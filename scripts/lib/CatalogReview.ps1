function Invoke-CatalogReview {
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $reportPath = Join-Path $GeneratedDir "catalog-review.md"
    $errors = @()
    $warnings = @()
    $rows = @()

    try {
        Invoke-ValidateKit -Quiet
    } catch {
        $errors += "Validation failed before catalog review: $($_.Exception.Message)"
    }

    $catalog = Read-JsonFile -Path $CatalogPath
    $today = Get-Date
    $serverOwners = @{}

    foreach ($entry in $catalog.PSObject.Properties) {
        $toolName = $entry.Name
        $providerEntries = @(
            [PSCustomObject]@{
                ToolName = $toolName
                ProviderName = if ($entry.Value.defaultProvider) { [string]$entry.Value.defaultProvider } else { "default" }
                Item = $entry.Value
            }
        )

        if ($entry.Value.providers) {
            foreach ($provider in $entry.Value.providers.PSObject.Properties) {
                $providerEntries += [PSCustomObject]@{
                    ToolName = $toolName
                    ProviderName = $provider.Name
                    Item = Resolve-CatalogItem -CatalogItem $entry.Value -Provider $provider.Name
                }
            }
        }

        foreach ($providerEntry in $providerEntries) {
            $item = $providerEntry.Item
            $serverName = [string]$item.serverName
            if (-not [string]::IsNullOrWhiteSpace($serverName)) {
                if (-not $serverOwners.ContainsKey($serverName)) { $serverOwners[$serverName] = @() }
                $serverOwners[$serverName] += "$($providerEntry.ToolName)/$($providerEntry.ProviderName)"
            }

            $lastVerified = [DateTime]::MinValue
            if (-not [DateTime]::TryParseExact([string]$item.lastVerified, "yyyy-MM-dd", $null, [System.Globalization.DateTimeStyles]::None, [ref]$lastVerified)) {
                $errors += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) has invalid lastVerified value '$($item.lastVerified)'."
            } else {
                $reviewDays = Get-CatalogReviewWindowDays -LifecycleStatus ([string]$item.lifecycleStatus)
                if (($today - $lastVerified).TotalDays -gt $reviewDays) {
                    $warnings += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) is outside its $reviewDays-day verification window."
                }
            }

            if ($item.kind -eq "mcp" -and $item.transport -eq "stdio" -and $item.runner -eq "npx" -and $item.package -and ([string]$item.package -notmatch "@latest$")) {
                $warnings += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) uses npm package '$($item.package)' without @latest."
            }
            if ($item.runtime -eq "python" -and $providerEntry.ToolName -ne "googleAnalytics") {
                $warnings += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) is Python-based. Confirm there is no credible Node or remote first-day option."
            }
            if ($item.officialness -match "third-party" -and $item.riskLevel -eq "high") {
                $warnings += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) is third-party and high risk. Confirm user approval and, for organizational data or accounts, organizational permission before use."
            }
            if ($item.lifecycleStatus -eq "default" -and @($item.knownLimitations).Count -eq 0) {
                $warnings += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) is a default provider but has no known limitations documented."
            }
            if ($item.lifecycleStatus -in @("candidate", "private-beta", "deprecated") -and $item.riskLevel -eq "low") {
                $warnings += "$($providerEntry.ToolName)/$($providerEntry.ProviderName) has lifecycle '$($item.lifecycleStatus)' but low risk. Recheck risk metadata."
            }

            $rows += [PSCustomObject]@{
                Tool = $providerEntry.ToolName
                Provider = $providerEntry.ProviderName
                DisplayName = [string]$item.displayName
                Lifecycle = [string]$item.lifecycleStatus
                Kind = [string]$item.kind
                Runtime = [string]$item.runtime
                Auth = [string]$item.authMode
                Officialness = [string]$item.officialness
                Risk = [string]$item.riskLevel
                LastVerified = [string]$item.lastVerified
                Source = [string]$item.source
            }
        }
    }

    foreach ($serverName in $serverOwners.Keys) {
        $owners = @($serverOwners[$serverName] | Select-Object -Unique)
        $distinctTools = @($owners | ForEach-Object { ($_ -split "/")[0] } | Select-Object -Unique)
        if ($distinctTools.Count -gt 1) {
            $errors += "Server name '$serverName' is shared by different tools: $($owners -join ', ')."
        }
    }

    $lines = @()
    $lines += "# MCP Catalog Review"
    $lines += ""
    $lines += "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))"
    $lines += ""
    $lines += "This report is generated from reusable catalog metadata. It does not include local credentials."
    $lines += ""
    $lines += "## Provider Matrix"
    $lines += ""
    $lines += "| Tool | Provider | Lifecycle | Kind | Runtime | Auth | Officialness | Risk | Last Verified |"
    $lines += "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    foreach ($row in @($rows | Sort-Object Tool, Provider)) {
        $lines += "| $($row.Tool) | $($row.Provider) | $($row.Lifecycle) | $($row.Kind) | $($row.Runtime) | $($row.Auth) | $($row.Officialness) | $($row.Risk) | $($row.LastVerified) |"
    }

    if ($warnings.Count -gt 0) {
        $lines += ""
        $lines += "## Warnings"
        $lines += ""
        foreach ($warning in $warnings) { $lines += "- $warning" }
    }

    if ($errors.Count -gt 0) {
        $lines += ""
        $lines += "## Errors"
        $lines += ""
        foreach ($errorItem in $errors) { $lines += "- $errorItem" }
        Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
        Write-Host "Wrote catalog review: $reportPath"
        throw "Catalog review failed with $($errors.Count) error(s)."
    }

    $lines += ""
    $lines += "Result: OK"
    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    Write-Host "Catalog review passed with $($warnings.Count) warning(s)."
    Write-Host "Wrote catalog review: $reportPath"
}
