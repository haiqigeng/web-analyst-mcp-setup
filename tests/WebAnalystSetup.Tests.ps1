BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $CatalogPath = Join-Path $RepoRoot "config\mcp-catalog.json"
    $SelectionExamplePath = Join-Path $RepoRoot "config\tool-selection.example.json"
    $ScriptPath = Join-Path $RepoRoot "scripts\WebAnalystSetup.ps1"
    $Catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $SelectionExample = Get-Content -Raw -LiteralPath $SelectionExamplePath | ConvertFrom-Json
    $ScriptText = Get-Content -Raw -LiteralPath $ScriptPath
}

Describe "Reusable kit hygiene" {
    It "does not track local runtime files" {
        $tracked = git -C $RepoRoot ls-files
        foreach ($path in @(
            "secrets/.env.local",
            "config/tool-selection.json",
            "generated/onboarding-report.md",
            "generated/onboarding-state.json",
            "generated/first-day-checklist.md",
            "generated/credential-guide.md",
            "generated/bigquery-safety-plan.md",
            "generated/mcp-update-check.md",
            ".mcp.json",
            ".codex/config.toml",
            ".gemini/settings.json"
        )) {
            ($tracked -contains $path) | Should -BeFalse
        }
    }

    It "keeps reusable selection profile-free by default" {
        $SelectionExample.PSObject.Properties.Name -contains "profile" | Should -BeFalse
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

    It "uses @latest for npm-based default package entries" {
        foreach ($tool in $Catalog.PSObject.Properties) {
            if ($tool.Value.runner -eq "npx" -and $tool.Value.package) {
                [string]$tool.Value.package | Should -Match "@latest$"
            }
        }
    }
}

Describe "Setup action surface" {
    It "exposes credential guide and BigQuery safety actions" {
        $ScriptText | Should -Match '"CredentialGuide"'
        $ScriptText | Should -Match '"BigQuerySafetyPlan"'
        $ScriptText | Should -Match '"PesterTests"'
    }

    It "keeps BigQuery safety output ignored and generated on demand" {
        $ScriptText | Should -Match 'bigquery-safety-plan\.md'
        $ScriptText | Should -Match 'credential-guide\.md'
        $ScriptText | Should -Match 'mcp-update-check\.md'
    }
}
