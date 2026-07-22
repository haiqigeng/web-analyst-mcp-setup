function Get-ToolAliasMap {
    return @{
        "drive" = "googleDrive"
        "google drive" = "googleDrive"
        "gmail" = "gmail"
        "gtm" = "googleTagManager"
        "google tag manager" = "googleTagManager"
        "ga4" = "googleAnalytics"
        "google analytics" = "googleAnalytics"
        "google analytics 4" = "googleAnalytics"
        "playwright" = "browserQa"
        "browser qa" = "browserQa"
        "browser testing" = "browserQa"
        "chrome devtools" = "browserDebug"
        "browser debug" = "browserDebug"
        "bigquery" = "bigQuery"
        "big query" = "bigQuery"
        "bq" = "bigQuery"
        "clickup" = "clickup"
        "trello" = "trello"
        "piano" = "pianoAnalytics"
        "piano analytics" = "pianoAnalytics"
        "piano api" = "pianoAnalyticsApi"
        "tag commander" = "tagCommander"
        "commanders act" = "tagCommander"
        "contentsquare" = "contentsquare"
    }
}

function Resolve-RequestedToolNames {
    param(
        [string[]]$RequestedTools,
        [string]$CatalogFile = $CatalogPath
    )

    $catalog = Read-JsonFile -Path $CatalogFile
    $aliases = Get-ToolAliasMap
    $tokens = @()
    foreach ($requested in @($RequestedTools)) {
        $tokens += @([string]$requested -split ",")
    }

    $resolved = @()
    foreach ($tokenValue in $tokens) {
        $token = ([string]$tokenValue).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        $catalogMatch = @($catalog.PSObject.Properties | Where-Object { $_.Name -ieq $token } | Select-Object -First 1)
        if ($catalogMatch.Count -gt 0) {
            $resolved += $catalogMatch[0].Name
            continue
        }
        if ($aliases.ContainsKey($token)) {
            $resolved += [string]$aliases[$token]
            continue
        }

        $displayMatch = @($catalog.PSObject.Properties | Where-Object { [string]$_.Value.displayName -ieq $token } | Select-Object -First 1)
        if ($displayMatch.Count -gt 0) {
            $resolved += $displayMatch[0].Name
            continue
        }

        $available = @($catalog.PSObject.Properties | ForEach-Object { [string]$_.Value.displayName } | Sort-Object)
        throw "Unknown tool '$token'. Choose one of: $($available -join ', ')."
    }
    return @($resolved | Select-Object -Unique)
}

function Get-DetectedAiClient {
    foreach ($candidate in @(
        @{ Name = "Codex"; Command = "codex" },
        @{ Name = "Claude"; Command = "claude" },
        @{ Name = "Gemini"; Command = "gemini" }
    )) {
        if (Get-Command $candidate.Command -ErrorAction SilentlyContinue) { return $candidate.Name }
    }
    return "Codex"
}

function Get-ClientMcpLoginGuidance {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Codex", "Claude", "Gemini")]
        [string]$ClientName,
        [Parameter(Mandatory = $true)]
        [string]$RequestedServerName,
        [string]$CapabilitiesFile = $ClientCapabilitiesPath
    )

    $capabilities = Read-JsonFile -Path $CapabilitiesFile
    $clientKey = switch ($ClientName) {
        "Codex" { "codex" }
        "Claude" { "claudeCode" }
        "Gemini" { "geminiCli" }
    }
    $client = $capabilities.clients.$clientKey
    if (-not $client -or -not [bool]$client.supportsMcpLogin) {
        throw "$ClientName does not declare a supported MCP login flow in $CapabilitiesFile."
    }
    $template = [string]$client.mcpLoginGuidance
    if ([string]::IsNullOrWhiteSpace($template) -or $template -notmatch "\{serverName\}") {
        throw "$ClientName has invalid MCP login guidance in $CapabilitiesFile."
    }
    return $template.Replace("{serverName}", $RequestedServerName)
}

function Set-ConversationSelection {
    param(
        [string[]]$RequestedTools,
        [string]$RequestedClient = "Selected",
        [string]$SelectionFile = $SelectionPath,
        [string]$SelectionTemplateFile = $SelectionExamplePath,
        [string]$CatalogFile = $CatalogPath
    )

    $selectionWasMissing = -not (Test-Path -LiteralPath $SelectionFile)
    $selection = if ($selectionWasMissing) {
        Read-JsonFile -Path $SelectionTemplateFile
    } else {
        Read-JsonFile -Path $SelectionFile
    }

    $resolvedTools = @()
    if (@($RequestedTools).Count -gt 0) {
        $resolvedTools = @(Resolve-RequestedToolNames -RequestedTools $RequestedTools -CatalogFile $CatalogFile)
        foreach ($tool in $selection.tools.PSObject.Properties) { $tool.Value.enabled = $false }
        foreach ($toolName in $resolvedTools) {
            if (-not (Test-ObjectProperty -Object $selection.tools -Name $toolName)) {
                throw "The local selection template does not contain catalog tool '$toolName'."
            }
            $selection.tools.($toolName).enabled = $true
        }
    }

    $effectiveClient = $RequestedClient
    $hasSelectedClient = $selection.aiClients.codex -or $selection.aiClients.claudeCode -or $selection.aiClients.geminiCli
    if ($effectiveClient -eq "Selected" -and ($selectionWasMissing -or -not $hasSelectedClient)) { $effectiveClient = Get-DetectedAiClient }
    if ($effectiveClient -ne "Selected") {
        $selection.aiClients.codex = $effectiveClient -in @("Codex", "All")
        $selection.aiClients.claudeCode = $effectiveClient -in @("Claude", "All")
        $selection.aiClients.geminiCli = $effectiveClient -in @("Gemini", "All")
    }

    if (Test-ObjectProperty -Object $selection -Name "profile") {
        $selection.PSObject.Properties.Remove("profile")
    }

    $directory = Split-Path -Parent $SelectionFile
    if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
    Write-JsonFile -Object $selection -Path $SelectionFile
    return $selection
}

function Read-RawDotEnvMap {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($rawLine in @(Get-Content -LiteralPath $Path)) {
        $line = ([string]$rawLine).Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        $map[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1)
    }
    return $map
}

function Get-SelectedCredentialKeys {
    param(
        [string]$SelectionFile = $SelectionPath,
        [string]$CatalogFile = $CatalogPath
    )
    if (-not (Test-Path -LiteralPath $SelectionFile)) { return @() }

    $selection = Read-JsonFile -Path $SelectionFile
    $catalog = Read-JsonFile -Path $CatalogFile
    $keys = @()
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }
        foreach ($field in @("credentialKeys", "optionalCredentialKeys", "urlEnvKey", "bearerTokenEnvVar")) {
            if (-not (Test-ObjectProperty -Object $item -Name $field)) { continue }
            foreach ($key in @($item.$field)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $keys += [string]$key }
            }
        }
    }
    return @($keys | Select-Object -Unique | Sort-Object)
}

function Sync-SelectedCredentialFile {
    param(
        [string]$SelectionFile = $SelectionPath,
        [string]$CatalogFile = $CatalogPath,
        [string]$TemplateFile = $EnvTemplatePath,
        [string]$TargetFile = $EnvPath
    )

    $selectedKeys = @(Get-SelectedCredentialKeys -SelectionFile $SelectionFile -CatalogFile $CatalogFile)
    $existing = Read-RawDotEnvMap -Path $TargetFile
    $template = Read-RawDotEnvMap -Path $TemplateFile
    $preservedKeys = @()
    foreach ($key in $existing.Keys) {
        if ($selectedKeys -contains $key) { continue }
        $value = [string]$existing[$key]
        $templateValue = if ($template.ContainsKey($key)) { [string]$template[$key] } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -ne $templateValue) { $preservedKeys += $key }
    }

    if ($selectedKeys.Count -eq 0 -and $preservedKeys.Count -eq 0) {
        if (Test-Path -LiteralPath $TargetFile) { Remove-Item -LiteralPath $TargetFile -Force }
        return
    }

    $targetDirectory = Split-Path -Parent $TargetFile
    if ($targetDirectory) { New-Item -ItemType Directory -Force $targetDirectory | Out-Null }
    $lines = @(
        "# Credential keys for the current selection; existing non-empty values are retained to avoid data loss.",
        "# This file is ignored by Git. Prefer browser OAuth or authorized local/vault credentials and *_FILE keys."
    )
    foreach ($key in $selectedKeys) {
        $value = if ($existing.ContainsKey($key)) { [string]$existing[$key] } elseif ($template.ContainsKey($key)) { [string]$template[$key] } else { "" }
        $lines += "$key=$value"
    }
    if ($preservedKeys.Count -gt 0) {
        $lines += ""
        $lines += "# Preserved non-empty values for tools that are not currently selected."
        foreach ($key in @($preservedKeys | Sort-Object)) { $lines += "$key=$($existing[$key])" }
    }
    Set-Content -LiteralPath $TargetFile -Value $lines -Encoding UTF8
}

function Get-MissingRequiredCredentialKeys {
    param($Item, [hashtable]$EnvMap)
    $missing = @()
    foreach ($key in @($Item.credentialKeys)) {
        $keyName = [string]$key
        if ([string]::IsNullOrWhiteSpace($keyName)) { continue }
        $present = -not [string]::IsNullOrWhiteSpace((Get-EffectiveCredentialValue -EnvMap $EnvMap -Key $keyName))
        if (-not $present) { $missing += $keyName }
    }
    return $missing
}

function Get-EffectiveCredentialValue {
    param([hashtable]$EnvMap, [string]$Key)
    if ($EnvMap.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$EnvMap[$Key])) { return [string]$EnvMap[$Key] }
    foreach ($scope in @("Process", "User")) {
        $value = [Environment]::GetEnvironmentVariable($Key, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ""
}

function Test-LocalAuthenticationMaterialReady {
    param(
        [string]$ToolName,
        $Item,
        [hashtable]$EnvMap,
        [string[]]$MissingKeys
    )
    if (@($MissingKeys).Count -gt 0) { return $false }
    if ([string]$Item.authMode -in @("api_header", "api_token", "service_account")) { return $true }

    $pathKeys = @(switch ($ToolName) {
        "googleDrive" { "GOOGLE_OAUTH_CLIENT_JSON"; "GDRIVE_CREDENTIALS_PATH" }
        "gmail" { "GOOGLE_OAUTH_CLIENT_JSON"; "GMAIL_CREDENTIALS_PATH" }
        "googleAnalytics" { "GOOGLE_APPLICATION_CREDENTIALS" }
    })
    if ($pathKeys.Count -eq 0) { return $false }
    foreach ($pathKey in $pathKeys) {
        $path = [Environment]::ExpandEnvironmentVariables((Get-EffectiveCredentialValue -EnvMap $EnvMap -Key $pathKey))
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return $false }
    }
    return $true
}

function Get-ProviderApprovalReasons {
    param($Item, [string]$ToolName = "")
    $reasons = @()
    if ([string]$Item.dataExposure -eq "third-party-remote-mcp") {
        $reasons += "selected account data passes through a third-party hosted MCP"
    }
    if ([string]$Item.officialness -match "third-party|candidate|vendor-api") {
        $reasons += "provider is not first-party"
    }
    if ([string]$Item.lifecycleStatus -in @("candidate", "private-beta")) {
        $reasons += "provider lifecycle is $([string]$Item.lifecycleStatus)"
    }
    if ([string]$Item.riskLevel -eq "high") { $reasons += "catalog risk is high" }
    if ([string]$Item.writeCapability -and [string]$Item.writeCapability -notin @("read-only-default", "analytics-read-default")) {
        $reasons += "capability: $([string]$Item.writeCapability)"
    }
    if ([string]$Item.authMode -match "company") { $reasons += "OAuth client setup or organizational IAM approval may be required" }
    if ($ToolName -eq "bigQuery") { $reasons += "warehouse queries can incur cost; confirm project, dataset, and byte limit" }
    return @($reasons | Select-Object -Unique)
}

function Get-ConnectPlanRows {
    param(
        [string]$SelectionFile = $SelectionPath,
        [string]$CatalogFile = $CatalogPath,
        [string]$CredentialFile = $EnvPath
    )
    $selection = Read-JsonFile -Path $SelectionFile
    $catalog = Read-JsonFile -Path $CatalogFile
    $envMap = Import-DotEnvMap -Path $CredentialFile
    $rows = @()
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }
        $missing = @(Get-MissingRequiredCredentialKeys -Item $item -EnvMap $envMap)
        $approval = @(Get-ProviderApprovalReasons -Item $item -ToolName $tool.Name)
        $auth = if ($item.authMode -eq "none") { "None" } elseif ($missing.Count -gt 0) { "Missing: $($missing -join ', ')" } else { [string]$item.authMode }
        $rows += [PSCustomObject]@{
            ToolName = $tool.Name
            Tool = [string]$item.displayName
            Provider = if ($item.selectedProvider) { [string]$item.selectedProvider } else { [string]$tool.Value.provider }
            Runtime = [string]$item.runtime
            Auth = $auth
            DataRoute = [string]$item.dataExposure
            Risk = [string]$item.riskLevel
            Approval = if ($approval.Count -gt 0) { $approval -join "; " } else { "standard setup" }
        }
    }
    return $rows
}

function Write-ConnectPlan {
    $selection = Read-JsonFile -Path $SelectionPath
    $rows = @(Get-ConnectPlanRows)
    if ($rows.Count -eq 0) { throw "No tools are selected. Pass -Tools with names such as gtm, ga4, or playwright." }
    $clients = @(Resolve-TargetClients -Selection $selection -RequestedClient "Selected")
    $clientTargets = @($clients | ForEach-Object {
            $path = Get-ClientConfigTarget -ClientName $_ -Selection $selection
            [PSCustomObject]@{
                Client = $_
                ConfigTarget = $path
                Existing = if (Test-Path -LiteralPath $path) { "Yes" } else { "No" }
            }
        })
    $selectedItems = @(Get-SelectedCatalogItems)
    $needs = Get-PrerequisiteNeeds -SelectedItems $selectedItems -IncludePython ([bool]$InstallPython)
    $prerequisites = @()
    if ($needs.NeedsNode) { $prerequisites += "Node.js 22+" }
    if ($needs.NeedsPython) { $prerequisites += "Python/pipx" }
    if ($needs.NeedsGcloud) { $prerequisites += "Google Cloud CLI" }

    Write-Step "Connect plan"
    Write-Host (($rows | Select-Object Tool, Provider, Runtime, Auth, DataRoute, Risk | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())
    Write-Host (($clientTargets | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())
    Write-Host "Prerequisites used by this selection: $(if ($prerequisites.Count -gt 0) { $prerequisites -join ', ' } else { 'none' })"
    $approvalRows = @($rows | Where-Object { $_.Approval -ne "standard setup" })
    if ($approvalRows.Count -gt 0) {
        Write-Host "Approval-sensitive routes:"
        foreach ($row in $approvalRows) { Write-Host "  - $($row.Tool): $($row.Approval)" }
    }
    Write-Host "A confirmed run may install missing prerequisites and update only the selected clients' kit-owned MCP entries."
    return $rows
}

function Set-ToolEvidenceInternal {
    param(
        [string]$RequestedToolName,
        [string]$RequestedStage,
        [string]$RequestedOutcome,
        [string]$RequestedTarget = "",
        [string]$RequestedEvidence = "",
        [string]$Provider = "",
        [string]$StatePath = $OnboardingStatePath,
        [string]$SelectionFile = $SelectionPath,
        [switch]$PreservePassed
    )
    if ($RequestedEvidence -match "GOCSPX|ya29\.|1//|github_pat_|ghp_|private_key") {
        throw "Evidence looks like a credential. Record only a short human-verifiable summary."
    }
    if ([string]::IsNullOrWhiteSpace($Provider)) {
        $selection = Read-JsonFile -Path $SelectionFile
        $Provider = [string]$selection.tools.($RequestedToolName).provider
    }
    $state = Read-OnboardingState -Path $StatePath
    if (-not $state["toolEvidence"].ContainsKey($RequestedToolName) -or [string]$state["toolEvidence"][$RequestedToolName]["provider"] -ne $Provider) {
        $state["toolEvidence"][$RequestedToolName] = @{ provider = $Provider; stages = @{} }
    }
    $entry = $state["toolEvidence"][$RequestedToolName]
    if ($PreservePassed -and $entry["stages"].ContainsKey($RequestedStage) -and [string]$entry["stages"][$RequestedStage]["outcome"] -eq "Passed") {
        return
    }
    $entry["stages"][$RequestedStage] = @{
        outcome = $RequestedOutcome
        recordedAt = (Get-Date).ToString("o")
        target = $RequestedTarget
        evidence = $RequestedEvidence
    }
    Write-OnboardingState -State $state -Path $StatePath
}

function Initialize-ConnectEvidence {
    param([string[]]$ConfiguredToolNames)
    $selection = Read-JsonFile -Path $SelectionPath
    $catalog = Read-JsonFile -Path $CatalogPath
    $envMap = Import-DotEnvMap -Path $EnvPath
    $clients = @(Resolve-TargetClients -Selection $selection -RequestedClient "Selected") -join ", "
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }
        if ($ConfiguredToolNames -contains $tool.Name -or $item.kind -eq "api") {
            Set-ToolEvidenceInternal -RequestedToolName $tool.Name -RequestedStage "Configured" -RequestedOutcome "Passed" -RequestedTarget $clients -RequestedEvidence "Selected connection configuration is present." -PreservePassed
        } else {
            Set-ToolEvidenceInternal -RequestedToolName $tool.Name -RequestedStage "Configured" -RequestedOutcome "Pending" -RequestedTarget $clients -RequestedEvidence "The selected client configuration is not complete."
        }
        if ($item.authMode -eq "none") {
            Set-ToolEvidenceInternal -RequestedToolName $tool.Name -RequestedStage "Authenticated" -RequestedOutcome "Passed" -RequestedTarget "No login required" -RequestedEvidence "The selected provider requires no account authentication." -PreservePassed
        } else {
            $missing = @(Get-MissingRequiredCredentialKeys -Item $item -EnvMap $envMap)
            $evidence = if ($missing.Count -gt 0) { "Waiting for credentials authorized for the intended account: $($missing -join ', ')." } else { "Waiting for the selected provider's login or credential verification." }
            Set-ToolEvidenceInternal -RequestedToolName $tool.Name -RequestedStage "Authenticated" -RequestedOutcome "Pending" -RequestedEvidence $evidence -PreservePassed
        }
        Set-ToolEvidenceInternal -RequestedToolName $tool.Name -RequestedStage "Visible" -RequestedOutcome "Pending" -RequestedEvidence "Check the MCP tools in the active client session." -PreservePassed
        Set-ToolEvidenceInternal -RequestedToolName $tool.Name -RequestedStage "Verified" -RequestedOutcome "Pending" -RequestedEvidence "Run the catalog's target-specific read-only smoke test." -PreservePassed
    }
}

function Get-ConnectResultRows {
    param(
        [string]$SelectionFile = $SelectionPath,
        [string]$CatalogFile = $CatalogPath,
        [string]$CredentialFile = $EnvPath,
        [string]$StatePath = $OnboardingStatePath,
        [switch]$SkipConfigurationCheck
    )
    $selection = Read-JsonFile -Path $SelectionFile
    $catalog = Read-JsonFile -Path $CatalogFile
    $envMap = Import-DotEnvMap -Path $CredentialFile
    $state = Read-OnboardingState -Path $StatePath
    $targetClients = @(Resolve-TargetClients -Selection $selection -RequestedClient "Selected")
    $rows = @()
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }
        $provider = if ($item.selectedProvider) { [string]$item.selectedProvider } else { [string]$tool.Value.provider }
        $evidence = if ($state["toolEvidence"].ContainsKey($tool.Name) -and [string]$state["toolEvidence"][$tool.Name]["provider"] -eq $provider) { $state["toolEvidence"][$tool.Name] } else { $null }
        $verified = $null
        if ($evidence -and $evidence["stages"].ContainsKey("Verified")) { $verified = $evidence["stages"]["Verified"] }
        $authenticated = $null
        if ($evidence -and $evidence["stages"].ContainsKey("Authenticated")) { $authenticated = $evidence["stages"]["Authenticated"] }
        $missing = @(Get-MissingRequiredCredentialKeys -Item $item -EnvMap $envMap)
        $localAuthReady = Test-LocalAuthenticationMaterialReady -ToolName $tool.Name -Item $item -EnvMap $envMap -MissingKeys $missing
        $isAdcAuth = [string]$item.authMode -match "adc|application_default_credentials"
        $requiresLocalAuthMaterial = $tool.Name -in @("googleDrive", "gmail", "googleAnalytics") -or [string]$item.authMode -in @("api_header", "api_token", "service_account")

        $configured = $item.kind -eq "api"
        if ($SkipConfigurationCheck) {
            $configured = $true
        } elseif ($item.kind -eq "mcp") {
            try { $configured = [bool](Get-McpConfiguredSummary -Selection $selection -ServerName ([string]$item.serverName)).AllConfigured } catch { $configured = $false }
        }

        $result = "Blocked"
        $target = ""
        $nextAction = [string]$item.testPrompt
        if (-not $configured) {
            $result = "Blocked"
            $nextAction = "Run Connect with approval to configure the selected client."
        } elseif ($missing.Count -gt 0 -and $isAdcAuth) {
            $result = "Blocked"
            $nextAction = "Run the GoogleAdcLogin helper and sign in with the intended Google account; then run: $([string]$item.testPrompt)"
        } elseif ($missing.Count -gt 0) {
            $result = "Blocked"
            $nextAction = "Provide credentials authorized for the intended account: $($missing -join ', ')."
        } elseif ($requiresLocalAuthMaterial -and -not $localAuthReady) {
            $result = "Blocked"
            $nextAction = if ($isAdcAuth) {
                "Run the GoogleAdcLogin helper and sign in with the intended Google account; then run: $([string]$item.testPrompt)"
            } elseif ($tool.Name -in @("googleDrive", "gmail")) {
                "Complete the selected provider's OAuth browser setup with the intended account; then run: $([string]$item.testPrompt)"
            } else {
                "Provide valid local authentication material authorized for the intended account, then run: $([string]$item.testPrompt)"
            }
        } elseif ($verified -and [string]$verified["outcome"] -eq "Passed") {
            $result = "Verified"
            $target = [string]$verified["target"]
            $nextAction = "None"
        } elseif ($item.authMode -eq "none") {
            $result = "Ready to verify"
            $nextAction = [string]$item.testPrompt
        } elseif (($authenticated -and [string]$authenticated["outcome"] -eq "Passed") -or $localAuthReady) {
            $result = "Ready to verify"
            $nextAction = [string]$item.testPrompt
        } elseif ($isAdcAuth) {
            $result = "Blocked"
            $nextAction = "Run the GoogleAdcLogin helper and sign in with the intended Google account; then run: $([string]$item.testPrompt)"
        } elseif ([string]$item.authMode -match "oauth") {
            $result = "Blocked"
            if ([string]$item.transport -eq "http") {
                $loginGuidance = @($targetClients | ForEach-Object {
                        Get-ClientMcpLoginGuidance -ClientName $_ -RequestedServerName ([string]$item.serverName)
                    })
                $nextAction = ($loginGuidance -join "; ") + ". Then run: $([string]$item.testPrompt)"
            } else {
                $nextAction = "Start or reload '$([string]$item.serverName)' in the selected client and complete the provider's browser OAuth flow; then run: $([string]$item.testPrompt)"
            }
        } elseif ($item.kind -eq "api") {
            $result = "Ready to verify"
            $nextAction = [string]$item.testPrompt
        }

        $rows += [PSCustomObject]@{
            ToolName = $tool.Name
            Tool = [string]$item.displayName
            Result = $result
            Target = $target
            NextAction = $nextAction
        }
    }
    return $rows
}

function Write-SetupSummary {
    param([string]$Path = (Join-Path $GeneratedDir "setup-summary.md"))
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $rows = @(Get-ConnectResultRows)
    $generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    $lines = @(
        "# Web Analyst Tool Setup",
        "",
        "Generated: $generatedAt",
        "",
        "| Tool | Result | Connected target | Next action |",
        "| --- | --- | --- | --- |"
    )
    foreach ($row in $rows) {
        $target = ([string]$row.Target) -replace "\|", "/"
        $next = ([string]$row.NextAction) -replace "\|", "/"
        $lines += "| $($row.Tool) | $($row.Result) | $target | $next |"
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8

    $state = Read-OnboardingState
    $state["generatedAt"] = $generatedAt
    $state["sourceSelectionFile"] = "config/tool-selection.json"
    $state["selectedTools"] = @($rows | ForEach-Object { @{ tool = $_.ToolName; displayName = $_.Tool; result = $_.Result; target = $_.Target; nextAction = $_.NextAction } })
    $state["credentialKeys"] = @(Get-SelectedCredentialKeys)
    $state["reminders"] = @("A tool is ready only after its target-specific read-only check passes.")
    if ($state.ContainsKey("profile")) { $state.Remove("profile") }
    Write-OnboardingState -State $state

    Write-Step "Setup result"
    if ($rows.Count -gt 0) { Write-Host (($rows | Select-Object Tool, Result, Target, NextAction | Format-Table -AutoSize | Out-String -Width 260).TrimEnd()) }
    Write-Host "Saved concise handover: $Path"
    return $rows
}

function Test-SelectedConfigurationReady {
    $selection = Read-JsonFile -Path $SelectionPath
    $catalog = Read-JsonFile -Path $CatalogPath
    $mcpCount = 0
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item -or $item.kind -ne "mcp") { continue }
        $mcpCount++
        if (-not (Get-McpConfiguredSummary -Selection $selection -ServerName ([string]$item.serverName)).AllConfigured) { return $false }
    }
    return $mcpCount -gt 0
}

function Invoke-Connect {
    Invoke-ValidateKit -Quiet
    if (@($Tools).Count -gt 0 -or -not (Test-Path -LiteralPath $SelectionPath) -or $Client -ne "Selected") {
        Set-ConversationSelection -RequestedTools $Tools -RequestedClient $Client | Out-Null
    }
    Ensure-LocalFiles | Out-Null
    $selectedItems = @(Get-SelectedCatalogItems)
    if ($selectedItems.Count -eq 0) { throw "No tools are selected. Pass -Tools with names such as gtm, ga4, or playwright." }

    Write-ConnectPlan | Out-Null
    if ($Preview -or -not $Confirmed) {
        Write-SetupSummary | Out-Null
        Write-Host "Preview complete. No prerequisite or MCP client configuration was changed. Rerun Connect with -Confirmed after the user approves this plan."
        return
    }

    try {
        Invoke-Prereqs -NoReport
    } catch {
        Write-Warning "One or more prerequisite checks were blocked: $($_.Exception.Message)"
        try { Invoke-CheckMcpUpdates -NoReport } catch { Write-Warning "Package resolution remains incomplete: $($_.Exception.Message)" }
    }

    $configuredToolNames = @()
    $selectedMcpItems = @($selectedItems | Where-Object { $_.Item.kind -eq "mcp" })
    if ($selectedMcpItems.Count -gt 0) {
        if (Test-SelectedConfigurationReady) {
            $configuredToolNames += @($selectedMcpItems | ForEach-Object { $_.ToolName })
            Write-Host "Selected MCP entries are already present; configuration apply was skipped."
        } else {
            $servers = @(Get-EnabledMcpServers -SkipUnavailable)
            if ($servers.Count -gt 0) {
                try {
                    Invoke-Apply -ServersOverride $servers -NoGeneratedFiles
                    $configuredToolNames += @($servers | ForEach-Object { $_.ToolName })
                } catch {
                    Write-Warning "MCP configuration could not be completed for every ready tool: $($_.Exception.Message)"
                }
            }
        }
    }
    $configuredToolNames += @($selectedItems | Where-Object { $_.Item.kind -eq "api" } | ForEach-Object { $_.ToolName })
    Initialize-ConnectEvidence -ConfiguredToolNames @($configuredToolNames | Select-Object -Unique)
    Write-SetupSummary | Out-Null
    Write-Host "Complete only the login and read-only verification actions shown above; blocked tools do not prevent the others from being used."
}
