BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $CatalogPathForTest = Join-Path $RepoRoot "config\mcp-catalog.json"
    $SelectionExamplePathForTest = Join-Path $RepoRoot "config\tool-selection.example.json"
    $ScriptPathForTest = Join-Path $RepoRoot "scripts\WebAnalystSetup.ps1"
    $Catalog = Get-Content -Raw -LiteralPath $CatalogPathForTest | ConvertFrom-Json
    $SelectionExample = Get-Content -Raw -LiteralPath $SelectionExamplePathForTest | ConvertFrom-Json
    $ScriptText = Get-Content -Raw -LiteralPath $ScriptPathForTest

    . $ScriptPathForTest -Action Status
}

Describe "Reusable kit hygiene" {
    It "does not track local runtime files" {
        $tracked = git -C $RepoRoot ls-files
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed with exit code $LASTEXITCODE" }
        foreach ($path in @(
            "secrets/.env.local",
            "config/tool-selection.json",
            "generated/onboarding-report.md",
            "generated/onboarding-state.json",
            "generated/mcp-version-lock.json",
            "generated/managed-config-state.json",
            "generated/first-day-checklist.md",
            "generated/credential-guide.md",
            "generated/bigquery-safety-plan.md",
            "generated/mcp-update-check.md",
            ".mcp.json",
            ".codex/config.toml",
            ".gemini/settings.json",
            ".web-analyst-installation-id"
        )) {
            ($tracked -contains $path) | Should -BeFalse
        }
    }

    It "keeps reusable selection profile-free by default" {
        $SelectionExample.PSObject.Properties.Name -contains "profile" | Should -BeFalse
    }

    It "provides a valid skill adapter and UI metadata" {
        Test-Path (Join-Path $RepoRoot "SKILL.md") | Should -BeTrue
        Test-Path (Join-Path $RepoRoot "agents\openai.yaml") | Should -BeTrue
        (Get-Content -Raw (Join-Path $RepoRoot "SKILL.md")) | Should -Match "(?s)^---\s+name: web-analyst-mcp-setup\s+description:"
        (Get-Content -Raw (Join-Path $RepoRoot "agents\openai.yaml")) | Should -Match '\$web-analyst-mcp-setup'
    }
}

Describe "Catalog provider metadata" {
    It "declares lifecycle metadata for every catalog path" {
        foreach ($tool in $Catalog.PSObject.Properties) {
            foreach ($field in @("lifecycleStatus", "recommendedUse", "fallbackWhen", "knownLimitations")) {
                $tool.Value.PSObject.Properties.Name -contains $field | Should -BeTrue
            }
            if ($tool.Value.providers) {
                foreach ($provider in $tool.Value.providers.PSObject.Properties) {
                    foreach ($field in @("lifecycleStatus", "recommendedUse", "fallbackWhen", "knownLimitations")) {
                        $provider.Value.PSObject.Properties.Name -contains $field | Should -BeTrue
                    }
                }
            }
        }
    }

    It "uses update-aware npm package specs in the catalog" {
        foreach ($tool in $Catalog.PSObject.Properties) {
            if ($tool.Value.runner -eq "npx" -and $tool.Value.package) {
                [string]$tool.Value.package | Should -Match "@latest$"
            }
        }
    }

    It "declares the selection provider as each tool's default" {
        foreach ($tool in $SelectionExample.tools.PSObject.Properties) {
            [string]$Catalog.($tool.Name).defaultProvider | Should -Be ([string]$tool.Value.provider)
        }
    }

    It "resolves default and fallback providers predictably" {
        $default = Resolve-CatalogItem -CatalogItem $Catalog.googleDrive -Provider "google-drive-local-node-fallback"
        $fallback = Resolve-CatalogItem -CatalogItem $Catalog.googleDrive -Provider "google-drive-official-remote"

        $default.runtime | Should -Be "node"
        $default.selectedProvider | Should -Be "google-drive-local-node-fallback"
        $fallback.runtime | Should -Be "remote"
        $fallback.selectedProvider | Should -Be "google-drive-official-remote"
    }

    It "keeps broad analytics inventories out of smoke tests" {
        [string]$Catalog.googleTagManager.testPrompt | Should -Match "intended GTM account or container"
        [string]$Catalog.googleTagManager.testPrompt | Should -Match "Do not enumerate"
        [string]$Catalog.bigQuery.testPrompt | Should -Match "confirmed project and dataset"
        [string]$Catalog.bigQuery.testPrompt | Should -Match "Do not enumerate"
    }
}

Describe "Deterministic configuration generation" {
    BeforeEach {
        $script:SampleServers = @(
            [PSCustomObject]@{
                ToolName = "browserQa"
                ServerName = "browser-qa"
                Transport = "stdio"
                Runner = "npx"
                Package = "@playwright/mcp@1.2.3"
                Url = ""
                StartArgs = @("--browser", "msedge")
                RequiredScopes = @()
                BearerTokenEnvVar = ""
            },
            [PSCustomObject]@{
                ToolName = "bigQuery"
                ServerName = "bigquery"
                Transport = "http"
                Runner = ""
                Package = ""
                Url = "https://example.invalid/mcp"
                StartArgs = @()
                RequiredScopes = @("scope.read")
                BearerTokenEnvVar = "BIGQUERY_TOKEN"
            }
        )
    }

    It "generates Codex TOML with exact packages and remote auth metadata" {
        $toml = New-CodexToml -Servers $SampleServers
        $legacyToml = New-CodexToml -Servers $SampleServers -WithoutToolIdentity
        $toml | Should -Match '\[mcp_servers\.browser-qa\]'
        $toml | Should -Match '@playwright/mcp@1\.2\.3'
        $toml | Should -Match '"-ToolName", "browserQa"'
        $legacyToml | Should -Match '@playwright/mcp@1\.2\.3'
        $legacyToml | Should -Not -Match '"-ToolName", "browserQa"'
        $toml | Should -Match '\[mcp_servers\.bigquery\]'
        $toml | Should -Match 'bearer_token_env_var = "BIGQUERY_TOKEN"'
        $toml | Should -Match 'scopes = \["scope\.read"\]'
    }

    It "generates client-specific JSON configuration for Claude and Gemini" {
        $claudeJson = New-McpJsonObject -Servers $SampleServers -ClientName "Claude"
        $geminiJson = New-McpJsonObject -Servers $SampleServers -ClientName "Gemini"

        $claudeJson.mcpServers.Keys | Should -Contain "browser-qa"
        $claudeJson.mcpServers["browser-qa"].command | Should -Be "powershell.exe"
        $claudeJson.mcpServers["bigquery"].type | Should -Be "http"
        $claudeJson.mcpServers["bigquery"].url | Should -Be "https://example.invalid/mcp"
        $claudeJson.mcpServers["bigquery"].headers.Authorization | Should -Be 'Bearer ${BIGQUERY_TOKEN}'

        $geminiJson.mcpServers["browser-qa"].command | Should -Be "powershell.exe"
        $geminiJson.mcpServers["bigquery"].httpUrl | Should -Be "https://example.invalid/mcp"
        $geminiJson.mcpServers["bigquery"].ContainsKey("url") | Should -BeFalse
        $geminiJson.mcpServers["bigquery"].headers.Authorization | Should -Be 'Bearer ${BIGQUERY_TOKEN}'
    }

    It "creates stable fingerprints regardless of JSON property order" {
        $first = [ordered]@{ command = "node"; args = @("a", "b") }
        $second = [ordered]@{ args = @("a", "b"); command = "node" }
        (Get-ObjectFingerprint $first) | Should -Be (Get-ObjectFingerprint $second)
    }
}

Describe "Selected-provider prerequisites" {
    It "requires only runtimes used by the selected providers" {
        $remoteOnly = @([PSCustomObject]@{ Item = [PSCustomObject]@{ runner = $null; authMode = "company_oauth_remote" } })
        $nodeOnly = @([PSCustomObject]@{ Item = [PSCustomObject]@{ runner = "npx"; authMode = "company_oauth_browser" } })
        $adcOnly = @([PSCustomObject]@{ Item = [PSCustomObject]@{ runner = "pipx"; authMode = "company_oauth_adc" } })

        $remoteNeeds = Get-PrerequisiteNeeds -SelectedItems $remoteOnly -IncludePython $false
        $remoteNeeds.NeedsNode | Should -BeFalse
        $remoteNeeds.NeedsPython | Should -BeFalse
        $remoteNeeds.NeedsGcloud | Should -BeFalse

        $nodeNeeds = Get-PrerequisiteNeeds -SelectedItems $nodeOnly -IncludePython $false
        $nodeNeeds.NeedsNode | Should -BeTrue
        $nodeNeeds.NeedsPython | Should -BeFalse
        $nodeNeeds.NeedsGcloud | Should -BeFalse

        $adcNeeds = Get-PrerequisiteNeeds -SelectedItems $adcOnly -IncludePython $false
        $adcNeeds.NeedsNode | Should -BeFalse
        $adcNeeds.NeedsPython | Should -BeTrue
        $adcNeeds.NeedsGcloud | Should -BeTrue
    }

    It "does not upgrade a healthy Node.js runtime during Prereqs" {
        $prereqText = [regex]::Match($ScriptText, '(?s)function Invoke-Prereqs \{(.*?)function New-McpUpdateResult').Groups[1].Value
        $prereqText | Should -Match '(?s)elseif \(\$nodeMajor -lt 22\).*?winget upgrade'
        $prereqText | Should -Match 'else \{\s+Write-Host "node: \$raw"\s+\}'
        $prereqText | Should -Not -Match 'Checking Git'
    }
}

Describe "Ownership-safe configuration changes" {
    It "uses a persistent installation identifier that can move with the folder" {
            $installationIdPath = Join-Path $TestDrive ".web-analyst-installation-id"
            $first = Get-InstallationId -Path $installationIdPath
            $second = Get-InstallationId -Path $installationIdPath
            $first | Should -Be $second
            { [Guid]::Parse($first) } | Should -Not -Throw
    }

    It "does not create an installation identifier during a read-only lookup" {
            $installationIdPath = Join-Path $TestDrive "read-only-installation-id"
            (Get-InstallationId -Path $installationIdPath -ReadOnly) | Should -BeNullOrEmpty
            Test-Path -LiteralPath $installationIdPath | Should -BeFalse
    }

    It "creates a recovery backup before a config rewrite" {
        $path = Join-Path $TestDrive "config.toml"
        Set-Content -LiteralPath $path -Value 'model = "before"'
        $backup = New-ConfigBackup -Path $path
        Test-Path -LiteralPath $backup | Should -BeTrue
        (Get-Content -Raw -LiteralPath $backup).Trim() | Should -Be 'model = "before"'
    }

    It "replaces only the managed Codex block and preserves unrelated settings" {
        $path = Join-Path $TestDrive "config.toml"
        Set-Content -LiteralPath $path -Value @(
            'model = "example"',
            '[mcp_servers.unrelated]',
            'url = "https://unrelated.invalid/mcp"',
            '# BEGIN WEB_ANALYST_MCP_MANAGED',
            '[mcp_servers.old-kit-entry]',
            'url = "https://old.invalid/mcp"',
            '# END WEB_ANALYST_MCP_MANAGED'
        )

        $oldFingerprint = Get-ObjectFingerprint -InputObject (Get-CodexManagedBlock -Path $path)
        $newBlock = "# BEGIN WEB_ANALYST_MCP_MANAGED`n[mcp_servers.new-kit-entry]`nurl = `"https://new.invalid/mcp`"`n# END WEB_ANALYST_MCP_MANAGED"
        $newFingerprint = Update-ManagedTextBlock -Path $path -Block $newBlock -ExpectedFingerprint $oldFingerprint
        $content = Get-Content -Raw $path

        $newFingerprint | Should -Be (Get-ObjectFingerprint -InputObject $newBlock)
        $content | Should -Match 'model = "example"'
        $content | Should -Match '\[mcp_servers\.unrelated\]'
        $content | Should -Match '\[mcp_servers\.new-kit-entry\]'
        $content | Should -Not -Match 'old-kit-entry'
    }

    It "validates a Codex managed-block update without writing in preview" {
        $path = Join-Path $TestDrive "preview-config.toml"
        $block = "# BEGIN WEB_ANALYST_MCP_MANAGED`n[mcp_servers.preview]`nurl = `"https://preview.invalid/mcp`"`n# END WEB_ANALYST_MCP_MANAGED"

        Update-ManagedTextBlock -Path $path -Block $block -PreviewOnly | Out-Null

        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It "refuses to overwrite or remove a user-modified Codex managed block" {
        $path = Join-Path $TestDrive "modified-config.toml"
        $originalBlock = "# BEGIN WEB_ANALYST_MCP_MANAGED`n[mcp_servers.owned]`nurl = `"https://owned.invalid/mcp`"`n# END WEB_ANALYST_MCP_MANAGED"
        Set-Content -LiteralPath $path -Value $originalBlock
        $fingerprint = Get-ObjectFingerprint -InputObject (Get-CodexManagedBlock -Path $path)
        Set-Content -LiteralPath $path -Value ($originalBlock -replace "owned.invalid", "user-change.invalid")

        { Update-ManagedTextBlock -Path $path -Block $originalBlock -ExpectedFingerprint $fingerprint } | Should -Throw "*user-modified managed block*"
        (Remove-CodexManagedBlock -Path $path -ExpectedFingerprint $fingerprint) | Should -BeFalse
        (Get-Content -Raw -LiteralPath $path) | Should -Match "user-change.invalid"
    }

    It "refuses an unmanaged Codex server-name collision" {
        $path = Join-Path $TestDrive "config.toml"
        Set-Content -LiteralPath $path -Value "[mcp_servers.browser-qa]`nurl = `"https://user.invalid/mcp`""
        { Assert-NoCodexServerNameCollision -Path $path -ServerNames @("browser-qa") } | Should -Throw "*unmanaged MCP server*"
    }

    It "preserves unrelated JSON entries and refuses an unowned collision" {
        $path = Join-Path $TestDrive "mcp.json"
        $existing = @{ mcpServers = @{ unrelated = @{ url = "https://unrelated.invalid/mcp" }; shared = @{ url = "https://user.invalid/mcp" } }; setting = "keep" }
        Write-JsonFile -Object $existing -Path $path
        $newObject = @{ mcpServers = @{ browser = @{ command = "node"; args = @("server.js") } } }

        $fingerprints = Set-ManagedMcpJsonFile -Path $path -NewObject $newObject
        $written = ConvertTo-Hashtable (Read-JsonFile -Path $path)
        $written["setting"] | Should -Be "keep"
        $written["mcpServers"].ContainsKey("unrelated") | Should -BeTrue
        $fingerprints.ContainsKey("browser") | Should -BeTrue

        $collision = @{ mcpServers = @{ shared = @{ url = "https://kit.invalid/mcp" } } }
        { Set-ManagedMcpJsonFile -Path $path -NewObject $collision } | Should -Throw "*unowned or user-modified*"
    }

    It "removes only unchanged owned JSON entries" {
        $path = Join-Path $TestDrive "mcp.json"
        $ownedEntry = @{ command = "node"; args = @("server.js") }
        $existing = @{ mcpServers = @{ owned = $ownedEntry; unrelated = @{ url = "https://unrelated.invalid/mcp" } } }
        Write-JsonFile -Object $existing -Path $path
        $fingerprints = @{ owned = Get-ObjectFingerprint $ownedEntry }

        (Remove-OwnedMcpJsonEntries -Path $path -Fingerprints $fingerprints) | Should -Be 1
        $written = ConvertTo-Hashtable (Read-JsonFile -Path $path)
        $written["mcpServers"].ContainsKey("owned") | Should -BeFalse
        $written["mcpServers"].ContainsKey("unrelated") | Should -BeTrue
    }

    It "preserves an owned entry after the user modifies it" {
        $path = Join-Path $TestDrive "mcp.json"
        $original = @{ command = "node"; args = @("old.js") }
        $changed = @{ command = "node"; args = @("user-change.js") }
        Write-JsonFile -Object @{ mcpServers = @{ owned = $changed } } -Path $path
        $fingerprints = @{ owned = Get-ObjectFingerprint $original }

        (Remove-OwnedMcpJsonEntries -Path $path -Fingerprints $fingerprints) | Should -Be 0
        (ConvertTo-Hashtable (Read-JsonFile -Path $path))["mcpServers"].ContainsKey("owned") | Should -BeTrue
    }

    It "keeps client config deletion outside ResetKit" {
        $resetKitText = [regex]::Match($ScriptText, '(?s)function Invoke-ResetKit \{(.*?)function Protect-LocalGoogleOAuthMcpEnvironment').Groups[1].Value
        $resetKitText | Should -Not -Match '\.mcp\.json'
        $resetKitText | Should -Not -Match '\.codex\\config\.toml'
        $resetKitText | Should -Not -Match '\.gemini\\settings\.json'
    }
}

Describe "Per-tool MCP credential isolation" {
    It "includes the tool identity in generated local launchers" {
        $server = [PSCustomObject]@{
            ToolName = "browserQa"
            ServerName = "playwright"
            Runner = "npx"
            Package = "@playwright/mcp@1.2.3"
            StartArgs = @()
        }
        $launcherArgs = @(Get-RunMcpLauncherArgs -Server $server)
        $launcherArgs | Should -Contain "-ToolName"
        $launcherArgs | Should -Contain "browserQa"
    }

    It "infers the tool for launchers generated before tool identity was recorded" {
        $context = Resolve-RunMcpCatalogContext -RequestedServerName "gtm" -RequestedRunner "npx" -RequestedPackage "mcp-remote@1.2.3"
        $context.ToolName | Should -Be "googleTagManager"
    }

    It "does not expose another tool's dummy credentials to a local MCP" {
        $envPath = Join-Path $TestDrive "isolated.env"
        Set-Content -LiteralPath $envPath -Value @(
            "TRELLO_API_KEY=dummy-trello-key",
            "GOOGLE_APPLICATION_CREDENTIALS=$TestDrive\dummy-adc.json"
        )
        [Environment]::SetEnvironmentVariable("TRELLO_API_KEY", "inherited-dummy-trello-key", "Process")
        [Environment]::SetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", "$TestDrive\inherited-dummy-adc.json", "Process")

        Set-RunMcpEnvironment -RequestedToolName "browserQa" -RequestedServerName "playwright" -RequestedRunner "npx" -RequestedPackage "@playwright/mcp@1.2.3" -DotEnvPath $envPath

        [Environment]::GetEnvironmentVariable("TRELLO_API_KEY", "Process") | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", "Process") | Should -BeNullOrEmpty
    }

    It "passes only the selected Google Drive dummy paths and required aliases" {
        $envPath = Join-Path $TestDrive "drive.env"
        $oauthPath = Join-Path $TestDrive "oauth-client.json"
        $tokenPath = Join-Path $TestDrive "drive-token.json"
        Set-Content -LiteralPath $envPath -Value @(
            "GOOGLE_OAUTH_CLIENT_JSON=$oauthPath",
            "GDRIVE_CREDENTIALS_PATH=$tokenPath",
            "TRELLO_TOKEN=dummy-unrelated-token",
            "GOOGLE_APPLICATION_CREDENTIALS=$TestDrive\dummy-adc.json"
        )

        Set-RunMcpEnvironment -RequestedToolName "googleDrive" -RequestedServerName "google-drive" -RequestedRunner "npx" -RequestedPackage "@piotr-agier/google-drive-mcp@1.2.3" -DotEnvPath $envPath

        [Environment]::GetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_JSON", "Process") | Should -Be $oauthPath
        [Environment]::GetEnvironmentVariable("GDRIVE_OAUTH_PATH", "Process") | Should -Be $oauthPath
        [Environment]::GetEnvironmentVariable("GOOGLE_DRIVE_OAUTH_CREDENTIALS", "Process") | Should -Be $oauthPath
        [Environment]::GetEnvironmentVariable("GOOGLE_DRIVE_MCP_TOKEN_PATH", "Process") | Should -Be $tokenPath
        [Environment]::GetEnvironmentVariable("TRELLO_TOKEN", "Process") | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", "Process") | Should -BeNullOrEmpty
    }
}

Describe "Selected clients and exact version locks" {
    It "targets only clients selected in local configuration" {
        $selection = [PSCustomObject]@{
            aiClients = [PSCustomObject]@{ codex = $true; claudeCode = $false; geminiCli = $true }
        }
        @(Resolve-TargetClients -Selection $selection -RequestedClient "Selected") | Should -Be @("Codex", "Gemini")
    }

    It "resolves an exact package from the local version lock" {
            $lockPath = Join-Path $TestDrive "mcp-version-lock.json"
            Write-JsonFile -Object @{
                version = 1
                entries = @{
                    "browserQa|playwright-official-mcp" = @{
                        packageName = "@playwright/mcp"
                        resolvedPackage = "@playwright/mcp@1.2.3"
                    }
                }
            } -Path $lockPath
            $item = [PSCustomObject]@{ package = "@playwright/mcp@latest"; runner = "npx"; selectedProvider = "playwright-official-mcp" }
            (Resolve-LockedPackageSpec -ToolName "browserQa" -Item $item -LockPath $lockPath) | Should -Be "@playwright/mcp@1.2.3"
    }

    It "refuses floating local package execution without a lock" {
            $lockPath = Join-Path $TestDrive "missing-lock.json"
            $item = [PSCustomObject]@{ package = "@playwright/mcp@latest"; runner = "npx"; selectedProvider = "playwright-official-mcp" }
            { Resolve-LockedPackageSpec -ToolName "browserQa" -Item $item -LockPath $lockPath } | Should -Throw "*No exact package lock*"
    }
}

Describe "Evidence and action surface" {
    It "preserves tool evidence when the handover state is updated" {
            $statePath = Join-Path $TestDrive "onboarding-state.json"
            $state = @{ toolEvidence = @{ browserQa = @{ provider = "playwright-official-mcp"; stages = @{ Verified = @{ outcome = "Passed"; recordedAt = "2026-07-10T10:00:00Z"; target = "public page"; evidence = "Title returned" } } } } }
            Write-OnboardingState -State $state -Path $statePath
            $loaded = Read-OnboardingState -Path $statePath
            $loaded["toolEvidence"]["browserQa"]["stages"]["Verified"]["outcome"] | Should -Be "Passed"
    }

    It "invalidates incomplete legacy evidence instead of treating it as verified" {
            $statePath = Join-Path $TestDrive "legacy-state.json"
            Write-JsonFile -Object @{ toolEvidence = @{ browserQa = @{ provider = "playwright-official-mcp"; stages = @{ Verified = @{ outcome = "Passed"; evidence = "Old proof" } } } } } -Path $statePath
            $loaded = Read-OnboardingState -Path $statePath
            $loaded["toolEvidence"]["browserQa"]["stages"]["Verified"]["outcome"] | Should -Be "Pending"
            $loaded["toolEvidence"]["browserQa"]["stages"]["Verified"]["evidence"] | Should -Match "repeat"
    }

    It "exposes preview, evidence, safe reset, and update-lock actions" {
        $ScriptText | Should -Match '"RecordEvidence"'
        $ScriptText | Should -Match '"ResetMcpConfig"'
        $ScriptText | Should -Match '\[switch\]\$Preview'
        $ScriptText | Should -Match 'mcp-version-lock\.json'
    }

    It "keeps user-facing safety outputs ignored and generated on demand" {
        $ScriptText | Should -Match 'bigquery-safety-plan\.md'
        $ScriptText | Should -Match 'credential-guide\.md'
        $ScriptText | Should -Match 'mcp-update-check\.md'
    }

    It "detects representative secret and local-identifier canaries" {
        $patterns = @(Get-ReleaseSecretPatterns)
        $canaries = @(
            ("GOC" + "SPX-example-secret"),
            ("gh" + "p_exampletoken"),
            ("GTM-" + "ABCDEF"),
            ("C:" + "\Users\Example\secret.json")
        )
        foreach ($canary in $canaries) {
            @($patterns | Where-Object { $canary -cmatch $_ }).Count | Should -BeGreaterThan 0
        }
    }
}
