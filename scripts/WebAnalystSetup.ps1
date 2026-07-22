[CmdletBinding()]
param(
    [ValidateSet("Connect", "Prepare", "Validate", "Doctor", "CredentialGuide", "BigQuerySafetyPlan", "OnboardingReport", "RecordEvidence", "ReleaseAudit", "CatalogReview", "PesterTests", "Prereqs", "CheckMcpUpdates", "Generate", "Apply", "Status", "Dashboard", "RunMcp", "GoogleOAuthFile", "GoogleAdcLogin", "RefreshGoogleDriveToken", "BigQueryAdcBearerToken", "ResetKit", "ResetMcpConfig", "ResetCodexMcp", "All")]
    [string]$Action = "Status",

    [ValidateSet("Selected", "All", "Codex", "Claude", "Gemini")]
    [string]$Client = "Selected",

    [string[]]$Tools = @(),
    [string]$ServerName,
    [ValidateSet("npx", "pipx")]
    [string]$Runner = "npx",
    [string]$Package,
    [string[]]$McpArgs = @(),
    [string]$McpArgsJson,
    [string]$McpArgsBase64,
    [string]$ToolName,
    [ValidateSet("Configured", "Authenticated", "Visible", "Verified")]
    [string]$Stage,
    [ValidateSet("Passed", "Failed", "Pending")]
    [string]$Outcome,
    [string]$Target,
    [string]$Evidence,
    [switch]$Preview,
    [switch]$Confirmed,
    [switch]$AllCatalogProviders,
    [switch]$InstallPython,
    [switch]$ConfirmedMcpEndpointDeletion
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$SelectionPath = Join-Path $Root "config\tool-selection.json"
$SelectionExamplePath = Join-Path $Root "config\tool-selection.example.json"
$CatalogPath = Join-Path $Root "config\mcp-catalog.json"
$ClientCapabilitiesPath = Join-Path $Root "config\client-capabilities.json"
$EnvPath = Join-Path $Root "secrets\.env.local"
$EnvTemplatePath = Join-Path $Root "secrets\.env.template"
$GeneratedDir = Join-Path $Root "generated"
$OnboardingStatePath = Join-Path $GeneratedDir "onboarding-state.json"
$VersionLockPath = Join-Path $GeneratedDir "mcp-version-lock.json"
$OwnershipRoot = Join-Path $env:USERPROFILE ".web-analyst-agent\config-ownership"
$InstallationIdPath = Join-Path $Root ".web-analyst-installation-id"
$ScriptPath = $MyInvocation.MyCommand.Path
$LibDir = Join-Path $PSScriptRoot "lib"

if (Test-Path -LiteralPath $LibDir) {
    Get-ChildItem -LiteralPath $LibDir -Filter "*.ps1" -File | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message"
}

function Ensure-LocalFiles {
    New-Item -ItemType Directory -Force (Join-Path $Root "config") | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Root "secrets") | Out-Null
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null

    if (-not (Test-Path -LiteralPath $SelectionPath)) {
        Copy-Item -LiteralPath $SelectionExamplePath -Destination $SelectionPath
        Write-Host "Created config\tool-selection.json."
    }
    Sync-SelectedCredentialFile
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) { $hash[$key] = ConvertTo-Hashtable -InputObject ($InputObject[$key]) }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $array = @()
            foreach ($item in $InputObject) { $array += ConvertTo-Hashtable -InputObject $item }
            return ,$array
        }
        if ($InputObject.PSObject.Properties.Count -gt 0 -and $InputObject.GetType().Name -eq "PSCustomObject") {
            $hash = @{}
            foreach ($prop in $InputObject.PSObject.Properties) { $hash[$prop.Name] = ConvertTo-Hashtable -InputObject $prop.Value }
            return $hash
        }
        return $InputObject
    }
}

function Resolve-CatalogItem {
    param($CatalogItem, [string]$Provider)
    if ($null -eq $CatalogItem) { return $null }

    $resolved = ConvertTo-Hashtable $CatalogItem
    if ($resolved.ContainsKey("providers") -and -not [string]::IsNullOrWhiteSpace($Provider)) {
        $providers = $resolved["providers"]
        if ($providers -and $providers.ContainsKey($Provider)) {
            $providerValues = ConvertTo-Hashtable $providers[$Provider]
            foreach ($key in $providerValues.Keys) {
                $resolved[$key] = $providerValues[$key]
            }
            $resolved["selectedProvider"] = $Provider
        } else {
            $resolved["selectedProvider"] = [string]$resolved["defaultProvider"]
        }
    } elseif ($resolved.ContainsKey("defaultProvider")) {
        $resolved["selectedProvider"] = [string]$resolved["defaultProvider"]
    }

    $resolved.Remove("providers")
    return ($resolved | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Write-JsonFile {
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing JSON file: $Path"
    }
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function ConvertTo-CanonicalJson {
    param($InputObject)

    if ($null -eq $InputObject) { return "null" }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in @($InputObject.Keys | Sort-Object)) {
            $keyJson = ConvertTo-Json -InputObject ([string]$key) -Compress
            $valueJson = ConvertTo-CanonicalJson -InputObject ($InputObject[$key])
            "$keyJson`:$valueJson"
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($InputObject -is [PSCustomObject]) {
        $parts = foreach ($property in @($InputObject.PSObject.Properties | Sort-Object Name)) {
            $keyJson = ConvertTo-Json -InputObject $property.Name -Compress
            $valueJson = ConvertTo-CanonicalJson -InputObject $property.Value
            "$keyJson`:$valueJson"
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $parts = foreach ($item in $InputObject) { ConvertTo-CanonicalJson -InputObject $item }
        return "[" + ($parts -join ",") + "]"
    }
    return ConvertTo-Json -InputObject $InputObject -Compress
}

function Get-ObjectFingerprint {
    param($InputObject)
    $canonical = ConvertTo-CanonicalJson -InputObject $InputObject
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-OwnershipStatePath {
    param([switch]$ReadOnly)
    $installationId = Get-InstallationId -ReadOnly:$ReadOnly
    if ([string]::IsNullOrWhiteSpace($installationId)) { return $null }
    return Join-Path $OwnershipRoot ($installationId + ".json")
}

function Get-InstallationId {
    param([string]$Path = $InstallationIdPath, [switch]$ReadOnly)
    if (Test-Path -LiteralPath $Path) {
        $existingId = (Get-Content -Raw -LiteralPath $Path).Trim()
        $parsed = [Guid]::Empty
        if ([Guid]::TryParse($existingId, [ref]$parsed)) { return $parsed.ToString() }
    }
    if ($ReadOnly) { return $null }
    $newId = [Guid]::NewGuid().ToString()
    Set-Content -LiteralPath $Path -Value $newId -Encoding ASCII
    return $newId
}

function Read-OwnershipState {
    param([switch]$ReadOnly)
    $path = Get-OwnershipStatePath -ReadOnly:$ReadOnly
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return @{
            version = 1
            kitRoot = [string]$Root
            clients = @{}
        }
    }
    return ConvertTo-Hashtable (Read-JsonFile -Path $path)
}

function Write-OwnershipState {
    param($State)
    New-Item -ItemType Directory -Force $OwnershipRoot | Out-Null
    $State["version"] = 1
    $State["kitRoot"] = [string]$Root
    $State["updatedAt"] = (Get-Date).ToString("o")
    Write-JsonFile -Object $State -Path (Get-OwnershipStatePath)
}

function New-ConfigBackup {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $backup = "$Path.web-analyst-backup-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backup
    return $backup
}

function Resolve-TargetClients {
    param($Selection, [string]$RequestedClient = $Client)

    if ($RequestedClient -eq "All") { return @("Codex", "Claude", "Gemini") }
    if ($RequestedClient -ne "Selected") { return @($RequestedClient) }

    $targets = @()
    if ($Selection.aiClients.codex) { $targets += "Codex" }
    if ($Selection.aiClients.claudeCode) { $targets += "Claude" }
    if ($Selection.aiClients.geminiCli) { $targets += "Gemini" }
    if ($targets.Count -eq 0) {
        throw "No AI clients are selected in config\tool-selection.json."
    }
    return $targets
}

function Get-ClientConfigTarget {
    param([string]$ClientName, $Selection)
    $scope = [string]$Selection.installScope
    if ([string]::IsNullOrWhiteSpace($scope)) { $scope = "user" }

    switch ($ClientName) {
        "Codex" {
            $directory = if ($scope -eq "project") { Join-Path $Root ".codex" } else { Join-Path $env:USERPROFILE ".codex" }
            return Join-Path $directory "config.toml"
        }
        "Claude" { return Join-Path $Root ".mcp.json" }
        "Gemini" {
            $directory = if ($scope -eq "project") { Join-Path $Root ".gemini" } else { Join-Path $env:USERPROFILE ".gemini" }
            return Join-Path $directory "settings.json"
        }
        default { throw "Unsupported client target: $ClientName" }
    }
}

function Read-OnboardingState {
    param([string]$Path = $OnboardingStatePath)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{
            version = 2
            toolEvidence = @{}
        }
    }
    $state = ConvertTo-Hashtable (Read-JsonFile -Path $Path)
    if (-not $state.ContainsKey("toolEvidence") -or $null -eq $state["toolEvidence"]) { $state["toolEvidence"] = @{} }
    foreach ($toolKey in @($state["toolEvidence"].Keys)) {
        $toolEntry = $state["toolEvidence"][$toolKey]
        if (-not $toolEntry.ContainsKey("provider")) { $toolEntry["provider"] = "" }
        if (-not $toolEntry.ContainsKey("stages") -or $null -eq $toolEntry["stages"]) { $toolEntry["stages"] = @{} }
        foreach ($stageKey in @($toolEntry["stages"].Keys)) {
            $stageEntry = $toolEntry["stages"][$stageKey]
            $complete = $stageEntry.ContainsKey("outcome") -and $stageEntry.ContainsKey("recordedAt") -and $stageEntry.ContainsKey("target") -and $stageEntry.ContainsKey("evidence")
            if (-not $complete) {
                $toolEntry["stages"][$stageKey] = @{
                    outcome = "Pending"
                    recordedAt = (Get-Date).ToString("o")
                    target = ""
                    evidence = "Legacy evidence was incomplete; repeat this check."
                }
            }
        }
    }
    return $state
}

function Write-OnboardingState {
    param($State, [string]$Path = $OnboardingStatePath)
    $stateDirectory = Split-Path -Parent $Path
    if ($stateDirectory) { New-Item -ItemType Directory -Force $stateDirectory | Out-Null }
    $State["version"] = 2
    $State["updatedAt"] = (Get-Date).ToString("o")
    Write-JsonFile -Object $State -Path $Path
}

function Get-CurrentToolProvider {
    param([string]$RequestedToolName)
    $selection = Read-JsonFile -Path $SelectionPath
    if (-not (Test-ObjectProperty -Object $selection.tools -Name $RequestedToolName)) {
        throw "Unknown tool '$RequestedToolName' in config\tool-selection.json."
    }
    return [string]$selection.tools.($RequestedToolName).provider
}

function Get-ToolEvidenceEntry {
    param([string]$RequestedToolName, [string]$Provider)
    $state = Read-OnboardingState
    if (-not $state["toolEvidence"].ContainsKey($RequestedToolName)) { return $null }
    $entry = $state["toolEvidence"][$RequestedToolName]
    if ($entry.ContainsKey("provider") -and [string]$entry["provider"] -ne $Provider) { return $null }
    return $entry
}

function Format-EvidenceStage {
    param($ToolEvidence, [string]$RequestedStage, [string]$PendingText)
    if (-not $ToolEvidence -or -not $ToolEvidence.ContainsKey("stages") -or -not $ToolEvidence["stages"].ContainsKey($RequestedStage)) {
        return $PendingText
    }
    $stageEntry = $ToolEvidence["stages"][$RequestedStage]
    $result = [string]$stageEntry["outcome"]
    if ($stageEntry["recordedAt"]) {
        $recordedAt = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$stageEntry["recordedAt"], [ref]$recordedAt)) {
            $result += " " + $recordedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
        }
    }
    if ($stageEntry["target"]) { $result += " - " + [string]$stageEntry["target"] }
    return $result
}

function Invoke-RecordEvidence {
    Ensure-LocalFiles | Out-Null
    if ([string]::IsNullOrWhiteSpace($ToolName) -or [string]::IsNullOrWhiteSpace($Stage) -or [string]::IsNullOrWhiteSpace($Outcome)) {
        throw "RecordEvidence requires -ToolName, -Stage, and -Outcome."
    }
    if ($Evidence -match "GOCSPX|ya29\.|1//|github_pat_|ghp_|private_key") {
        throw "Evidence looks like it may contain a credential. Record a short human-verifiable summary, never a token or secret."
    }
    if ($Stage -eq "Verified" -and $Outcome -eq "Passed" -and [string]::IsNullOrWhiteSpace($Evidence)) {
        throw "A passed verification requires a short -Evidence summary."
    }

    $provider = Get-CurrentToolProvider -RequestedToolName $ToolName
    Set-ToolEvidenceInternal -RequestedToolName $ToolName -Provider $provider -RequestedStage $Stage -RequestedOutcome $Outcome -RequestedTarget $Target -RequestedEvidence $Evidence
    Write-Host "Recorded $Stage evidence for $ToolName [$provider]: $Outcome"
}

function Get-PropertyNames {
    param($Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-ObjectProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return @(Get-PropertyNames -Object $Object) -contains $Name
}

function New-CheckResult {
    param([string]$Area, [string]$Check, [string]$Status, [string]$Detail = "")
    return [PSCustomObject]@{
        Area = $Area
        Check = $Check
        Status = $Status
        Detail = $Detail
    }
}

function Get-ToolStatusRows {
    param([switch]$UseExampleWhenLocalSelectionMissing)

    $selectionFile = $SelectionPath
    if (-not (Test-Path -LiteralPath $selectionFile) -and $UseExampleWhenLocalSelectionMissing) {
        $selectionFile = $SelectionExamplePath
    }
    if (-not (Test-Path -LiteralPath $selectionFile)) { return @() }

    $selection = Read-JsonFile -Path $selectionFile
    $catalog = Read-JsonFile -Path $CatalogPath
    $envMap = Import-DotEnvMap -Path $EnvPath
    $rows = @()

    foreach ($tool in $selection.tools.PSObject.Properties) {
        $enabled = [bool]$tool.Value.enabled
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) {
            $rows += [PSCustomObject]@{
                Tool = $tool.Name
                DisplayName = $tool.Name
                Enabled = $enabled
                Provider = [string]$tool.Value.provider
                Kind = "unknown"
                Runtime = ""
                Auth = ""
                CredentialState = "Catalog entry missing"
                Status = "Catalog issue"
                NextStep = "Add or fix this tool in config\mcp-catalog.json."
                Configured = if ($enabled) { "Selected" } else { "Not selected" }
                Authenticated = "Unknown"
                Visible = "Unknown"
                Verified = "Not verified"
                WriteCapability = ""
                Risk = "unknown"
            }
            continue
        }

        $credentialKeys = @($item.credentialKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $missing = @()
        $present = @()
        foreach ($key in $credentialKeys) {
            if ($envMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($envMap[$key])) {
                $present += $key
            } else {
                $missing += $key
            }
        }

        $credentialState = "No credentials required"
        if ($credentialKeys.Count -gt 0) {
            if ($missing.Count -gt 0) {
                $credentialState = "Missing: " + ($missing -join ", ")
            } else {
                $credentialState = "Present: " + ($present -join ", ")
            }
        }

        if ($tool.Name -eq "bigQuery" -and $item.bearerTokenEnvVar) {
            $bearerKey = [string]$item.bearerTokenEnvVar
            $bearerValue = ""
            if ($envMap.ContainsKey($bearerKey)) { $bearerValue = [string]$envMap[$bearerKey] }
            if ([string]::IsNullOrWhiteSpace($bearerValue)) {
                $bearerValue = [Environment]::GetEnvironmentVariable($bearerKey, "User")
            }
            if ([string]::IsNullOrWhiteSpace($bearerValue)) {
                $bearerValue = [Environment]::GetEnvironmentVariable($bearerKey, "Process")
            }
            if (-not [string]::IsNullOrWhiteSpace($bearerValue)) {
                $credentialState = "Short-lived bearer token env var present: $bearerKey"
            } else {
                $credentialState = "Needs auth choice: official remote OAuth or short-lived ADC bearer token"
            }
        }

        $providerName = if ($item.selectedProvider) { [string]$item.selectedProvider } else { [string]$tool.Value.provider }
        $toolEvidence = Get-ToolEvidenceEntry -RequestedToolName $tool.Name -Provider $providerName
        $configuredState = if ($enabled) { "Selected" } else { "Not selected" }
        $allConfigured = $false
        if ($enabled -and $item.kind -eq "mcp") {
            $configurationCheck = Get-McpConfiguredSummary -Selection $selection -ServerName ([string]$item.serverName)
            $configuredState = $configurationCheck.Summary
            $allConfigured = [bool]$configurationCheck.AllConfigured
        } elseif ($enabled -and $item.kind -eq "api") {
            $configuredState = "API connector selected"
            $allConfigured = $true
        }

        $status = if ($enabled) { "Selected" } else { "Available" }
        $nextStep = [string]$item.testPrompt
        if ($enabled -and $missing.Count -gt 0) {
            $status = "Needs credentials"
            $nextStep = "Collect credential values authorized for the intended account: " + ($missing -join ", ")
        } elseif ($enabled -and $item.authMode -eq "none") {
            $status = "Ready to configure"
            $nextStep = "Run Apply, then verify with the lightweight browser test."
        } elseif ($enabled -and $item.authMode -match "oauth|adc") {
            $status = "Needs authentication"
            $nextStep = "Run Dashboard for the login command, complete browser auth, then run Status."
        } elseif ($enabled -and $item.kind -eq "api") {
            $status = "API connector selected"
            $nextStep = "Verify credentials and prepare a read-only API test plan."
        }
        if ($enabled -and $tool.Name -eq "bigQuery") {
            if ($credentialState -like "Short-lived bearer token*") {
                $status = "Needs client reload and smoke test"
                $nextStep = "Restart/reload the MCP client so it reads BIGQUERY_MCP_ACCESS_TOKEN, then run a dry-run read-only query."
            } else {
                $status = "Needs BigQuery auth choice"
                $nextStep = "Choose official remote OAuth/IAM if your MCP client supports it; in Codex, use BigQueryAdcBearerToken as a short-term ADC bearer-token fix, then restart/reload Codex and run a dry-run read-only query."
            }
        }

        if ($enabled -and $item.kind -eq "mcp" -and -not $allConfigured) {
            $status = "Needs configuration"
            $nextStep = "Run Apply for the selected AI client, then reload it if needed."
        }

        $authenticated = "Unknown"
        if ($item.authMode -eq "none" -and $credentialState -eq "No credentials required") {
            $authenticated = "No auth needed"
        } elseif ($credentialState -eq "No credentials required" -and [string]$item.authMode -match "oauth|adc") {
            $authenticated = "Needs browser/login check"
        } elseif ($credentialState -eq "No credentials required") {
            $authenticated = "No local secret required"
        } elseif ($credentialState -like "Present:*" -or $credentialState -like "Token present*" -or $credentialState -like "Short-lived*") {
            $authenticated = "Credential/token present"
        } elseif ($credentialState -like "Missing:*" -or $credentialState -like "Needs auth*") {
            $authenticated = "Needs credential or login"
        } elseif ($enabled -and $item.authMode -match "oauth|adc") {
            $authenticated = "Needs login check"
        }

        $authenticated = Format-EvidenceStage -ToolEvidence $toolEvidence -RequestedStage "Authenticated" -PendingText $authenticated
        $visible = Format-EvidenceStage -ToolEvidence $toolEvidence -RequestedStage "Visible" -PendingText "Pending current-session tool check"
        $verified = Format-EvidenceStage -ToolEvidence $toolEvidence -RequestedStage "Verified" -PendingText "Pending read-only proof"
        if ($toolEvidence -and $toolEvidence.ContainsKey("stages") -and $toolEvidence["stages"].ContainsKey("Verified") -and [string]$toolEvidence["stages"]["Verified"]["outcome"] -eq "Passed") {
            $status = "Verified"
            $nextStep = "Connection proof is recorded. Re-test only after credentials, provider, or client configuration changes."
        }

        $rows += [PSCustomObject]@{
            Tool = $tool.Name
            DisplayName = [string]$item.displayName
            Enabled = $enabled
            Provider = $providerName
            Kind = [string]$item.kind
            Runtime = [string]$item.runtime
            Auth = [string]$item.authMode
            CredentialState = $credentialState
            Status = $status
            NextStep = $nextStep
            Configured = $configuredState
            Authenticated = $authenticated
            Visible = $visible
            Verified = $verified
            WriteCapability = [string]$item.writeCapability
            Risk = [string]$item.riskLevel
        }
    }
    return $rows
}

function Assert-PathInsideRoot {
    param([string]$Path)
    $rootPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path).TrimEnd("\")
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    if ($fullPath -ne $rootPath -and -not $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside the kit folder: $Path"
    }
}

function Import-DotEnvMap {
    param([string]$Path, [switch]$IntoProcess)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }

        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $value = [Environment]::ExpandEnvironmentVariables($value)
        $map[$key] = $value
        if ($IntoProcess) {
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }

    foreach ($fileKey in @($map.Keys | Where-Object { $_ -like "*_FILE" })) {
        $baseKey = $fileKey.Substring(0, $fileKey.Length - 5)
        if ($map.ContainsKey($baseKey) -and -not [string]::IsNullOrWhiteSpace($map[$baseKey])) { continue }
        $secretFilePath = [Environment]::ExpandEnvironmentVariables($map[$fileKey])
        if ([string]::IsNullOrWhiteSpace($secretFilePath) -or -not (Test-Path -LiteralPath $secretFilePath)) { continue }
        $secretValue = (Get-Content -Raw -LiteralPath $secretFilePath).TrimEnd("`r", "`n")
        $map[$baseKey] = $secretValue
        if ($IntoProcess) {
            [Environment]::SetEnvironmentVariable($baseKey, $secretValue, "Process")
        }
    }

    return $map
}

function Set-DotEnvValue {
    param([string]$Path, [string]$Key, [string]$Value)
    Ensure-LocalFiles | Out-Null
    $lines = @()
    if (Test-Path -LiteralPath $Path) {
        $lines = @(Get-Content -LiteralPath $Path)
    }

    $escapedKey = [regex]::Escape($Key)
    $updated = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$escapedKey\s*=") {
            $lines[$i] = "$Key=$Value"
            $updated = $true
            break
        }
    }
    if (-not $updated) {
        $lines += "$Key=$Value"
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Test-PathInsideDirectory {
    param([string]$Path, [string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd("\")
    $fullDirectory = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Directory)).TrimEnd("\")
    return ($fullPath -eq $fullDirectory -or $fullPath.StartsWith($fullDirectory + "\", [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-OAuthTokenStatus {
    param(
        [string]$TokenPath,
        [string[]]$RequiredScopes = @(),
        [string]$ProbeUri
    )

    if ([string]::IsNullOrWhiteSpace($TokenPath)) { return "Needs token path" }
    $expanded = [Environment]::ExpandEnvironmentVariables($TokenPath)
    if (-not (Test-Path -LiteralPath $expanded)) { return "Needs browser auth token" }

    try {
        $token = Get-Content -Raw -LiteralPath $expanded | ConvertFrom-Json
    } catch {
        return "Token file unreadable"
    }

    $parts = @("Token present")
    $scopeText = [string]$token.scope
    $missingScopes = @()
    foreach ($scope in $RequiredScopes) {
        if ($scopeText -notlike "*$scope*") { $missingScopes += $scope }
    }
    if ($missingScopes.Count -gt 0) {
        $parts += "missing scopes: " + ($missingScopes -join ", ")
    } elseif ($RequiredScopes.Count -gt 0) {
        $parts += "scopes ok"
    }

    if ($token.expiry_date) {
        $expiry = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$token.expiry_date)
        if ($expiry -lt [DateTimeOffset]::UtcNow) {
            $parts += "access token expired"
        } else {
            $parts += "expires " + $expiry.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
        }
    }

    if ($ProbeUri -and $token.access_token -and $missingScopes.Count -eq 0) {
        try {
            Invoke-RestMethod -Method Get -Uri $ProbeUri -Headers @{ Authorization = "Bearer $($token.access_token)" } -TimeoutSec 10 | Out-Null
            $parts += "API reachable"
        } catch {
            $parts += "API check failed"
        }
    }

    return ($parts -join "; ")
}

function Remove-ExternalKitToken {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $agentHome = Join-Path $env:USERPROFILE ".web-analyst-agent"
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-PathInsideDirectory -Path $expanded -Directory $agentHome)) { return }
    if (Test-Path -LiteralPath $expanded) {
        Remove-Item -LiteralPath $expanded -Force
        Write-Host "Removed $expanded"
    }
}

function Invoke-GoogleOAuthFile {
    Ensure-LocalFiles | Out-Null
    $envMap = Import-DotEnvMap -Path $EnvPath
    $clientId = $envMap["GOOGLE_CLIENT_ID"]
    $clientSecret = $envMap["GOOGLE_CLIENT_SECRET"]
    $target = $envMap["GOOGLE_OAUTH_CLIENT_JSON"]
    $sourceJson = $envMap["GOOGLE_ADC_CLIENT_JSON"]

    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = Join-Path $env:USERPROFILE ".web-analyst-agent\google-oauth-client.json"
    }

    $target = [Environment]::ExpandEnvironmentVariables($target)
    New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null

    if (([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) -and $sourceJson) {
        $sourceJson = [Environment]::ExpandEnvironmentVariables($sourceJson)
        if (Test-Path -LiteralPath $sourceJson) {
            Copy-Item -LiteralPath $sourceJson -Destination $target -Force
        }
    }

    if (-not (Test-Path -LiteralPath $target)) {
        if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
            throw "Provide GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET, or provide an existing OAuth JSON path in GOOGLE_ADC_CLIENT_JSON."
        }

        $oauth = @{
            installed = @{
                client_id = $clientId
                project_id = $envMap["GOOGLE_PROJECT_ID"]
                auth_uri = "https://accounts.google.com/o/oauth2/auth"
                token_uri = "https://oauth2.googleapis.com/token"
                auth_provider_x509_cert_url = "https://www.googleapis.com/oauth2/v1/certs"
                client_secret = $clientSecret
                redirect_uris = @(
                    "http://localhost",
                    "http://localhost:3000/oauth2callback"
                )
            }
        }
        Write-JsonFile -Object $oauth -Path $target
    }

    Set-DotEnvValue -Path $EnvPath -Key "GOOGLE_OAUTH_CLIENT_JSON" -Value $target
    Set-DotEnvValue -Path $EnvPath -Key "GDRIVE_OAUTH_PATH" -Value $target
    Set-DotEnvValue -Path $EnvPath -Key "GMAIL_OAUTH_PATH" -Value $target
    Set-DotEnvValue -Path $EnvPath -Key "GOOGLE_ADC_CLIENT_JSON" -Value $target

    Write-Host "Created Google OAuth client JSON: $target"
    Write-Host "Secret values were not printed."
}

function Invoke-GoogleAdcLogin {
    Ensure-LocalFiles | Out-Null
    Invoke-GoogleOAuthFile
    $envMap = Import-DotEnvMap -Path $EnvPath
    $gcloud = Get-GcloudCommand
    if (-not $gcloud) {
        Ensure-GoogleCloudCli
        $gcloud = Get-GcloudCommand
    }
    if (-not $gcloud) { throw "gcloud was not found. Run -Action Prereqs first." }

    $oauthJson = [Environment]::ExpandEnvironmentVariables($envMap["GOOGLE_ADC_CLIENT_JSON"])
    if (-not (Test-Path -LiteralPath $oauthJson)) {
        throw "Google ADC client JSON was not found: $oauthJson"
    }

    & $gcloud auth application-default login --scopes "https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform" --client-id-file $oauthJson
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $adcPaths = @(
        (Join-Path $env:APPDATA "gcloud\application_default_credentials.json"),
        (Join-Path $env:USERPROFILE ".config\gcloud\application_default_credentials.json")
    )
    foreach ($adcPath in $adcPaths) {
        if (Test-Path -LiteralPath $adcPath) {
            Set-DotEnvValue -Path $EnvPath -Key "GOOGLE_APPLICATION_CREDENTIALS" -Value $adcPath
            Write-Host "Saved GOOGLE_APPLICATION_CREDENTIALS path: $adcPath"
            return
        }
    }
    Write-Host "ADC login completed, but the credentials path was not detected automatically."
}

function Find-WinGetNodeDir {
    $packages = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (-not (Test-Path -LiteralPath $packages)) { return $null }
    $node = Get-ChildItem -Path $packages -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "OpenJS\.NodeJS\.LTS" } |
        Select-Object -First 1
    if ($node) { return Split-Path -Parent $node.FullName }
    return $null
}

function Ensure-NodeOnPath {
    $nodeDir = Find-WinGetNodeDir
    if ($nodeDir -and ($env:PATH -notlike "*$nodeDir*")) {
        $env:PATH = "$nodeDir;$env:PATH"
    }
}

function Get-GitCommand {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) { return $git.Source }

    $candidatePaths = @(
        (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidatePaths += (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe")
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Resolve-Npx {
    Ensure-NodeOnPath

    $nodeDir = Find-WinGetNodeDir
    if ($nodeDir) {
        $candidate = Join-Path $nodeDir "npx.cmd"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if ($npxCmd) { return $npxCmd.Source }

    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if ($npx) { return $npx.Source }

    throw "npx was not found. Run -Action Prereqs first."
}

function Resolve-Npm {
    Ensure-NodeOnPath

    $nodeDir = Find-WinGetNodeDir
    if ($nodeDir) {
        $candidate = Join-Path $nodeDir "npm.cmd"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($npmCmd) { return $npmCmd.Source }

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) { return $npm.Source }

    throw "npm was not found. Run -Action Prereqs first."
}

function Get-NpmLookupName {
    param([string]$PackageName)
    if ([string]::IsNullOrWhiteSpace($PackageName)) { return $null }

    $name = $PackageName.Trim()
    if ($name -match '^(@[^/]+/[^@]+)@.+$') { return $matches[1] }
    if ($name -match '^([^@]+)@.+$') { return $matches[1] }
    return $name
}

function Get-VersionLockKey {
    param([string]$ToolName, [string]$Provider)
    if ([string]::IsNullOrWhiteSpace($Provider)) { $Provider = "default" }
    return "$ToolName|$Provider"
}

function Read-VersionLock {
    param([string]$Path = $VersionLockPath)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ version = 1; entries = @{} }
    }
    $lock = ConvertTo-Hashtable (Read-JsonFile -Path $Path)
    if (-not $lock.ContainsKey("entries") -or $null -eq $lock["entries"]) { $lock["entries"] = @{} }
    return $lock
}

function Write-VersionLock {
    param($Lock)
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $Lock["version"] = 1
    $Lock["generatedAt"] = (Get-Date).ToString("o")
    Write-JsonFile -Object $Lock -Path $VersionLockPath
}

function New-VersionedPackageSpec {
    param([string]$Runner, [string]$PackageName, [string]$Version)
    if ($Runner -eq "pipx") { return "$PackageName==$Version" }
    return "$PackageName@$Version"
}

function Resolve-LockedPackageSpec {
    param([string]$ToolName, $Item, [switch]$AllowUnlocked, [string]$LockPath = $VersionLockPath)

    $package = [string]$Item.package
    if ([string]::IsNullOrWhiteSpace($package)) { return $package }
    $runner = [string]$Item.runner
    if ($runner -notin @("npx", "pipx")) { return $package }

    $provider = if ($Item.selectedProvider) { [string]$Item.selectedProvider } else { "default" }
    $lock = Read-VersionLock -Path $LockPath
    $key = Get-VersionLockKey -ToolName $ToolName -Provider $provider
    if ($lock["entries"].ContainsKey($key)) {
        $entry = $lock["entries"][$key]
        $expectedName = if ($runner -eq "npx") { Get-NpmLookupName -PackageName $package } else { $package -replace "==.*$", "" }
        if ([string]$entry["packageName"] -eq $expectedName -and -not [string]::IsNullOrWhiteSpace([string]$entry["resolvedPackage"])) {
            return [string]$entry["resolvedPackage"]
        }
    }

    if ($AllowUnlocked) { return $null }
    throw "No exact package lock exists for $ToolName [$provider]. Run -Action CheckMcpUpdates before Apply or launching this MCP."
}

function Invoke-PipxRun {
    param([string]$PackageName, [string[]]$Args = @())

    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if ($pipx) {
        & $pipx.Source run $PackageName @Args
        return
    }

    $python = Get-PythonCommand
    if ($python) {
        & $python -m pipx run $PackageName @Args
        return
    }

    throw "pipx was not found. Run -Action Prereqs first."
}

function Test-WindowsStorePythonAlias {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $windowsApps = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    return ($expanded -like (Join-Path $windowsApps "python*.exe"))
}

function Test-ExecutableWorks {
    param([string]$Path, [string[]]$CommandArgs = @("--version"))
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (Test-WindowsStorePythonAlias -Path $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $output = & $Path @CommandArgs 2>$null
        return ($? -and -not [string]::IsNullOrWhiteSpace(($output | Select-Object -First 1)))
    } catch {
        return $false
    }
}

function Test-CommandWorks {
    param([string]$Command, [string[]]$Args = @("--version"))
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    return (Test-ExecutableWorks -Path $cmd.Source -CommandArgs $Args)
}

function Assert-WinGetAvailable {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Install Windows Package Manager, then rerun this script."
    }
    Write-Host "winget: $(& winget --version)"
}

function Get-PythonCommand {
    if (Test-CommandWorks -Command "py") { return (Get-Command py).Source }

    $pathCandidates = @()
    $pythonCommands = @(Get-Command python.exe -All -ErrorAction SilentlyContinue) + @(Get-Command python -All -ErrorAction SilentlyContinue)
    foreach ($pythonCommand in $pythonCommands) {
        if ($pythonCommand.Source -and -not (Test-WindowsStorePythonAlias -Path $pythonCommand.Source)) {
            $pathCandidates += $pythonCommand.Source
        }
    }

    $localPythonRoot = Join-Path $env:LOCALAPPDATA "Programs\Python"
    if (Test-Path -LiteralPath $localPythonRoot) {
        $localCandidates = @(Get-ChildItem -Path $localPythonRoot -Recurse -Filter python.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object { $_.FullName })
        $launcherCandidates = @(Get-ChildItem -Path $localPythonRoot -Recurse -Filter py.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object { $_.FullName })
        $pathCandidates += $localCandidates
        $pathCandidates += $launcherCandidates
    }

    foreach ($candidate in ($pathCandidates | Select-Object -Unique)) {
        if (Test-ExecutableWorks -Path $candidate) { return $candidate }
    }

    return $null
}

function Get-GcloudCommand {
    if (Test-CommandWorks -Command "gcloud" -Args @("--version")) { return (Get-Command gcloud).Source }

    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA "Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"),
        (Join-Path $env:ProgramFiles "Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidatePaths += (Join-Path ${env:ProgramFiles(x86)} "Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd")
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Ensure-PythonAndPipx {
    Write-Step "Checking Python and pipx"
    $python = Get-PythonCommand
    if (-not $python) {
        Assert-WinGetAvailable
        winget install --id Python.Python.3.12 --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
        $python = Get-PythonCommand
    }
    if ($python) {
        $pythonDir = Split-Path -Parent $python
        $pythonScriptsDir = Join-Path $pythonDir "Scripts"
        $pythonFolderName = Split-Path -Leaf $pythonDir
        $roamingScriptsDir = Join-Path $env:APPDATA "Python\$pythonFolderName\Scripts"
        $userLocalBin = Join-Path $env:USERPROFILE ".local\bin"
        foreach ($pathToAdd in @($pythonDir, $pythonScriptsDir, $roamingScriptsDir, $userLocalBin)) {
            if ((Test-Path -LiteralPath $pathToAdd) -and $env:PATH -notlike "*$pathToAdd*") {
                $env:PATH = "$pathToAdd;$env:PATH"
            }
        }
    }

    $pipx = Get-Command pipx -ErrorAction SilentlyContinue
    if (-not $pipx) {
        if ($python) {
            & $python -m pip install --user --upgrade pipx
            & $python -m pipx ensurepath
        } else {
            throw "Python was installed but is not available in this shell yet. Open a new terminal and rerun -Action Prereqs."
        }
    } else {
        Write-Host "pipx: $(& $pipx.Source --version)"
    }
}

function Ensure-GoogleCloudCli {
    Write-Step "Checking Google Cloud CLI"
    $gcloud = Get-GcloudCommand
    if (-not $gcloud) {
        Assert-WinGetAvailable
        winget install --id Google.CloudSDK --source winget --silent --accept-package-agreements --accept-source-agreements
        $gcloud = Get-GcloudCommand
    } else {
        Write-Host "gcloud: $(& $gcloud --version | Select-Object -First 1)"
    }
    if ($gcloud) {
        $gcloudDir = Split-Path -Parent $gcloud
        if ($env:PATH -notlike "*$gcloudDir*") { $env:PATH = "$gcloudDir;$env:PATH" }
    }
}

function Invoke-ValidateKit {
    param([switch]$Quiet)

    $errors = @()
    $warnings = @()
    $requiredFiles = @(
        "README.md",
        "AGENTS.md",
        "SKILL.md",
        "agents\openai.yaml",
        ".gitignore",
        "config\mcp-catalog.json",
        "config\tool-selection.example.json",
        "config\client-capabilities.json",
        "secrets\.env.template",
        "scripts\WebAnalystSetup.ps1",
        "scripts\lib\CatalogReview.ps1",
        "scripts\lib\Connect.ps1",
        "scripts\lib\PesterTests.ps1",
        "scripts\lib\ReleaseAudit.ps1",
        "schemas\mcp-catalog.schema.json",
        "schemas\tool-selection.schema.json",
        "schemas\client-capabilities.schema.json",
        "schemas\onboarding-state.schema.json",
        "schemas\mcp-version-lock.schema.json",
        "tests\WebAnalystSetup.Tests.ps1",
        "docs\data-and-credential-safety.md",
        "CHANGELOG.md"
    )

    foreach ($relative in $requiredFiles) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path)) { $errors += "Missing required file: $relative" }
    }

    $catalog = $null
    $selectionExample = $null
    $clientCapabilities = $null
    foreach ($relative in @("config\mcp-catalog.json", "config\tool-selection.example.json", "config\client-capabilities.json", "schemas\mcp-catalog.schema.json", "schemas\tool-selection.schema.json", "schemas\client-capabilities.schema.json", "schemas\onboarding-state.schema.json", "schemas\mcp-version-lock.schema.json")) {
        $path = Join-Path $Root $relative
        if (Test-Path -LiteralPath $path) {
            try {
                $json = Read-JsonFile -Path $path
                if ($relative -eq "config\mcp-catalog.json") { $catalog = $json }
                if ($relative -eq "config\tool-selection.example.json") { $selectionExample = $json }
                if ($relative -eq "config\client-capabilities.json") { $clientCapabilities = $json }
            } catch {
                $errors += "Invalid JSON in $relative`: $($_.Exception.Message)"
            }
        }
    }

    $skillPath = Join-Path $Root "SKILL.md"
    if (Test-Path -LiteralPath $skillPath) {
        $skillText = Get-Content -Raw -LiteralPath $skillPath
        if ($skillText -notmatch "(?s)^---\s*\r?\nname:\s*web-analyst-mcp-setup\s*\r?\ndescription:\s*.+?\r?\n---") {
            $errors += "SKILL.md must contain only name and description in valid YAML frontmatter."
        }
    }
    $openAiMetadataPath = Join-Path $Root "agents\openai.yaml"
    if (Test-Path -LiteralPath $openAiMetadataPath) {
        $openAiMetadata = Get-Content -Raw -LiteralPath $openAiMetadataPath
        if ($openAiMetadata -notmatch "display_name:" -or $openAiMetadata -notmatch "short_description:" -or $openAiMetadata -notmatch '\$web-analyst-mcp-setup') {
            $errors += "agents\openai.yaml is missing required skill interface metadata."
        }
    }

    $scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root "scripts") -Recurse -Filter "*.ps1" -File)
    foreach ($scriptFile in $scriptFiles) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        foreach ($parseError in @($parseErrors)) {
            $relativeScript = $scriptFile.FullName.Substring($Root.Path.Length + 1)
            $errors += "PowerShell syntax error in $relativeScript at $($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
    }

    if ($catalog) {
        $requiredCatalogFields = @("displayName", "kind", "trustLevel", "lifecycleStatus", "recommendedUse", "fallbackWhen", "knownLimitations", "officialness", "authFriction", "runtime", "dataExposure", "writeCapability", "riskLevel", "lastVerified", "author", "source", "authMode", "serverName", "defaultProvider", "credentialKeys", "notes", "testPrompt")
        $validLifecycleStatuses = @("default", "fallback", "optional", "candidate", "private-beta", "api-fallback", "deprecated")
        foreach ($entry in $catalog.PSObject.Properties) {
            $item = $entry.Value
            foreach ($field in $requiredCatalogFields) {
                if (-not (Test-ObjectProperty -Object $item -Name $field)) {
                    $errors += "Catalog tool '$($entry.Name)' is missing field '$field'."
                }
            }
            if ((Test-ObjectProperty -Object $item -Name "lifecycleStatus") -and $validLifecycleStatuses -notcontains [string]$item.lifecycleStatus) {
                $errors += "Catalog tool '$($entry.Name)' has invalid lifecycleStatus '$($item.lifecycleStatus)'."
            }
            if ($item.kind -eq "mcp" -and $item.transport -eq "stdio" -and -not $item.package) {
                $errors += "Catalog tool '$($entry.Name)' is stdio MCP but has no package."
            }
            if ($item.runner -eq "npx" -and $item.package -and ([string]$item.package -notmatch "@latest$")) {
                $warnings += "Catalog tool '$($entry.Name)' uses npm package without @latest: $($item.package)"
            }
            if ($item.providers) {
                foreach ($provider in $item.providers.PSObject.Properties) {
                    foreach ($field in @("displayName", "trustLevel", "lifecycleStatus", "recommendedUse", "fallbackWhen", "knownLimitations", "officialness", "authFriction", "runtime", "dataExposure", "writeCapability", "riskLevel", "lastVerified", "authMode", "serverName", "notes", "testPrompt")) {
                        if (-not (Test-ObjectProperty -Object $provider.Value -Name $field)) {
                            $errors += "Catalog provider '$($entry.Name).$($provider.Name)' is missing field '$field'."
                        }
                    }
                    if ((Test-ObjectProperty -Object $provider.Value -Name "lifecycleStatus") -and $validLifecycleStatuses -notcontains [string]$provider.Value.lifecycleStatus) {
                        $errors += "Catalog provider '$($entry.Name).$($provider.Name)' has invalid lifecycleStatus '$($provider.Value.lifecycleStatus)'."
                    }
                }
            }
        }
    }

    if ($selectionExample -and $catalog) {
        foreach ($tool in $selectionExample.tools.PSObject.Properties) {
            if (-not (Test-ObjectProperty -Object $catalog -Name $tool.Name)) {
                $errors += "tool-selection.example.json references unknown tool '$($tool.Name)'."
                continue
            }
            $providerName = [string]$tool.Value.provider
            $catalogItem = $catalog.($tool.Name)
            $validProviders = @()
            if ($catalogItem.defaultProvider) { $validProviders += [string]$catalogItem.defaultProvider }
            if ($catalogItem.providers) { $validProviders += @(Get-PropertyNames -Object $catalogItem.providers) }
            if ($providerName -and $validProviders.Count -gt 0 -and $validProviders -notcontains $providerName) {
                $errors += "tool-selection.example.json uses invalid provider '$providerName' for '$($tool.Name)'."
            }
        }
    }

    if ($clientCapabilities) {
        foreach ($clientEntry in $clientCapabilities.clients.PSObject.Properties) {
            foreach ($field in @("displayName", "configTargets", "supportsRemoteHttp", "supportsProjectConfig", "supportsMcpLogin", "mcpLoginGuidance", "restartGuidance", "notes")) {
                if (-not (Test-ObjectProperty -Object $clientEntry.Value -Name $field)) {
                    $errors += "Client capability '$($clientEntry.Name)' is missing field '$field'."
                }
            }
        }
    }

    $gitignore = Join-Path $Root ".gitignore"
    if (Test-Path -LiteralPath $gitignore) {
        $ignoreText = Get-Content -Raw -LiteralPath $gitignore
        foreach ($pattern in @("secrets/*", "!secrets/.env.template", "config/tool-selection.json", "generated/*", "*.web-analyst-backup-*")) {
            if ($ignoreText -notmatch [regex]::Escape($pattern)) {
                $errors += ".gitignore does not protect '$pattern'."
            }
        }
    }

    $sensitivePatterns = @(
        "client_secret_\d+",
        "googleusercontent\.com",
        "C:\\Users\\[^\\]+",
        "Downloads\\[^\\]+",
        "refresh_token\s*[:=]",
        "private_key\s*[:=]",
        "project[_-]?id\s*[:=]\s*['""]?[a-z][a-z0-9-]{4,}[a-z0-9]",
        "GTM-[A-Z0-9]{6,}",
        "G-[A-Z0-9]{6,}",
        "UA-\d+-\d+"
    )
    $filesToScan = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch "\\.git\\" -and $_.FullName -notmatch "\\generated\\" -and $_.FullName -notmatch "\\secrets\\\.env\.local$" -and $_.FullName -ne $ScriptPath }
    foreach ($file in $filesToScan) {
        $contentLines = @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)
        foreach ($pattern in $sensitivePatterns) {
            if (@($contentLines | Where-Object { $_ -cmatch $pattern }).Count -gt 0) {
                $errors += "Sensitive or machine-specific pattern '$pattern' found in $($file.FullName.Substring($Root.Path.Length + 1))."
            }
        }
    }

    if (-not $Quiet) {
        foreach ($warning in $warnings) { Write-Warning $warning }
    }

    if ($errors.Count -gt 0) {
        if (-not $Quiet) {
            Write-Step "Validation failed"
            $errors | ForEach-Object { Write-Host "ERROR: $_" }
        }
        throw "Kit validation failed with $($errors.Count) error(s)."
    }

    if (-not $Quiet) {
        Write-Step "Validation"
        Write-Host "Validation passed."
        if ($warnings.Count -gt 0) { Write-Host "$($warnings.Count) warning(s) were reported." }
    }
}

function Invoke-Doctor {
    $rows = @()

    try {
        Invoke-ValidateKit -Quiet
        $rows += New-CheckResult -Area "Kit" -Check "Reusable files" -Status "OK" -Detail "Catalog, schemas, docs, and script validation passed."
    } catch {
        $rows += New-CheckResult -Area "Kit" -Check "Reusable files" -Status "FAIL" -Detail $_.Exception.Message
    }

    foreach ($target in @(
        @{ Name = "Local tool selection"; Path = $SelectionPath; Expected = "optional" },
        @{ Name = "Local env"; Path = $EnvPath; Expected = "optional" },
        @{ Name = "Generated MCP JSON"; Path = (Join-Path $GeneratedDir "mcp.json"); Expected = "ignored" },
        @{ Name = "Generated Codex TOML"; Path = (Join-Path $GeneratedDir "codex.config-snippet.toml"); Expected = "ignored" }
    )) {
        $exists = Test-Path -LiteralPath $target.Path
        $status = if ($exists) { "Present" } else { "Absent" }
        $detail = if ($exists) { "This is local runtime state and should stay ignored by git." } else { "Clean reusable state." }
        $rows += New-CheckResult -Area "Local state" -Check $target.Name -Status $status -Detail $detail
    }

    foreach ($commandName in @("winget", "node", "npm", "git", "python", "pipx", "gcloud", "codex", "claude", "gemini")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            $rows += New-CheckResult -Area "Prereq" -Check $commandName -Status "Found" -Detail $command.Source
        } else {
            $rows += New-CheckResult -Area "Prereq" -Check $commandName -Status "Missing" -Detail "Only needed when the selected tool/provider requires it."
        }
    }

    $browsers = @(Get-InstalledBrowserCandidates)
    if ($browsers.Count -gt 0) {
        $browserText = ($browsers | ForEach-Object {
            if ($_.IsDefault) { "$($_.Name) (default)" } else { $_.Name }
        }) -join ", "
        $rows += New-CheckResult -Area "Browser" -Check "Installed/default browser" -Status "Found" -Detail $browserText
    } else {
        $rows += New-CheckResult -Area "Browser" -Check "Installed/default browser" -Status "Missing" -Detail "Install or allow the helper to install a compatible browser before browser MCP tests."
    }

    $toolRows = @(Get-ToolStatusRows -UseExampleWhenLocalSelectionMissing | Where-Object { $_.Enabled })
    if ($toolRows.Count -gt 0) {
        foreach ($toolRow in $toolRows) {
            $rows += New-CheckResult -Area "Tool" -Check $toolRow.Tool -Status $toolRow.Status -Detail $toolRow.CredentialState
        }
    } else {
        $rows += New-CheckResult -Area "Tool" -Check "Enabled tools" -Status "None" -Detail "Choose tools with the user, then update config\tool-selection.json during onboarding."
    }

    Write-Step "Doctor"
    Write-Host (($rows | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
}

function Invoke-OnboardingReport {
    Write-Warning "OnboardingReport is retained for compatibility. Connect now produces the single setup summary."
    Write-SetupSummary | Out-Null
}

function Get-SelectedCatalogItems {
    Ensure-LocalFiles | Out-Null
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $items = @()
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }
        $items += [PSCustomObject]@{
            ToolName = $tool.Name
            Item = $item
        }
    }
    return $items
}

function Get-AllCatalogMcpItems {
    $catalog = Read-JsonFile -Path $CatalogPath
    $items = @()
    foreach ($entry in $catalog.PSObject.Properties) {
        $defaultProvider = if ($entry.Value.defaultProvider) { [string]$entry.Value.defaultProvider } else { "default" }
        $defaultItem = Resolve-CatalogItem -CatalogItem $entry.Value -Provider $defaultProvider
        if ($defaultItem -and $defaultItem.kind -eq "mcp") {
            $items += [PSCustomObject]@{ ToolName = $entry.Name; Item = $defaultItem }
        }
        if ($entry.Value.providers) {
            foreach ($provider in $entry.Value.providers.PSObject.Properties) {
                $providerItem = Resolve-CatalogItem -CatalogItem $entry.Value -Provider $provider.Name
                if ($providerItem -and $providerItem.kind -eq "mcp") {
                    $items += [PSCustomObject]@{ ToolName = $entry.Name; Item = $providerItem }
                }
            }
        }
    }
    return $items
}

function Get-PrerequisiteNeeds {
    param($SelectedItems, [bool]$IncludePython)
    $needsNode = $false
    $needsPython = $IncludePython
    $needsGcloud = $false
    foreach ($selected in @($SelectedItems)) {
        $item = $selected.Item
        if ($item.runner -eq "npx") { $needsNode = $true }
        if ($item.runner -eq "pipx") { $needsPython = $true }
        if ($item.authMode -in @("application_default_credentials", "company_oauth_adc")) { $needsGcloud = $true }
    }
    return [PSCustomObject]@{
        NeedsNode = $needsNode
        NeedsPython = $needsPython
        NeedsGcloud = $needsGcloud
    }
}

function Invoke-Prereqs {
    param([switch]$NoReport)

    $selectedItems = @(Get-SelectedCatalogItems)
    $needs = Get-PrerequisiteNeeds -SelectedItems $selectedItems -IncludePython ([bool]$InstallPython)

    if (-not $needs.NeedsNode -and -not $needs.NeedsPython -and -not $needs.NeedsGcloud) {
        Write-Host "No local system runtime is required by the selected providers."
    }

    if ($needs.NeedsNode) {
        Write-Step "Checking Node.js LTS"
        Ensure-NodeOnPath
        $node = Get-Command node -ErrorAction SilentlyContinue
        $nodeMajor = $null
        if ($node) {
            $raw = & node --version
            if ($raw -match "v(\d+)") { $nodeMajor = [int]$matches[1] }
        }
        if (-not $nodeMajor) {
            Assert-WinGetAvailable
            winget install --id OpenJS.NodeJS.LTS --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
        } elseif ($nodeMajor -lt 22) {
            Write-Host "node: $raw is below the supported Node.js 22+ LTS baseline; upgrading the selected prerequisite."
            Assert-WinGetAvailable
            winget upgrade --id OpenJS.NodeJS.LTS --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
        } else {
            Write-Host "node: $raw"
        }
        Ensure-NodeOnPath
        $npmCommand = Resolve-Npm
        Write-Host "npm: $(& $npmCommand --version)"
    } else {
        Write-Host "Node.js: not required by the selected providers."
    }

    if ($needs.NeedsPython) { Ensure-PythonAndPipx }
    if ($needs.NeedsGcloud) { Ensure-GoogleCloudCli }
    Invoke-CheckMcpUpdates -NoReport:$NoReport
}

function New-McpUpdateResult {
    param([string]$Tool, [string]$Provider, [string]$Check, [string]$Status, [string]$Detail)
    return [PSCustomObject]@{
        Tool = $Tool
        Provider = $Provider
        Check = $Check
        Status = $Status
        Detail = $Detail
    }
}

function Get-CatalogReviewWindowDays {
    param([string]$LifecycleStatus)
    switch ($LifecycleStatus) {
        { $_ -in @("candidate", "private-beta") } { return 30 }
        { $_ -in @("default", "fallback") } { return 60 }
        { $_ -in @("optional", "api-fallback") } { return 90 }
        "deprecated" { return 180 }
        default { return 60 }
    }
}

function Get-CatalogFreshnessStatus {
    param($Item)
    $lastVerified = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact([string]$Item.lastVerified, "yyyy-MM-dd", $null, [System.Globalization.DateTimeStyles]::None, [ref]$lastVerified)) {
        return "Invalid lastVerified: $($Item.lastVerified)"
    }
    $ageDays = [int]((Get-Date) - $lastVerified).TotalDays
    $reviewDays = Get-CatalogReviewWindowDays -LifecycleStatus ([string]$Item.lifecycleStatus)
    if ($ageDays -gt ($reviewDays * 2)) { return "Stale: verified $ageDays days ago; $reviewDays-day review window" }
    if ($ageDays -gt $reviewDays) { return "Aging: verified $ageDays days ago; $reviewDays-day review window" }
    return "Fresh: verified $ageDays days ago; $reviewDays-day review window"
}

function Get-McpEndpointUrl {
    param($Item, $EnvMap)
    $url = [string]$Item.url
    if (-not $url -and $Item.urlEnvKey) {
        $urlKey = [string]$Item.urlEnvKey
        if ($EnvMap.ContainsKey($urlKey)) { $url = [string]$EnvMap[$urlKey] }
    }
    if (-not $url -and $Item.startArgs) {
        $url = [string](@($Item.startArgs | Where-Object { [string]$_ -match "^https?://" } | Select-Object -First 1))
    }
    return $url
}

function Test-McpEndpointReachability {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return "No endpoint URL in catalog or env." }
    try {
        $response = Invoke-WebRequest -Method Head -Uri $Url -TimeoutSec 12 -MaximumRedirection 3 -UseBasicParsing
        return "Reachable: HTTP $([int]$response.StatusCode)"
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            if ($statusCode -in @(401, 403, 405)) {
                return "Endpoint responded: HTTP $statusCode (auth or method restriction expected for some MCP endpoints)"
            }
        }
        try {
            $response = Invoke-WebRequest -Method Get -Uri $Url -TimeoutSec 12 -MaximumRedirection 3 -UseBasicParsing
            return "Reachable by GET: HTTP $([int]$response.StatusCode)"
        } catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                if ($statusCode -in @(401, 403, 405)) {
                    return "Endpoint responded: HTTP $statusCode (auth or method restriction expected for some MCP endpoints)"
                }
            }
            return "Not reachable now: $($_.Exception.Message)"
        }
    }
}

function Write-McpUpdateReport {
    param($Rows)
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $reportPath = Join-Path $GeneratedDir "mcp-update-check.md"
    $lines = @()
    $lines += "# MCP Update Check"
    $lines += ""
    $lines += "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))"
    $lines += ""
    $lines += "This report checks selected MCP package freshness, remote endpoint reachability, and catalog verification age. It does not include credentials."
    $lines += ""
    $lines += "| Tool | Provider | Check | Status | Detail |"
    $lines += "| --- | --- | --- | --- | --- |"
    foreach ($row in $Rows) {
        $detail = ([string]$row.Detail) -replace "\|", "/"
        $lines += "| $($row.Tool) | $($row.Provider) | $($row.Check) | $($row.Status) | $detail |"
    }
    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    Write-Host "Wrote MCP update report: $reportPath"
}

function Invoke-CheckMcpUpdates {
    param([switch]$NoReport)

    $selectedItems = if ($AllCatalogProviders) { @(Get-AllCatalogMcpItems) } else { @(Get-SelectedCatalogItems | Where-Object { $_.Item.kind -eq "mcp" }) }
    $envMap = Import-DotEnvMap -Path $EnvPath
    $rows = @()
    $lock = Read-VersionLock

    Write-Step "Checking MCP package updates"
    if ($selectedItems.Count -eq 0) {
        Write-Host "No enabled MCP tools in config\tool-selection.json."
        return
    }

    $npm = $null
    foreach ($selected in $selectedItems) {
        $item = $selected.Item
        $transport = [string]$item.transport
        if (-not $transport) { $transport = "stdio" }

        $provider = [string]$item.selectedProvider
        if (-not $provider) { $provider = "default" }
        $tool = [string]$selected.ToolName
        $label = "$($item.displayName) [$provider]"

        $freshness = Get-CatalogFreshnessStatus -Item $item
        $freshStatus = if ($freshness -like "Fresh:*") { "OK" } elseif ($freshness -like "Aging:*") { "Review soon" } else { "Review" }
        $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "catalog verification" -Status $freshStatus -Detail $freshness

        $endpointUrl = Get-McpEndpointUrl -Item $item -EnvMap $envMap
        if ($transport -eq "http" -or ($item.package -and [string]$item.package -like "mcp-remote*") -or $endpointUrl) {
            $reachability = Test-McpEndpointReachability -Url $endpointUrl
            $reachStatus = if ($reachability -like "Reachable*" -or $reachability -like "Endpoint responded:*") { "OK" } elseif ($reachability -eq "No endpoint URL in catalog or env.") { "No URL" } else { "Check" }
            $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "remote endpoint" -Status $reachStatus -Detail $reachability
        }

        $runner = [string]$item.runner
        if (-not $runner) { $runner = "npx" }

        if ($transport -eq "http" -and -not $item.package) {
            Write-Host "$label`: remote MCP; package updates are handled by the provider."
            continue
        }

        if ($runner -eq "npx") {
            if (-not $item.package) {
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "npm package" -Status "Check" -Detail "npx MCP without a package value; check catalog entry."
                continue
            }

            if (-not $npm) {
                try {
                    $npm = Resolve-Npm
                } catch {
                    $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "npm package" -Status "Skipped" -Detail "npm is not available yet; run Prereqs before installing MCPs."
                    continue
                }
            }

            $lookupName = Get-NpmLookupName -PackageName ([string]$item.package)
            try {
                $latestRaw = & $npm view $lookupName version --json 2>$null
                if ($LASTEXITCODE -ne 0) { throw "npm view failed" }
                $latest = (($latestRaw -join "`n").Trim() -replace '^"|"$', '')
                if ([string]::IsNullOrWhiteSpace($latest)) { throw "npm did not return a version" }

                $mode = if ([string]$item.package -match '@latest$') { "uses @latest" } else { "not pinned to @latest" }
                $resolvedPackage = New-VersionedPackageSpec -Runner "npx" -PackageName $lookupName -Version $latest
                $key = Get-VersionLockKey -ToolName $tool -Provider $provider
                $lock["entries"][$key] = @{
                    tool = $tool
                    provider = $provider
                    runner = "npx"
                    packageName = $lookupName
                    version = $latest
                    resolvedPackage = $resolvedPackage
                    checkedAt = (Get-Date).ToString("o")
                }
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "npm package" -Status "Locked" -Detail "npm latest $latest; exact launch package $resolvedPackage ($mode)."
            } catch {
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "npm package" -Status "Check" -Detail "Could not check npm package $lookupName. Verify the package source before installing."
            }
            continue
        }

        if ($runner -eq "pipx") {
            try {
                $packageName = ([string]$item.package -replace "==.*$", "")
                $pypiResponse = Invoke-RestMethod -Method Get -Uri "https://pypi.org/pypi/$packageName/json" -TimeoutSec 15
                $latest = [string]$pypiResponse.info.version
                if ([string]::IsNullOrWhiteSpace($latest)) { throw "PyPI did not return a version" }
                $resolvedPackage = New-VersionedPackageSpec -Runner "pipx" -PackageName $packageName -Version $latest
                $key = Get-VersionLockKey -ToolName $tool -Provider $provider
                $lock["entries"][$key] = @{
                    tool = $tool
                    provider = $provider
                    runner = "pipx"
                    packageName = $packageName
                    version = $latest
                    resolvedPackage = $resolvedPackage
                    checkedAt = (Get-Date).ToString("o")
                }
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "PyPI package" -Status "Locked" -Detail "PyPI latest $latest; exact launch package $resolvedPackage."
            } catch {
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "PyPI package" -Status "Check" -Detail "Could not check pip package $($item.package). Verify the package source before installing."
            }
            continue
        }

        $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "package" -Status "Skipped" -Detail "Runner $runner is not covered by the update checker yet."
    }

    Write-Host (($rows | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
    Write-VersionLock -Lock $lock
    Write-Host "Wrote exact MCP package lock: $VersionLockPath"
    if (-not $NoReport) { Write-McpUpdateReport -Rows $rows }
}

function Get-GoogleApiLibraryUrl {
    param([string]$Service)
    if ([string]::IsNullOrWhiteSpace($Service)) { return "" }
    return "https://console.cloud.google.com/apis/library/$Service"
}

function Join-MarkdownList {
    param([object[]]$Values)
    $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0) { return "" }
    return ($items -join "<br>")
}

function Invoke-CredentialGuide {
    Ensure-LocalFiles | Out-Null
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $guidePath = Join-Path $GeneratedDir "credential-guide.md"
    $selectedItems = @(Get-SelectedCatalogItems)

    $lines = @()
    $lines += "# Credential Setup Guide"
    $lines += ""
    $lines += "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))"
    $lines += ""
    $lines += "This guide is generated from the selected tools. It provides direct setup URLs and names credential keys only; it does not print secret values."
    $lines += ""

    if ($selectedItems.Count -eq 0) {
        $lines += 'No tools are enabled yet. Choose tools, then rerun `CredentialGuide`.'
        Set-Content -LiteralPath $guidePath -Value $lines -Encoding UTF8
        Write-Host "Wrote credential guide: $guidePath"
        return
    }

    $googleServices = @()
    $googleScopes = @()
    $oauthNeeded = $false
    $bigQuerySelected = $false
    $rows = @()

    foreach ($selected in $selectedItems) {
        $item = $selected.Item
        $credentialKeys = @($item.credentialKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $optionalKeys = @($item.optionalCredentialKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $services = @($item.requiredGoogleServices | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $scopes = @($item.requiredScopes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $googleServices += $services
        $googleScopes += $scopes
        if (($credentialKeys + $optionalKeys) -match "GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET|GOOGLE_OAUTH_CLIENT_JSON|GOOGLE_ADC_CLIENT_JSON" -or [string]$item.authMode -match "oauth|adc") {
            $oauthNeeded = $true
        }
        if ($selected.ToolName -eq "bigQuery") { $bigQuerySelected = $true }
        $rows += [PSCustomObject]@{
            Tool = [string]$item.displayName
            Provider = if ($item.selectedProvider) { [string]$item.selectedProvider } else { "default" }
            Auth = [string]$item.authMode
            CredentialKeys = Join-MarkdownList $credentialKeys
            OptionalKeys = Join-MarkdownList $optionalKeys
            Services = Join-MarkdownList $services
            Scopes = Join-MarkdownList $scopes
        }
    }

    $googleServices = @($googleServices | Select-Object -Unique | Sort-Object)
    $googleScopes = @($googleScopes | Select-Object -Unique | Sort-Object)

    $lines += "## Direct URLs"
    $lines += ""
    $lines += "- Google Cloud project selector: https://console.cloud.google.com/projectselector2/home/dashboard"
    $lines += "- Google Cloud API Library: https://console.cloud.google.com/apis/library"
    if ($oauthNeeded) {
        $lines += "- Google Auth Platform overview: https://console.cloud.google.com/auth/overview"
        $lines += "- OAuth app branding: https://console.cloud.google.com/auth/branding"
        $lines += "- OAuth audience/test users: https://console.cloud.google.com/auth/audience"
        $lines += "- OAuth clients: https://console.cloud.google.com/auth/clients"
        $lines += "- OAuth scopes/data access if Google asks for scope declaration: https://console.cloud.google.com/auth/scopes"
    }
    if ($bigQuerySelected) {
        $lines += "- BigQuery console: https://console.cloud.google.com/bigquery"
        $lines += "- IAM access: https://console.cloud.google.com/iam-admin/iam"
    }
    $lines += ""

    if ($googleServices.Count -gt 0) {
        $lines += "## Google APIs To Enable"
        $lines += ""
        foreach ($service in $googleServices) {
            $lines += "- ``$service``: $(Get-GoogleApiLibraryUrl -Service $service)"
        }
        $lines += ""
    }

    if ($googleScopes.Count -gt 0) {
        $lines += "## OAuth Scopes Requested By Selected Routes"
        $lines += ""
        foreach ($scope in $googleScopes) { $lines += "- ``$scope``" }
        $lines += ""
        $lines += "For local third-party Drive/Gmail MCPs, the user grants scopes during browser OAuth. The Cloud project still needs the underlying APIs enabled, but IAM roles do not replace browser OAuth scopes."
        $lines += ""
    }

    $lines += "## Selected Tool Credential Matrix"
    $lines += ""
    $lines += "| Tool | Provider | Auth route | Required local keys | Optional/local helper keys | Google services | Scopes |"
    $lines += "| --- | --- | --- | --- | --- | --- | --- |"
    foreach ($row in $rows) {
        $lines += "| $($row.Tool) | $($row.Provider) | $($row.Auth) | $($row.CredentialKeys) | $($row.OptionalKeys) | $($row.Services) | $($row.Scopes) |"
    }
    $lines += ""

    $lines += "## Conversation Steps"
    $lines += ""
    $lines += "1. Use credentials or vault items authorized for the intended account first."
    $lines += "2. If Google OAuth credentials are missing and the account owner or applicable organizational policy permits a new project, open the project selector URL, create/select the project, then enable only the APIs listed above."
    $lines += "3. Configure Google Auth Platform only when the selected route needs Google OAuth client credentials. Create a Desktop/installed-app OAuth client unless the selected MCP documentation explicitly requires another client type."
    $lines += "4. Copy only the client ID/secret values into ignored local setup, or point the kit to an ignored OAuth JSON file. Do not paste secrets into reusable docs."
    $lines += "5. For BigQuery, request project/dataset IDs and least-privilege IAM separately from OAuth scopes."
    $lines += '6. Return to the setup conversation and run `Dashboard`, then the relevant auth command.'
    $lines += ""

    Set-Content -LiteralPath $guidePath -Value $lines -Encoding UTF8
    Write-Step "Credential guide"
    Write-Host "Wrote credential guide: $guidePath"
    Write-Host "Direct URLs and selected credential keys are ready for the conversation."
}

function Invoke-BigQuerySafetyPlan {
    Ensure-LocalFiles | Out-Null
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $planPath = Join-Path $GeneratedDir "bigquery-safety-plan.md"
    $envMap = Import-DotEnvMap -Path $EnvPath
    $projectId = ""
    foreach ($key in @("BIGQUERY_PROJECT_ID", "GOOGLE_PROJECT_ID")) {
        if ($envMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($envMap[$key])) {
            $projectId = [string]$envMap[$key]
            break
        }
    }
    $datasets = if ($envMap.ContainsKey("BIGQUERY_DATASETS")) { [string]$envMap["BIGQUERY_DATASETS"] } else { "" }
    $region = if ($envMap.ContainsKey("BIGQUERY_REGION")) { [string]$envMap["BIGQUERY_REGION"] } else { "" }
    $maxBytes = if ($envMap.ContainsKey("BIGQUERY_MAX_BYTES_BILLED")) { [string]$envMap["BIGQUERY_MAX_BYTES_BILLED"] } else { "" }

    $projectLabel = if ($projectId) { $projectId } else { "<project-id>" }
    $datasetLabel = if ($datasets) { $datasets } else { "<dataset-id>" }
    $maxBytesLabel = if ($maxBytes) { $maxBytes } else { "<max-bytes-billed>" }

    $lines = @()
    $lines += "# BigQuery Safety Plan"
    $lines += ""
    $lines += "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))"
    $lines += ""
    $lines += "Use this before running BigQuery through an MCP, direct API, or CLI. It is designed for read-only first-day analytics work."
    $lines += ""
    $lines += "## Current Local Context"
    $lines += ""
    $lines += "- Project: $projectLabel"
    $lines += "- Approved datasets: $datasetLabel"
    $lines += "- Region/location: $(if ($region) { $region } else { '<confirm before querying>' })"
    $lines += "- Max bytes billed guardrail: $maxBytesLabel"
    $lines += ""
    $lines += "## Guardrails"
    $lines += ""
    $lines += "1. Confirm project, dataset, table pattern, region, date range, and whether the query is read-only."
    $lines += "2. Start with metadata listing: projects, datasets, tables, schema, and partition fields."
    $lines += "3. Use partition filters on date-sharded or partitioned tables before aggregation."
    $lines += '4. Add a small `LIMIT` for exploration. Do not use `LIMIT` as a cost control by itself.'
    $lines += "5. Run a dry-run or estimate first when the tool supports it."
    $lines += "6. Ask for explicit approval before broad scans, expensive estimates, write/create/export jobs, or queries outside the approved datasets."
    $lines += ""
    $lines += "## CLI Dry-Run Templates"
    $lines += ""
    $tablePlaceholder = "$projectLabel.$datasetLabel.<table>"
    $lines += '```powershell'
    $lines += "bq query --use_legacy_sql=false --dry_run --project_id `"$projectLabel`" `"SELECT 1`""
    $lines += "bq query --use_legacy_sql=false --dry_run --maximum_bytes_billed $maxBytesLabel --project_id `"$projectLabel`" `"SELECT * FROM $tablePlaceholder WHERE <partition_date> BETWEEN 'YYYY-MM-DD' AND 'YYYY-MM-DD' LIMIT 100`""
    $lines += '```'
    $lines += ""
    $lines += "## MCP Prompt Template"
    $lines += ""
    $lines += '```text'
    $lines += "Use BigQuery in read-only mode. First list metadata for project $projectLabel and approved dataset(s) $datasetLabel. Before running SQL, show the project, dataset, table, date filter, whether a dry-run/estimate is available, and expected cost or bytes if the tool exposes it. Use partition filters and LIMIT 100 for exploration. Ask before broad/costly queries or anything outside the approved dataset list."
    $lines += '```'
    $lines += ""
    $lines += "## Approval Triggers"
    $lines += ""
    $lines += "- No project or dataset ID has been confirmed."
    $lines += "- Query scans wildcard, unpartitioned, or unknown-size tables."
    $lines += "- Estimated bytes exceed the user- or organization-set guardrail."
    $lines += "- Query writes, creates, exports, loads, deletes, updates, merges, or calls procedures."
    $lines += "- Query touches personal data or sensitive customer data beyond the stated task."

    Set-Content -LiteralPath $planPath -Value $lines -Encoding UTF8
    Write-Step "BigQuery safety plan"
    Write-Host "Wrote BigQuery safety plan: $planPath"
    Write-Host "Use metadata and dry-run checks before any real query."
}

function Get-DefaultHttpsBrowserProgId {
    try {
        return [string](Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -ErrorAction Stop).ProgId
    } catch {
        return ""
    }
}

function Get-InstalledBrowserCandidates {
    $candidates = @()

    $browserDefinitions = @(
        @{
            Name = "Microsoft Edge"
            PlaywrightBrowser = "msedge"
            DefaultPatterns = @("MSEdgeHTM")
            DevToolsCompatible = $true
            Paths = @(
                (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\Application\msedge.exe"),
                (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe")
            )
        },
        @{
            Name = "Google Chrome"
            PlaywrightBrowser = "chrome"
            DefaultPatterns = @("ChromeHTML")
            DevToolsCompatible = $true
            Paths = @(
                (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe"),
                (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe")
            )
        },
        @{
            Name = "Brave"
            PlaywrightBrowser = ""
            DefaultPatterns = @("BraveHTML")
            DevToolsCompatible = $true
            Paths = @(
                (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\Application\brave.exe"),
                (Join-Path $env:ProgramFiles "BraveSoftware\Brave-Browser\Application\brave.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "BraveSoftware\Brave-Browser\Application\brave.exe")
            )
        },
        @{
            Name = "Firefox"
            PlaywrightBrowser = "firefox"
            DefaultPatterns = @("FirefoxURL")
            DevToolsCompatible = $false
            Paths = @(
                (Join-Path $env:LOCALAPPDATA "Mozilla Firefox\firefox.exe"),
                (Join-Path $env:ProgramFiles "Mozilla Firefox\firefox.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "Mozilla Firefox\firefox.exe")
            )
        }
    )

    $defaultProgId = Get-DefaultHttpsBrowserProgId
    foreach ($definition in $browserDefinitions) {
        foreach ($path in @($definition.Paths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
            if (Test-Path -LiteralPath $path) {
                $isDefault = $false
                foreach ($pattern in $definition.DefaultPatterns) {
                    if ($defaultProgId -like "$pattern*") { $isDefault = $true }
                }
                $candidates += [PSCustomObject]@{
                    Name = [string]$definition.Name
                    PlaywrightBrowser = [string]$definition.PlaywrightBrowser
                    Path = [string]$path
                    DevToolsCompatible = [bool]$definition.DevToolsCompatible
                    IsDefault = $isDefault
                }
                break
            }
        }
    }

    return $candidates
}

function Get-PreferredBrowserCandidate {
    param([switch]$RequireDevTools)
    $candidates = @(Get-InstalledBrowserCandidates)
    if ($RequireDevTools) {
        $candidates = @($candidates | Where-Object { $_.DevToolsCompatible })
    }
    if ($candidates.Count -eq 0) { return $null }

    $default = @($candidates | Where-Object { $_.IsDefault } | Select-Object -First 1)
    if ($default.Count -gt 0) { return $default[0] }
    return @($candidates | Select-Object -First 1)[0]
}

function Get-EffectiveStartArgs {
    param($Item, [string]$ToolName)
    $startArgs = @()
    if ($null -ne $Item.startArgs) {
        $startArgs = @(@($Item.startArgs) | Where-Object { $null -ne $_ -and "$_".Length -gt 0 })
    }

    if ($ToolName -eq "browserQa") {
        $browser = Get-PreferredBrowserCandidate
        if ($browser) {
            if (-not [string]::IsNullOrWhiteSpace($browser.PlaywrightBrowser)) {
                if ($startArgs -notcontains "--browser") {
                    $startArgs += @("--browser", $browser.PlaywrightBrowser)
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($browser.Path)) {
                if ($startArgs -notcontains "--executable-path") {
                    $startArgs += @("--executable-path", $browser.Path)
                }
            }
        }
    }

    if ($ToolName -eq "browserDebug") {
        $browser = Get-PreferredBrowserCandidate -RequireDevTools
        if ($browser -and -not [string]::IsNullOrWhiteSpace($browser.Path) -and $startArgs -notcontains "--executablePath") {
            $startArgs += @("--executablePath", $browser.Path)
        }
    }

    return $startArgs
}

function Get-EnabledMcpServers {
    param([switch]$SkipUnavailable)

    Ensure-LocalFiles | Out-Null
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $envMap = Import-DotEnvMap -Path $EnvPath
    $servers = @()

    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }
        if ($item.kind -ne "mcp") { continue }

        $transport = [string]$item.transport
        if (-not $transport) { $transport = "stdio" }

        $runner = [string]$item.runner
        if (-not $runner) { $runner = "npx" }

        $url = [string]$item.url
        if (-not $url -and $item.urlEnvKey) {
            $urlKey = [string]$item.urlEnvKey
            if ($envMap.ContainsKey($urlKey)) { $url = [string]$envMap[$urlKey] }
        }

        if ($transport -eq "http" -and -not $url) {
            Write-Warning "Skipping $($tool.Name): missing MCP URL. Fill $($item.urlEnvKey) first."
            continue
        }

        if ($transport -eq "stdio" -and -not $item.package) { continue }

        $startArgs = @(Get-EffectiveStartArgs -Item $item -ToolName $tool.Name)

        $requiredScopes = @()
        if ($null -ne $item.requiredScopes) {
            $requiredScopes = @($item.requiredScopes) | Where-Object { $null -ne $_ -and "$_".Length -gt 0 }
        }

        $lockedPackage = ""
        try {
            $lockedPackage = [string](Resolve-LockedPackageSpec -ToolName $tool.Name -Item $item)
        } catch {
            if ($SkipUnavailable) {
                Write-Warning "Skipping $($tool.Name): $($_.Exception.Message)"
                continue
            }
            throw
        }

        $servers += [PSCustomObject]@{
            ToolName = $tool.Name
            ServerName = [string]$item.serverName
            Transport = $transport
            Runner = $runner
            Package = $lockedPackage
            Url = $url
            StartArgs = $startArgs
            RequiredScopes = $requiredScopes
            BearerTokenEnvVar = [string]$item.bearerTokenEnvVar
            DisplayName = [string]$item.displayName
        }
    }
    return $servers
}

function ConvertTo-McpArgsJson {
    param([string[]]$Values)
    $safeValues = @($Values | ForEach-Object { [string]$_ })
    return (ConvertTo-Json -InputObject $safeValues -Compress -Depth 5)
}

function ConvertTo-McpArgsBase64 {
    param([string[]]$Values)
    $json = ConvertTo-McpArgsJson @($Values)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Get-RunMcpLauncherArgs {
    param($Server, [switch]$WithoutToolIdentity)

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ScriptPath,
        "-Action",
        "RunMcp",
        "-ServerName",
        $Server.ServerName,
        "-Runner",
        $Server.Runner,
        "-Package",
        $Server.Package
    )

    if (-not $WithoutToolIdentity -and -not [string]::IsNullOrWhiteSpace([string]$Server.ToolName)) {
        $args += "-ToolName"
        $args += [string]$Server.ToolName
    }

    if ($Server.StartArgs.Count -gt 0) {
        $args += "-McpArgsBase64"
        $args += (ConvertTo-McpArgsBase64 @($Server.StartArgs))
    }

    return $args
}

function Get-EffectiveMcpArgsForRun {
    $effectiveArgs = @()
    if ($McpArgs.Count -gt 0) {
        $effectiveArgs += @($McpArgs | ForEach-Object { [string]$_ })
    }

    if (-not [string]::IsNullOrWhiteSpace($McpArgsJson)) {
        try {
            $decoded = ConvertFrom-Json -InputObject $McpArgsJson
            $effectiveArgs += @($decoded | ForEach-Object { [string]$_ })
        } catch {
            throw "Invalid -McpArgsJson value. Expected a JSON string array."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($McpArgsBase64)) {
        try {
            $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($McpArgsBase64))
            $decoded = ConvertFrom-Json -InputObject $json
            $effectiveArgs += @($decoded | ForEach-Object { [string]$_ })
        } catch {
            throw "Invalid -McpArgsBase64 value. Expected base64-encoded JSON string array."
        }
    }

    return $effectiveArgs
}

function Get-CatalogServerNames {
    $names = @()
    if (Test-Path -LiteralPath $CatalogPath) {
        $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
        foreach ($tool in $catalog.PSObject.Properties) {
            $serverName = [string]$tool.Value.serverName
            if (-not [string]::IsNullOrWhiteSpace($serverName)) {
                $names += $serverName
            }
            if ($tool.Value.providers) {
                foreach ($provider in $tool.Value.providers.PSObject.Properties) {
                    $providerServerName = [string]$provider.Value.serverName
                    if (-not [string]::IsNullOrWhiteSpace($providerServerName)) {
                        $names += $providerServerName
                    }
                }
            }
        }
    }
    return @($names | Select-Object -Unique)
}

function New-McpJsonObject {
    param(
        $Servers,
        [ValidateSet("Claude", "Gemini")]
        [string]$ClientName = "Claude"
    )
    $mcpServers = @{}
    foreach ($server in $Servers) {
        if ($server.Transport -eq "http") {
            if ($ClientName -eq "Gemini") {
                $mcpServers[$server.ServerName] = @{ httpUrl = $server.Url }
            } else {
                $mcpServers[$server.ServerName] = @{ type = "http"; url = $server.Url }
            }
            if (-not [string]::IsNullOrWhiteSpace($server.BearerTokenEnvVar)) {
                $mcpServers[$server.ServerName].headers = @{
                    Authorization = 'Bearer ${' + $server.BearerTokenEnvVar + '}'
                }
            }
        } else {
            $mcpServers[$server.ServerName] = @{
                command = "powershell.exe"
                args = @(Get-RunMcpLauncherArgs -Server $server)
            }
        }
    }
    return @{ mcpServers = $mcpServers }
}

function ConvertTo-TomlString {
    param([string]$Value)
    $escaped = $Value -replace "\\", "\\" -replace '"', '\"'
    return '"' + $escaped + '"'
}

function ConvertTo-TomlArray {
    param([string[]]$Values)
    return "[" + (($Values | ForEach-Object { ConvertTo-TomlString $_ }) -join ", ") + "]"
}

function New-CodexToml {
    param($Servers, [switch]$WithoutToolIdentity)
    $lines = @()
    $lines += "# BEGIN WEB_ANALYST_MCP_MANAGED"
    foreach ($server in $Servers) {
        $lines += "[mcp_servers.$($server.ServerName)]"
        if ($server.Transport -eq "http") {
            $lines += "url = " + (ConvertTo-TomlString $server.Url)
            if (-not [string]::IsNullOrWhiteSpace($server.BearerTokenEnvVar)) {
                $lines += "bearer_token_env_var = " + (ConvertTo-TomlString $server.BearerTokenEnvVar)
            }
            if ($server.RequiredScopes.Count -gt 0) {
                $lines += "scopes = " + (ConvertTo-TomlArray @($server.RequiredScopes))
            }
        } else {
            $baseArgs = @(Get-RunMcpLauncherArgs -Server $server -WithoutToolIdentity:$WithoutToolIdentity)
            $args = $baseArgs | ForEach-Object { ConvertTo-TomlString $_ }
            $lines += "command = " + (ConvertTo-TomlString "powershell.exe")
            $lines += "args = [$($args -join ', ')]"
        }
        $lines += "enabled = true"
        $lines += ""
    }
    $lines += "# END WEB_ANALYST_MCP_MANAGED"
    return ($lines -join [Environment]::NewLine)
}

function Test-McpServerConfiguredForClient {
    param([string]$ClientName, [string]$Path, [string]$ServerName)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    if ($ClientName -eq "Codex") {
        $content = Get-Content -Raw -LiteralPath $Path
        $match = [regex]::Match($content, "(?s)# BEGIN WEB_ANALYST_MCP_MANAGED(.*?)# END WEB_ANALYST_MCP_MANAGED")
        if (-not $match.Success) { return $false }
        return $match.Groups[1].Value -match "(?m)^\[mcp_servers\.$([regex]::Escape($ServerName))\]\s*$"
    }

    try {
        $json = ConvertTo-Hashtable (Read-JsonFile -Path $Path)
        return $json.ContainsKey("mcpServers") -and $json["mcpServers"].ContainsKey($ServerName)
    } catch {
        return $false
    }
}

function Get-McpConfiguredSummary {
    param($Selection, [string]$ServerName)
    $clients = @(Resolve-TargetClients -Selection $Selection -RequestedClient "Selected")
    $parts = @()
    $allConfigured = $true
    foreach ($clientName in $clients) {
        $path = Get-ClientConfigTarget -ClientName $clientName -Selection $Selection
        $configured = Test-McpServerConfiguredForClient -ClientName $clientName -Path $path -ServerName $ServerName
        if (-not $configured) { $allConfigured = $false }
        $parts += "$clientName`: " + $(if ($configured) { "configured" } else { "not configured" })
    }
    return [PSCustomObject]@{
        AllConfigured = $allConfigured
        Summary = $parts -join "; "
    }
}

function Get-CodexManagedBlock {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $content = Get-Content -Raw -LiteralPath $Path
    $beginCount = ([regex]::Matches($content, "# BEGIN WEB_ANALYST_MCP_MANAGED")).Count
    $endCount = ([regex]::Matches($content, "# END WEB_ANALYST_MCP_MANAGED")).Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) {
        throw "Codex config $Path contains malformed or duplicate web-analyst managed-block markers. Resolve them explicitly before Apply or reset."
    }
    if ($beginCount -eq 0) { return $null }

    $match = [regex]::Match($content, "(?s)# BEGIN WEB_ANALYST_MCP_MANAGED.*?# END WEB_ANALYST_MCP_MANAGED")
    if (-not $match.Success) {
        throw "Codex config $Path contains an unreadable web-analyst managed block. Resolve it explicitly before Apply or reset."
    }
    return $match.Value
}

function Update-ManagedTextBlock {
    param(
        [string]$Path,
        [string]$Block,
        [string]$ExpectedFingerprint,
        [switch]$PreviewOnly
    )

    $currentBlock = Get-CodexManagedBlock -Path $Path
    $desiredFingerprint = Get-ObjectFingerprint -InputObject $Block
    if ($null -ne $currentBlock) {
        $currentFingerprint = Get-ObjectFingerprint -InputObject $currentBlock
        if (-not [string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
            if ($currentFingerprint -ne $ExpectedFingerprint) {
                throw "Codex config $Path contains a user-modified managed block. The kit will not overwrite it."
            }
        } elseif ($currentFingerprint -ne $desiredFingerprint) {
            throw "Codex config $Path contains an unowned or user-modified managed block. The kit will not overwrite it."
        }
    }

    if (-not $PreviewOnly) {
        $pattern = "(?s)\r?\n?# BEGIN WEB_ANALYST_MCP_MANAGED.*?# END WEB_ANALYST_MCP_MANAGED\r?\n?"
        $content = ""
        if (Test-Path -LiteralPath $Path) {
            $content = [regex]::Replace((Get-Content -Raw -LiteralPath $Path), $pattern, [Environment]::NewLine)
        }
        $directory = Split-Path -Parent $Path
        if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
        $newContent = $content.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $Block + [Environment]::NewLine
        Set-Content -LiteralPath $Path -Value $newContent -Encoding UTF8
    }
    return $desiredFingerprint
}

function Assert-NoCodexServerNameCollision {
    param([string]$Path, [string[]]$ServerNames)
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $pattern = "(?s)\r?\n?# BEGIN WEB_ANALYST_MCP_MANAGED.*?# END WEB_ANALYST_MCP_MANAGED\r?\n?"
    $unmanagedContent = [regex]::Replace((Get-Content -Raw -LiteralPath $Path), $pattern, [Environment]::NewLine)
    foreach ($serverName in $ServerNames) {
        $escapedName = [regex]::Escape($serverName)
        if ($unmanagedContent -match "(?m)^\[mcp_servers\.$escapedName\]\s*$") {
            throw "Codex config already contains an unmanaged MCP server named '$serverName' at $Path. Rename it or remove it explicitly before Apply; the kit will not overwrite it."
        }
    }
}

function Set-ManagedMcpJsonFile {
    param(
        [string]$Path,
        $NewObject,
        [hashtable]$PriorFingerprints = @{},
        [switch]$PreviewOnly
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    } else {
        $existing = @{}
    }
    if (-not $existing.ContainsKey("mcpServers") -or $null -eq $existing["mcpServers"]) {
        $existing["mcpServers"] = @{}
    }

    $newNames = @($NewObject.mcpServers.Keys)
    foreach ($ownedName in @($PriorFingerprints.Keys)) {
        if ($newNames -contains $ownedName -or -not $existing["mcpServers"].ContainsKey($ownedName)) { continue }
        $currentFingerprint = Get-ObjectFingerprint -InputObject $existing["mcpServers"][$ownedName]
        if ($currentFingerprint -eq [string]$PriorFingerprints[$ownedName]) {
            $existing["mcpServers"].Remove($ownedName)
        } else {
            Write-Warning "Preserving '$ownedName' in $Path because it changed after the kit last managed it."
        }
    }

    $newFingerprints = @{}
    foreach ($name in $NewObject.mcpServers.Keys) {
        $newEntry = $NewObject.mcpServers[$name]
        $newFingerprint = Get-ObjectFingerprint -InputObject $newEntry
        if ($existing["mcpServers"].ContainsKey($name)) {
            $currentFingerprint = Get-ObjectFingerprint -InputObject $existing["mcpServers"][$name]
            $ownedAndUnchanged = $PriorFingerprints.ContainsKey($name) -and $currentFingerprint -eq [string]$PriorFingerprints[$name]
            if ($currentFingerprint -ne $newFingerprint -and -not $ownedAndUnchanged) {
                throw "MCP config $Path already contains an unowned or user-modified server named '$name'. The kit will not overwrite it."
            }
        }
        $existing["mcpServers"][$name] = $newEntry
        $newFingerprints[$name] = $newFingerprint
    }

    if (-not $PreviewOnly) {
        $directory = Split-Path -Parent $Path
        if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
        Write-JsonFile -Object $existing -Path $Path
    }
    return $newFingerprints
}

function Remove-OwnedMcpJsonEntries {
    param([string]$Path, [hashtable]$Fingerprints)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    $existing = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    if (-not $existing.ContainsKey("mcpServers") -or $null -eq $existing["mcpServers"]) { return 0 }

    $removed = 0
    foreach ($name in @($Fingerprints.Keys)) {
        if (-not $existing["mcpServers"].ContainsKey($name)) { continue }
        $currentFingerprint = Get-ObjectFingerprint -InputObject $existing["mcpServers"][$name]
        if ($currentFingerprint -ne [string]$Fingerprints[$name]) {
            Write-Warning "Preserving '$name' in $Path because it changed after the kit last managed it."
            continue
        }
        $existing["mcpServers"].Remove($name)
        $removed++
    }

    if ($removed -gt 0) {
        Write-JsonFile -Object $existing -Path $Path
    }
    return $removed
}

function Invoke-Generate {
    $servers = @(Get-EnabledMcpServers)
    $jsonObject = New-McpJsonObject -Servers $servers -ClientName "Claude"
    $codexToml = New-CodexToml -Servers $servers
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    Write-JsonFile -Object $jsonObject -Path (Join-Path $GeneratedDir "mcp.json")
    Set-Content -LiteralPath (Join-Path $GeneratedDir "codex.config-snippet.toml") -Value $codexToml -Encoding UTF8
    Write-Host "Generated MCP config for $($servers.Count) server(s)."
}

function Invoke-Apply {
    param(
        [object[]]$ServersOverride,
        [switch]$NoGeneratedFiles
    )

    $servers = if ($PSBoundParameters.ContainsKey("ServersOverride")) { @($ServersOverride) } else { @(Get-EnabledMcpServers) }
    if ($servers.Count -eq 0) { throw "No enabled MCP servers are ready to apply." }

    $codexToml = New-CodexToml -Servers $servers
    $legacyCodexToml = New-CodexToml -Servers $servers -WithoutToolIdentity
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $targetClients = @(Resolve-TargetClients -Selection $selection)
    $ownership = Read-OwnershipState -ReadOnly:$Preview
    $plans = @()

    foreach ($clientName in $targetClients) {
        $path = Get-ClientConfigTarget -ClientName $clientName -Selection $selection
        $prior = @{}
        if ($ownership["clients"].ContainsKey($clientName) -and $ownership["clients"][$clientName].ContainsKey("fingerprints")) {
            $prior = ConvertTo-Hashtable $ownership["clients"][$clientName]["fingerprints"]
        }

        if ($clientName -eq "Codex") {
            if (-not $prior.ContainsKey("managedBlock") -and $ownership["clients"].ContainsKey($clientName)) {
                $ownedClient = $ownership["clients"][$clientName]
                $currentManagedBlock = Get-CodexManagedBlock -Path $path
                if ($ownedClient.ContainsKey("format") -and [string]$ownedClient["format"] -eq "toml-managed-block" -and $null -ne $currentManagedBlock) {
                    $currentManagedBlockFingerprint = Get-ObjectFingerprint -InputObject $currentManagedBlock
                    if ($currentManagedBlockFingerprint -eq (Get-ObjectFingerprint -InputObject $legacyCodexToml)) {
                        $prior["managedBlock"] = $currentManagedBlockFingerprint
                    }
                }
            }
            Assert-NoCodexServerNameCollision -Path $path -ServerNames @($servers | ForEach-Object { $_.ServerName })
            $priorManagedBlockFingerprint = if ($prior.ContainsKey("managedBlock")) { [string]$prior["managedBlock"] } else { "" }
            Update-ManagedTextBlock -Path $path -Block $codexToml -ExpectedFingerprint $priorManagedBlockFingerprint -PreviewOnly | Out-Null
        } else {
            $clientJsonObject = New-McpJsonObject -Servers $servers -ClientName $clientName
            Set-ManagedMcpJsonFile -Path $path -NewObject $clientJsonObject -PriorFingerprints $prior -PreviewOnly | Out-Null
        }

        $plans += [PSCustomObject]@{
            Client = $clientName
            Path = $path
            Existing = if (Test-Path -LiteralPath $path) { "Yes" } else { "No" }
            Servers = (@($servers | ForEach-Object { $_.ServerName }) -join ", ")
            PriorFingerprints = $prior
        }
    }

    Write-Step "MCP configuration plan"
    Write-Host (($plans | Select-Object Client, Path, Existing, Servers | Format-Table -AutoSize | Out-String -Width 260).TrimEnd())
    if ($Preview) {
        Write-Host "Preview only. No MCP client configuration was changed."
        return
    }

    if (-not $NoGeneratedFiles) { Invoke-Generate }
    foreach ($plan in $plans) {
        $directory = Split-Path -Parent $plan.Path
        if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
        $backup = New-ConfigBackup -Path $plan.Path
        $prior = ConvertTo-Hashtable $plan.PriorFingerprints

        $fingerprints = @{}
        if ($plan.Client -eq "Codex") {
            $priorManagedBlockFingerprint = if ($prior.ContainsKey("managedBlock")) { [string]$prior["managedBlock"] } else { "" }
            $managedBlockFingerprint = Update-ManagedTextBlock -Path $plan.Path -Block $codexToml -ExpectedFingerprint $priorManagedBlockFingerprint
            $fingerprints["managedBlock"] = $managedBlockFingerprint
        } else {
            $clientJsonObject = New-McpJsonObject -Servers $servers -ClientName $plan.Client
            $fingerprints = Set-ManagedMcpJsonFile -Path $plan.Path -NewObject $clientJsonObject -PriorFingerprints $prior
        }

        $ownership["clients"][$plan.Client] = @{
            path = $plan.Path
            format = if ($plan.Client -eq "Codex") { "toml-managed-block" } else { "json-owned-entries" }
            serverNames = @($servers | ForEach-Object { $_.ServerName })
            fingerprints = $fingerprints
            lastBackup = $backup
            appliedAt = (Get-Date).ToString("o")
        }
        Write-OwnershipState -State $ownership
        Write-Host "Updated $($plan.Client) config: $($plan.Path)"
        if ($backup) { Write-Host "Backup: $backup" }
    }

    $targetLabel = @($targetClients) -join ", "
    foreach ($server in $servers) {
        $provider = [string]$selection.tools.($server.ToolName).provider
        Set-ToolEvidenceInternal -RequestedToolName $server.ToolName -Provider $provider -RequestedStage "Configured" -RequestedOutcome "Passed" -RequestedTarget $targetLabel -RequestedEvidence "MCP configuration saved with ownership protection and a recoverable backup." -PreservePassed
    }
}

function Invoke-Status {
    Ensure-LocalFiles | Out-Null
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $envMap = Import-DotEnvMap -Path $EnvPath

    Write-Step "Selected tool status"
    $statusRows = @()
    $factRows = @(Get-ToolStatusRows | Where-Object { $_.Enabled })
    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }

        $missing = @()
        foreach ($key in @($item.credentialKeys) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) {
            if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
                $missing += $key
            }
        }

        $transport = [string]$item.transport
        if (-not $transport) { $transport = "stdio" }

        $status = if ($item.kind -eq "api") { "API connector" } else { "Configured MCP" }
        if ($item.authMode -eq "none") { $status = "Ready; no auth needed" }
        if ($item.authMode -eq "user_oauth_remote") { $status = "Ready; browser OAuth from MCP client" }
        if ($item.authMode -eq "company_oauth_remote") { $status = "Ready; remote OAuth/IAM from MCP client" }
        if ($item.authMode -eq "static_oauth_client") { $status = "Needs MCP client OAuth client support" }
        if ($item.authMode -eq "company_oauth_browser") { $status = "Needs OAuth client or browser auth" }
        if ($item.authMode -eq "application_default_credentials" -or $item.authMode -eq "company_oauth_adc") { $status = "Needs Google ADC login if credentials missing" }
        if ($item.authMode -eq "api_header") { $status = "API header credentials present" }
        if ($item.authMode -eq "api_token") { $status = "API token credentials present" }
        if ($item.authMode -eq "service_account") { $status = "Needs service-account credentials authorized for the intended resource" }
        if ($missing.Count -gt 0) { $status = "Needs credentials: " + ($missing -join ", ") }

        if ($missing.Count -eq 0 -and $tool.Name -eq "googleDrive" -and $item.authMode -eq "company_oauth_browser") {
            $oauthPath = $envMap["GDRIVE_OAUTH_PATH"]
            $tokenPath = $envMap["GDRIVE_CREDENTIALS_PATH"]
            if ($oauthPath -and -not (Test-Path -LiteralPath $oauthPath)) { $status = "Needs OAuth JSON: $oauthPath" }
            elseif ($tokenPath -and -not (Test-Path -LiteralPath $tokenPath)) { $status = "Needs Drive browser auth token" }
            elseif ($tokenPath -and (Test-Path -LiteralPath $tokenPath)) {
                $status = Get-OAuthTokenStatus -TokenPath $tokenPath -RequiredScopes @($item.requiredScopes) -ProbeUri "https://www.googleapis.com/drive/v3/about?fields=user"
            }
        }

        if ($missing.Count -eq 0 -and $tool.Name -eq "gmail" -and $item.authMode -eq "company_oauth_browser") {
            $oauthPath = $envMap["GMAIL_OAUTH_PATH"]
            $tokenPath = $envMap["GMAIL_CREDENTIALS_PATH"]
            if ($oauthPath -and -not (Test-Path -LiteralPath $oauthPath)) { $status = "Needs OAuth JSON: $oauthPath" }
            elseif ($tokenPath -and -not (Test-Path -LiteralPath $tokenPath)) { $status = "Needs Gmail browser auth token" }
            elseif ($tokenPath -and (Test-Path -LiteralPath $tokenPath)) {
                $status = Get-OAuthTokenStatus -TokenPath $tokenPath -RequiredScopes @($item.requiredScopes) -ProbeUri "https://www.googleapis.com/gmail/v1/users/me/profile"
            }
        }

        if ($tool.Name -eq "googleAnalytics") {
            $adc = $envMap["GOOGLE_APPLICATION_CREDENTIALS"]
            if ($adc -and -not (Test-Path -LiteralPath $adc)) { $status = "Needs Google ADC JSON: $adc" }
        }

        if ($tool.Name -eq "bigQuery") {
            $bearerKey = [string]$item.bearerTokenEnvVar
            if ($bearerKey -and [Environment]::GetEnvironmentVariable($bearerKey, "User")) {
                $status = "Short-lived ADC bearer token configured; restart/reload client if tools still say auth required"
            } else {
                $status = "Needs BigQuery auth choice: official remote OAuth/IAM or Codex ADC bearer token"
            }
        }

        $factRow = @($factRows | Where-Object { $_.Tool -eq $tool.Name } | Select-Object -First 1)
        if ($factRow.Count -gt 0 -and [string]$factRow[0].Authenticated -like "Passed*") {
            $status = [string]$factRow[0].Authenticated
        }

        $statusRows += [PSCustomObject]@{
            Tool = [string]$item.displayName
            Configured = if ($factRow.Count -gt 0) { [string]$factRow[0].Configured } else { "Unknown" }
            Authentication = $status
            Visible = if ($factRow.Count -gt 0) { [string]$factRow[0].Visible } else { "Unknown" }
            Verified = if ($factRow.Count -gt 0) { [string]$factRow[0].Verified } else { "Unknown" }
        }
    }
    if ($statusRows.Count -gt 0) {
        Write-Host (($statusRows | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
    } else {
        Write-Host "No enabled tools."
    }

    Write-Step "AI client status"
    $targetClients = @(Resolve-TargetClients -Selection $selection -RequestedClient "Selected")
    if ($targetClients -contains "Codex") {
        if (Get-Command codex -ErrorAction SilentlyContinue) {
            codex mcp list
        } else {
            Write-Host "Codex CLI: not found on PATH"
        }
    }
    if ($targetClients -contains "Claude") {
        if (Get-Command claude -ErrorAction SilentlyContinue) {
            claude mcp list
        } else {
            Write-Host "Claude Code: not found on PATH"
        }
    }
    if ($targetClients -contains "Gemini") {
        if (Get-Command gemini -ErrorAction SilentlyContinue) {
            Write-Host "Gemini CLI: found at $((Get-Command gemini).Source)"
        } else {
            Write-Host "Gemini CLI: not found on PATH"
        }
    }
}

function Invoke-Dashboard {
    Ensure-LocalFiles | Out-Null
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $envMap = Import-DotEnvMap -Path $EnvPath
    $targetClients = @(Resolve-TargetClients -Selection $selection -RequestedClient "Selected")
    $textRows = @()
    $commandLines = @()

    foreach ($tool in $selection.tools.PSObject.Properties) {
        if (-not $tool.Value.enabled) { continue }
        $item = Resolve-CatalogItem -CatalogItem $catalog.($tool.Name) -Provider ([string]$tool.Value.provider)
        if (-not $item) { continue }

        $missing = @()
        foreach ($key in @($item.credentialKeys) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) {
            if (-not $envMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($envMap[$key])) {
                $missing += $key
            }
        }

        $transport = [string]$item.transport
        if (-not $transport) { $transport = "stdio" }

        $status = if ($item.kind -eq "api") { "API connector" } else { "Ready to configure" }
        $note = [string]$item.testPrompt
        if ($item.authMode -eq "none") {
            $status = "No auth needed"
        }
        if ($item.authMode -eq "user_oauth_remote") {
            $status = "Browser OAuth"
            $note = "Use the MCP client's OAuth/login command. Sign in with your own account."
        }
        if ($item.authMode -eq "company_oauth_remote") {
            $status = "OAuth/IAM"
            $note = "Use the MCP client's remote-login flow with access authorized for the intended Google Cloud project; confirm project, dataset, IAM roles, and applicable organizational permission first."
        }
        if ($tool.Name -eq "bigQuery") {
            $status = "BigQuery auth choice"
            $note = "Official recommendation: remote MCP with OAuth/IAM authorized for the intended Google Cloud project. Codex day-one workaround: run BigQueryAdcBearerToken to set a short-lived ADC bearer token, then restart/reload Codex and test with a dry-run read-only query."
        }
        if ($item.authMode -eq "static_oauth_client") {
            $status = "OAuth client required"
            $note = "Create an OAuth client ID/secret in Google Auth Platform and configure it in an MCP client that supports static OAuth client credentials. Codex simple login currently fails dynamic registration."
        }
        if ($item.authMode -eq "company_oauth_browser") {
            $status = "Browser OAuth"
            $note = "Provide the OAuth client ID/secret authorized for the intended account, then run GoogleOAuthFile and the browser auth command."
        }
        if ($item.authMode -eq "application_default_credentials" -or $item.authMode -eq "company_oauth_adc") {
            $status = "Google ADC"
            $note = "Prefer a Google client ID/secret authorized for the intended account; run GoogleAdcLogin to create ADC by browser login."
        }
        if ($item.authMode -eq "api_header") {
            $status = "API header"
            $note = "Uses a vendor API key header through the MCP remote adapter."
        }
        if ($item.authMode -eq "api_token") {
            $status = "API token"
            $note = "This MCP uses a token from the vendor account settings."
        }
        if ($item.authMode -eq "service_account") {
            $status = "Service account"
            $note = "Use only with the account owner's approval and, for organizational resources, organizational permission; add the service-account email to the target property with the minimum role."
        }
        if ($item.kind -eq "api") { $note = [string]$item.notes }
        if ($missing.Count -gt 0) {
            $status = "Needs credentials"
            $note = "Missing: " + ($missing -join ", ")
        }

        if ($missing.Count -eq 0 -and $tool.Name -eq "googleDrive" -and $item.authMode -eq "company_oauth_browser") {
            $oauthPath = $envMap["GDRIVE_OAUTH_PATH"]
            $tokenPath = $envMap["GDRIVE_CREDENTIALS_PATH"]
            if ($oauthPath -and -not (Test-Path -LiteralPath $oauthPath)) {
                $status = "Needs OAuth JSON"
                $note = "Run GoogleOAuthFile after saving GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET, or set GOOGLE_ADC_CLIENT_JSON to an OAuth JSON file authorized for the intended account."
            } elseif ($tokenPath -and -not (Test-Path -LiteralPath $tokenPath)) {
                $status = "Needs browser auth"
                $note = "Run the Google Drive auth command below and sign in with the intended Google account."
            } elseif ($tokenPath -and (Test-Path -LiteralPath $tokenPath)) {
                $status = "Token present"
                $note = "Run Status to check token scope/API reachability, then test Drive."
            }
        }

        if ($missing.Count -eq 0 -and $tool.Name -eq "gmail" -and $item.authMode -eq "company_oauth_browser") {
            $oauthPath = $envMap["GMAIL_OAUTH_PATH"]
            $tokenPath = $envMap["GMAIL_CREDENTIALS_PATH"]
            if ($oauthPath -and -not (Test-Path -LiteralPath $oauthPath)) {
                $status = "Needs OAuth JSON"
                $note = "Run GoogleOAuthFile after saving GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET, or set GOOGLE_ADC_CLIENT_JSON to an OAuth JSON file authorized for the intended account."
            } elseif ($tokenPath -and -not (Test-Path -LiteralPath $tokenPath)) {
                $status = "Needs browser auth"
                $note = "Run the Gmail auth command below and sign in with the intended Google account."
            } elseif ($tokenPath -and (Test-Path -LiteralPath $tokenPath)) {
                $status = "Token present"
                $note = "Run Status to check token scope/API reachability, then test Gmail."
            }
        }

        if ($tool.Name -eq "googleAnalytics") {
            $adc = $envMap["GOOGLE_APPLICATION_CREDENTIALS"]
            if ($adc -and -not (Test-Path -LiteralPath $adc)) {
                $status = "Needs ADC JSON"
                $note = "The GOOGLE_APPLICATION_CREDENTIALS path does not exist."
            }
        }

        $textRows += [PSCustomObject]@{
            Tool = [string]$item.displayName
            Type = [string]$item.kind
            Status = [string]$status
            "Next step" = [string]$note
        }

        if ($item.kind -eq "mcp") {
            $canShowAuthCommand = $true
            $lockedPackage = $null
            if ($transport -eq "http") {
                $url = [string]$item.url
                if (-not $url -and $item.urlEnvKey) {
                    $urlKey = [string]$item.urlEnvKey
                    if ($envMap.ContainsKey($urlKey)) { $url = [string]$envMap[$urlKey] }
                }
                if (-not $url) {
                    $canShowAuthCommand = $false
                }
                if ($url -and -not $item.authCommand -and $item.authMode -ne "static_oauth_client") {
                    foreach ($targetClient in $targetClients) {
                        $loginGuidance = Get-ClientMcpLoginGuidance -ClientName $targetClient -RequestedServerName ([string]$item.serverName)
                        $commandLines += "$($item.displayName) ($targetClient): $loginGuidance"
                    }
                }
            } elseif ($item.package) {
                $lockedPackage = Resolve-LockedPackageSpec -ToolName $tool.Name -Item $item -AllowUnlocked
                if (-not $lockedPackage) {
                    $canShowAuthCommand = $false
                    $status = "Needs package lock"
                    $note = "Run CheckMcpUpdates to resolve an exact package version before launch."
                    $textRows[$textRows.Count - 1].Status = $status
                    $textRows[$textRows.Count - 1]."Next step" = $note
                }
            }
            if ($transport -ne "http" -and $lockedPackage) {
                $runnerName = [string]$item.runner
                if (-not $runnerName) { $runnerName = "npx" }
                $base = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Action RunMcp -ServerName $($item.serverName) -Runner $runnerName -Package $lockedPackage"
                $startArgs = @(Get-EffectiveStartArgs -Item $item -ToolName $tool.Name)
                if ($startArgs.Count -gt 0) {
                    $encodedArgs = ConvertTo-McpArgsBase64 @($startArgs)
                    $base = $base + " -McpArgsBase64 $encodedArgs"
                }
                $commandLines += $base
            }
            if ($item.authCommand -and $canShowAuthCommand) {
                $authCommand = [string]$item.authCommand
                $authCommand = $authCommand -replace "scripts\\WebAnalystSetup\.ps1", "`"$ScriptPath`""
                if ($lockedPackage -and $item.package) {
                    $authCommand = $authCommand.Replace([string]$item.package, [string]$lockedPackage)
                }
                $commandLines += "$($item.displayName) auth: $authCommand"
            }
        }
    }

    Write-Step "MCP dashboard"
    if ($textRows.Count -gt 0) {
        Write-Host (($textRows | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
    } else {
        Write-Host "No enabled tools."
    }

    Write-Step "Reconnect and auth commands"
    if ($commandLines.Count -gt 0) {
        for ($i = 0; $i -lt $commandLines.Count; $i++) {
            Write-Host ("{0}. {1}" -f ($i + 1), $commandLines[$i])
        }
    } else {
        Write-Host "No auth commands for the enabled tools."
    }
}

function Remove-CodexManagedBlock {
    param([string]$Path, [string]$ExpectedFingerprint)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $content = Get-Content -Raw -LiteralPath $Path
    $managedPattern = "(?s)\r?\n?# BEGIN WEB_ANALYST_MCP_MANAGED.*?# END WEB_ANALYST_MCP_MANAGED\r?\n?"
    if ($content -notmatch $managedPattern) { return $false }

    $managedBlock = Get-CodexManagedBlock -Path $Path
    if ([string]::IsNullOrWhiteSpace($ExpectedFingerprint)) {
        Write-Warning "Preserving the Codex managed block in $Path because no ownership fingerprint is recorded. Re-apply an unchanged block first if you want the kit to adopt it safely."
        return $false
    }
    if ((Get-ObjectFingerprint -InputObject $managedBlock) -ne $ExpectedFingerprint) {
        Write-Warning "Preserving the Codex managed block in $Path because it changed after the kit last managed it."
        return $false
    }

    $content = [regex]::Replace($content, $managedPattern, [Environment]::NewLine).TrimEnd()
    if ($content) {
        Set-Content -LiteralPath $Path -Value ($content + [Environment]::NewLine) -Encoding UTF8
    } else {
        Set-Content -LiteralPath $Path -Value "" -Encoding UTF8
    }
    return $true
}

function Invoke-ResetMcpConfig {
    param([string[]]$TargetClients)
    if (-not $ConfirmedMcpEndpointDeletion) {
        throw "ResetMcpConfig removes kit-owned MCP configuration. Get explicit approval first, then rerun with -ConfirmedMcpEndpointDeletion."
    }

    Ensure-LocalFiles | Out-Null
    $selection = Read-JsonFile -Path $SelectionPath
    if (-not $TargetClients -or $TargetClients.Count -eq 0) {
        $TargetClients = @(Resolve-TargetClients -Selection $selection)
    }
    $ownership = Read-OwnershipState
    $ownershipPath = Get-OwnershipStatePath

    foreach ($clientName in $TargetClients) {
        $ownedClient = $null
        if ($ownership["clients"].ContainsKey($clientName)) {
            $ownedClient = $ownership["clients"][$clientName]
        }
        $path = if ($ownedClient -and $ownedClient.ContainsKey("path")) { [string]$ownedClient["path"] } else { Get-ClientConfigTarget -ClientName $clientName -Selection $selection }

        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host "No $clientName config found at $path"
            if ($ownedClient) { $ownership["clients"].Remove($clientName) }
            continue
        }

        if ($clientName -eq "Codex") {
            $content = Get-Content -Raw -LiteralPath $path
            if ($content -match "# BEGIN WEB_ANALYST_MCP_MANAGED") {
                $managedBlockFingerprint = ""
                if ($ownedClient -and $ownedClient.ContainsKey("fingerprints")) {
                    $codexFingerprints = ConvertTo-Hashtable $ownedClient["fingerprints"]
                    if ($codexFingerprints.ContainsKey("managedBlock")) {
                        $managedBlockFingerprint = [string]$codexFingerprints["managedBlock"]
                    }
                }
                $currentManagedBlock = Get-CodexManagedBlock -Path $path
                $canRemove = -not [string]::IsNullOrWhiteSpace($managedBlockFingerprint) -and (Get-ObjectFingerprint -InputObject $currentManagedBlock) -eq $managedBlockFingerprint
                $backup = if ($canRemove) { New-ConfigBackup -Path $path } else { $null }
                if (Remove-CodexManagedBlock -Path $path -ExpectedFingerprint $managedBlockFingerprint) {
                    Write-Host "Removed the kit-owned Codex MCP block from: $path"
                    Write-Host "Backup: $backup"
                }
            } else {
                Write-Host "No kit-owned Codex MCP block found at $path. Nothing was removed."
            }
        } elseif ($ownedClient -and $ownedClient.ContainsKey("fingerprints")) {
            $fingerprints = ConvertTo-Hashtable $ownedClient["fingerprints"]
            if ($fingerprints.Count -gt 0) {
                $backup = New-ConfigBackup -Path $path
                $removed = Remove-OwnedMcpJsonEntries -Path $path -Fingerprints $fingerprints
                Write-Host "Removed $removed kit-owned MCP entr$(if ($removed -eq 1) { 'y' } else { 'ies' }) from $clientName config: $path"
                if ($backup) { Write-Host "Backup: $backup" }
            }
        } else {
            Write-Warning "No ownership record exists for $clientName JSON config at $path. Nothing was removed."
        }

        if ($ownedClient) { $ownership["clients"].Remove($clientName) }
    }

    if ($ownership["clients"].Count -gt 0) {
        Write-OwnershipState -State $ownership
    } elseif (Test-Path -LiteralPath $ownershipPath) {
        Remove-Item -LiteralPath $ownershipPath -Force
    }
}

function Invoke-ResetCodexMcp {
    Invoke-ResetMcpConfig -TargetClients @("Codex")
}

function Invoke-ResetKit {
    Write-Step "Resetting local kit state"
    $ownershipStatePath = Get-OwnershipStatePath
    $envMap = @{}
    if (Test-Path -LiteralPath $EnvPath) {
        $envMap = Import-DotEnvMap -Path $EnvPath
    }

    foreach ($target in @($SelectionPath, $EnvPath)) {
        Assert-PathInsideRoot -Path $target
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
            Write-Host "Removed $target"
        }
    }

    $secretsDir = Join-Path $Root "secrets"
    if (Test-Path -LiteralPath $secretsDir) {
        foreach ($filter in @("*.json", "*.token")) {
            Get-ChildItem -LiteralPath $secretsDir -Filter $filter -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Assert-PathInsideRoot -Path $_.FullName
                Remove-Item -LiteralPath $_.FullName -Force
                Write-Host "Removed $($_.FullName)"
            }
        }
    }

    Write-Step "Resetting external kit-owned tokens"
    $externalPaths = @(
        (Join-Path $env:USERPROFILE ".web-analyst-agent\google-oauth-client.json"),
        (Join-Path $env:USERPROFILE ".web-analyst-agent\gdrive-credentials.json"),
        (Join-Path $env:USERPROFILE ".web-analyst-agent\gmail-credentials.json")
    )
    foreach ($key in @("GOOGLE_OAUTH_CLIENT_JSON", "GDRIVE_OAUTH_PATH", "GDRIVE_CREDENTIALS_PATH", "GMAIL_OAUTH_PATH", "GMAIL_CREDENTIALS_PATH")) {
        if ($envMap.ContainsKey($key)) { $externalPaths += $envMap[$key] }
    }
    foreach ($externalPath in ($externalPaths | Where-Object { $_ } | Select-Object -Unique)) {
        Remove-ExternalKitToken -Path $externalPath
    }
    Write-Host "External cleanup is limited to known files under %USERPROFILE%\.web-analyst-agent."
    if (Test-Path -LiteralPath $ownershipStatePath) {
        Write-Warning "MCP client configuration ownership is still recorded. Run ResetMcpConfig with explicit approval before ResetKit when you also want to disconnect the configured clients."
    }

    [Environment]::SetEnvironmentVariable("BIGQUERY_MCP_ACCESS_TOKEN", $null, "User")
    [Environment]::SetEnvironmentVariable("BIGQUERY_MCP_ACCESS_TOKEN", $null, "Process")
    Write-Host "Removed BIGQUERY_MCP_ACCESS_TOKEN from the process/user environment if it existed."

    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    Assert-PathInsideRoot -Path $GeneratedDir
    Get-ChildItem -LiteralPath $GeneratedDir -Force | Where-Object { $_.Name -ne ".gitkeep" } | ForEach-Object {
        Assert-PathInsideRoot -Path $_.FullName
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
        Write-Host "Removed $($_.FullName)"
    }

    $gitkeep = Join-Path $GeneratedDir ".gitkeep"
    if (-not (Test-Path -LiteralPath $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $ownershipStatePath) -and (Test-Path -LiteralPath $InstallationIdPath)) {
        Remove-Item -LiteralPath $InstallationIdPath -Force
        Write-Host "Removed local installation identifier."
    }

    Write-Host "Kit reset complete. Templates, catalog, script, and docs were kept."
}

function Protect-LocalGoogleOAuthMcpEnvironment {
    if ($ServerName -in @("google-drive", "gmail")) {
        # Some Google MCP packages prefer GOOGLE_APPLICATION_CREDENTIALS over their
        # local browser-OAuth token. Keep GA4 ADC from leaking into Drive/Gmail.
        [Environment]::SetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", $null, "Process")
    }
}

function Get-CatalogEnvironmentKeys {
    param($Item)
    $keys = @()
    foreach ($field in @("credentialKeys", "optionalCredentialKeys", "urlEnvKey", "bearerTokenEnvVar")) {
        if ($null -eq $Item.$field) { continue }
        foreach ($key in @($Item.$field)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $keys += [string]$key }
        }
    }
    foreach ($fileKey in @($keys | Where-Object { $_ -like "*_FILE" })) {
        $keys += $fileKey.Substring(0, $fileKey.Length - 5)
    }
    return @($keys | Select-Object -Unique)
}

function Resolve-RunMcpCatalogContext {
    param(
        [string]$RequestedToolName,
        [string]$RequestedServerName,
        [string]$RequestedRunner,
        [string]$RequestedPackage
    )

    $requestedPackageName = if ($RequestedRunner -eq "npx") {
        Get-NpmLookupName -PackageName $RequestedPackage
    } else {
        $RequestedPackage -replace "==.*$", ""
    }
    $candidates = @(Get-AllCatalogMcpItems | Where-Object {
        $candidatePackageName = if ([string]$_.Item.runner -eq "npx") {
            Get-NpmLookupName -PackageName ([string]$_.Item.package)
        } else {
            [string]$_.Item.package -replace "==.*$", ""
        }
        ([string]::IsNullOrWhiteSpace($RequestedToolName) -or $_.ToolName -eq $RequestedToolName) -and
        [string]$_.Item.serverName -eq $RequestedServerName -and
        [string]$_.Item.runner -eq $RequestedRunner -and
        $candidatePackageName -eq $requestedPackageName
    })

    if ($candidates.Count -ne 1) {
        $toolDescription = if ([string]::IsNullOrWhiteSpace($RequestedToolName)) { "server '$RequestedServerName'" } else { "tool '$RequestedToolName'" }
        throw "RunMcp could not resolve $toolDescription to exactly one cataloged provider for the requested runner and package. Re-run Apply to refresh the managed client configuration."
    }
    return $candidates[0]
}

function Set-RunMcpEnvironment {
    param(
        [string]$RequestedToolName,
        [string]$RequestedServerName,
        [string]$RequestedRunner,
        [string]$RequestedPackage,
        [string]$DotEnvPath = $EnvPath
    )

    $context = Resolve-RunMcpCatalogContext -RequestedToolName $RequestedToolName -RequestedServerName $RequestedServerName -RequestedRunner $RequestedRunner -RequestedPackage $RequestedPackage
    $envMap = Import-DotEnvMap -Path $DotEnvPath
    $allowedKeys = @(Get-CatalogEnvironmentKeys -Item $context.Item)

    if ($context.ToolName -eq "googleDrive") {
        $allowedKeys += @("GDRIVE_OAUTH_PATH", "GOOGLE_REFRESH_TOKEN")
    } elseif ($context.ToolName -eq "gmail") {
        $allowedKeys += @("GMAIL_OAUTH_PATH", "GOOGLE_REFRESH_TOKEN")
    }
    $allowedKeys = @($allowedKeys | Select-Object -Unique)

    $managedKeys = @($envMap.Keys)
    foreach ($catalogItem in @(Get-AllCatalogMcpItems)) {
        $managedKeys += @(Get-CatalogEnvironmentKeys -Item $catalogItem.Item)
    }
    $managedKeys += @(
        "CLIENT_ID",
        "CLIENT_SECRET",
        "REFRESH_TOKEN",
        "GOOGLE_REFRESH_TOKEN",
        "GOOGLE_DRIVE_OAUTH_CREDENTIALS",
        "GOOGLE_DRIVE_MCP_TOKEN_PATH",
        "GDRIVE_OAUTH_PATH",
        "GMAIL_OAUTH_PATH"
    )
    $managedKeys = @($managedKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    $selectedValues = @{}
    foreach ($key in $allowedKeys) {
        $selectedValues[$key] = Get-EffectiveCredentialValue -EnvMap $envMap -Key ([string]$key)
    }

    foreach ($key in $managedKeys) {
        [Environment]::SetEnvironmentVariable([string]$key, $null, "Process")
    }
    foreach ($key in $selectedValues.Keys) {
        $value = [string]$selectedValues[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [Environment]::SetEnvironmentVariable([string]$key, $value, "Process")
        }
    }

    if ($context.ToolName -in @("googleDrive", "gmail")) {
        $googleClientId = [Environment]::GetEnvironmentVariable("GOOGLE_CLIENT_ID", "Process")
        $googleClientSecret = [Environment]::GetEnvironmentVariable("GOOGLE_CLIENT_SECRET", "Process")
        $googleRefreshToken = [Environment]::GetEnvironmentVariable("GOOGLE_REFRESH_TOKEN", "Process")
        if ($googleClientId) { [Environment]::SetEnvironmentVariable("CLIENT_ID", $googleClientId, "Process") }
        if ($googleClientSecret) { [Environment]::SetEnvironmentVariable("CLIENT_SECRET", $googleClientSecret, "Process") }
        if ($googleRefreshToken) { [Environment]::SetEnvironmentVariable("REFRESH_TOKEN", $googleRefreshToken, "Process") }
    }

    if ($context.ToolName -eq "googleDrive") {
        $driveOAuthPath = [Environment]::GetEnvironmentVariable("GDRIVE_OAUTH_PATH", "Process")
        if (-not $driveOAuthPath) {
            $driveOAuthPath = [Environment]::GetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_JSON", "Process")
            if ($driveOAuthPath) { [Environment]::SetEnvironmentVariable("GDRIVE_OAUTH_PATH", $driveOAuthPath, "Process") }
        }
        if ($driveOAuthPath) { [Environment]::SetEnvironmentVariable("GOOGLE_DRIVE_OAUTH_CREDENTIALS", $driveOAuthPath, "Process") }

        $driveTokenPath = [Environment]::GetEnvironmentVariable("GDRIVE_CREDENTIALS_PATH", "Process")
        if ($driveTokenPath) { [Environment]::SetEnvironmentVariable("GOOGLE_DRIVE_MCP_TOKEN_PATH", $driveTokenPath, "Process") }
    } elseif ($context.ToolName -eq "gmail") {
        $gmailOAuthPath = [Environment]::GetEnvironmentVariable("GMAIL_OAUTH_PATH", "Process")
        if (-not $gmailOAuthPath) {
            $gmailOAuthPath = [Environment]::GetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_JSON", "Process")
            if ($gmailOAuthPath) { [Environment]::SetEnvironmentVariable("GMAIL_OAUTH_PATH", $gmailOAuthPath, "Process") }
        }
    }

    foreach ($pathKey in @("GDRIVE_OAUTH_PATH", "GDRIVE_CREDENTIALS_PATH", "GMAIL_OAUTH_PATH", "GMAIL_CREDENTIALS_PATH", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_DRIVE_OAUTH_CREDENTIALS", "GOOGLE_DRIVE_MCP_TOKEN_PATH")) {
        $pathValue = [Environment]::GetEnvironmentVariable($pathKey, "Process")
        if (-not $pathValue) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($pathValue)
        [Environment]::SetEnvironmentVariable($pathKey, $expanded, "Process")
        $parent = Split-Path -Parent $expanded
        if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
    }
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Invoke-RefreshGoogleDriveToken {
    Import-DotEnvMap -Path $EnvPath -IntoProcess | Out-Null

    $tokenPath = [Environment]::GetEnvironmentVariable("GDRIVE_CREDENTIALS_PATH", "Process")
    if (-not $tokenPath) {
        $tokenPath = Join-Path $env:USERPROFILE ".web-analyst-agent\gdrive-credentials.json"
    }
    $tokenPath = [Environment]::ExpandEnvironmentVariables($tokenPath)

    $oauthPath = [Environment]::GetEnvironmentVariable("GDRIVE_OAUTH_PATH", "Process")
    if (-not $oauthPath) {
        $oauthPath = [Environment]::GetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_JSON", "Process")
    }
    if (-not $oauthPath) {
        $oauthPath = Join-Path $env:USERPROFILE ".web-analyst-agent\google-oauth-client.json"
    }
    $oauthPath = [Environment]::ExpandEnvironmentVariables($oauthPath)

    if (-not (Test-Path -LiteralPath $tokenPath)) {
        throw "Drive token file not found: $tokenPath"
    }
    if (-not (Test-Path -LiteralPath $oauthPath)) {
        throw "Google OAuth client file not found: $oauthPath"
    }

    $token = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($token.refresh_token)) {
        throw "Drive refresh token missing. Re-run the Drive browser auth command."
    }

    $oauth = Get-Content -LiteralPath $oauthPath -Raw | ConvertFrom-Json
    if ($oauth.installed) {
        $client = $oauth.installed
    } elseif ($oauth.web) {
        $client = $oauth.web
    } else {
        throw "OAuth client file must contain an installed or web section."
    }

    if ([string]::IsNullOrWhiteSpace($client.client_id)) {
        throw "OAuth client ID missing in $oauthPath"
    }

    $body = @{
        client_id     = $client.client_id
        refresh_token = $token.refresh_token
        grant_type    = "refresh_token"
    }
    if (-not [string]::IsNullOrWhiteSpace($client.client_secret)) {
        $body.client_secret = $client.client_secret
    }

    $response = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -Body $body -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Google did not return an access token for Drive."
    }

    Set-JsonProperty -Object $token -Name "access_token" -Value $response.access_token
    Set-JsonProperty -Object $token -Name "token_type" -Value $response.token_type
    if ($response.expires_in) {
        Set-JsonProperty -Object $token -Name "expiry_date" -Value ([DateTimeOffset]::UtcNow.AddSeconds([int]$response.expires_in).ToUnixTimeMilliseconds())
    }
    if ($response.scope) {
        Set-JsonProperty -Object $token -Name "scope" -Value $response.scope
    }

    $parent = Split-Path -Parent $tokenPath
    if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
    $token | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tokenPath -Encoding UTF8
    Write-Host "Drive access token refreshed without printing token values."
}

function Invoke-BigQueryAdcBearerToken {
    $gcloud = Get-Command "gcloud.cmd" -ErrorAction SilentlyContinue
    if (-not $gcloud) {
        $gcloud = Get-Command "gcloud" -ErrorAction SilentlyContinue
    }
    if (-not $gcloud) {
        throw "gcloud was not found on PATH. Install Google Cloud CLI or use another BigQuery auth option."
    }

    $token = & $gcloud.Source auth application-default print-access-token 2>$null
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "No ADC access token returned. Run GoogleAdcLogin first, then retry."
    }

    [Environment]::SetEnvironmentVariable("BIGQUERY_MCP_ACCESS_TOKEN", $token.Trim(), "User")
    [Environment]::SetEnvironmentVariable("BIGQUERY_MCP_ACCESS_TOKEN", $token.Trim(), "Process")
    Write-Host "Saved short-lived BIGQUERY_MCP_ACCESS_TOKEN in the user environment without printing it."
    Write-Host "This token usually expires in about one hour. Re-run this action and restart/reload the MCP client when it expires."
}

function Invoke-RunMcp {
    if (-not $ServerName -or -not $Package) {
        throw "RunMcp requires -ServerName and -Package."
    }

    Set-RunMcpEnvironment -RequestedToolName $ToolName -RequestedServerName $ServerName -RequestedRunner $Runner -RequestedPackage $Package

    Protect-LocalGoogleOAuthMcpEnvironment

    $effectiveMcpArgs = @(Get-EffectiveMcpArgsForRun)

    if ($Runner -eq "pipx") {
        Invoke-PipxRun -PackageName $Package -Args $effectiveMcpArgs
    } else {
        $npx = Resolve-Npx
        & $npx -y $Package @effectiveMcpArgs
    }
    exit $LASTEXITCODE
}

function Invoke-WebAnalystSetupMain {
switch ($Action) {
    "Connect" {
        Invoke-Connect
    }
    "Prepare" {
        Ensure-LocalFiles
        Write-Host "Prepared local config files:"
        Write-Host "  $SelectionPath"
        if (Test-Path -LiteralPath $EnvPath) { Write-Host "  $EnvPath" }
        Write-Host "Use -Action Connect to preview and continue setup."
    }
    "Validate" {
        Invoke-ValidateKit
    }
    "Doctor" {
        Invoke-Doctor
    }
    "CredentialGuide" {
        Invoke-CredentialGuide
    }
    "BigQuerySafetyPlan" {
        Invoke-BigQuerySafetyPlan
    }
    "OnboardingReport" {
        Invoke-OnboardingReport
    }
    "RecordEvidence" {
        Invoke-RecordEvidence
    }
    "ReleaseAudit" {
        Invoke-ReleaseAudit
    }
    "CatalogReview" {
        Invoke-CatalogReview
    }
    "PesterTests" {
        Invoke-PesterTests
    }
    "Prereqs" {
        Ensure-LocalFiles
        Invoke-Prereqs
    }
    "CheckMcpUpdates" {
        Ensure-LocalFiles
        Invoke-CheckMcpUpdates
    }
    "Generate" {
        Ensure-LocalFiles
        Invoke-Generate
    }
    "Apply" {
        Ensure-LocalFiles
        Invoke-Apply
    }
    "Status" {
        Ensure-LocalFiles
        Invoke-Status
    }
    "Dashboard" {
        Ensure-LocalFiles
        Invoke-Dashboard
    }
    "GoogleOAuthFile" {
        Invoke-GoogleOAuthFile
    }
    "GoogleAdcLogin" {
        Invoke-GoogleAdcLogin
    }
    "RefreshGoogleDriveToken" {
        Invoke-RefreshGoogleDriveToken
    }
    "BigQueryAdcBearerToken" {
        Invoke-BigQueryAdcBearerToken
    }
    "ResetKit" {
        Invoke-ResetKit
    }
    "ResetMcpConfig" {
        Invoke-ResetMcpConfig
    }
    "ResetCodexMcp" {
        Invoke-ResetCodexMcp
    }
    "RunMcp" {
        Invoke-RunMcp
    }
    "All" {
        Write-Warning "All is deprecated. It now uses the safe, resumable Connect flow."
        Invoke-Connect
    }
}
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-WebAnalystSetupMain
}
