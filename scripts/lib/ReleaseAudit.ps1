function Invoke-ReleaseAudit {
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $reportPath = Join-Path $GeneratedDir "release-audit.md"
    $zipPath = Join-Path $env:TEMP "web-analyst-mcp-setup-release-audit.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    $errors = @()
    $warnings = @()
    $lines = @()
    $lines += "# Release Audit"
    $lines += ""
    $lines += "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))"
    $lines += ""

    try {
        Invoke-ValidateKit -Quiet
        $lines += "- Kit validation: OK"
    } catch {
        $errors += "Kit validation failed: $($_.Exception.Message)"
        $lines += "- Kit validation: FAILED"
    }

    try {
        Invoke-PesterTests
        $lines += "- Pester tests: OK"
    } catch {
        $errors += "Pester tests failed: $($_.Exception.Message)"
        $lines += "- Pester tests: FAILED"
    }

    $trackedFiles = @(git ls-files)
    if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) {
        $errors += "Could not list tracked files with git ls-files."
    }

    $statusLines = @(git status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        $errors += "Could not inspect working tree status with git status."
    } elseif ($statusLines.Count -gt 0) {
        $releasableDirty = @()
        foreach ($statusLine in $statusLines) {
            $pathText = $statusLine.Substring(3).Trim()
            if ($pathText -match " -> ") { $pathText = ($pathText -split " -> ")[-1].Trim() }
            $normalizedPath = $pathText -replace "\\", "/"
            if ($normalizedPath -like "generated/*") { continue }
            if ($normalizedPath -eq "config/tool-selection.json") { continue }
            if ($normalizedPath -like "secrets/*" -and $normalizedPath -ne "secrets/.env.template") { continue }
            if ($normalizedPath -in @(".mcp.json", ".codex/config.toml", ".gemini/settings.json")) { continue }
            $releasableDirty += $statusLine
        }
        if ($releasableDirty.Count -gt 0) {
            $errors += "Working tree has uncommitted releasable changes. Commit, revert, or intentionally exclude them before release: $($releasableDirty -join '; ')"
        }
    }

    $forbiddenTracked = @(
        "secrets/.env.local",
        "config/tool-selection.json",
        "generated/mcp.json",
        "generated/codex.config-snippet.toml",
        "generated/onboarding-report.md",
        "generated/onboarding-state.json",
        "generated/first-day-checklist.md",
        "generated/credential-guide.md",
        "generated/bigquery-safety-plan.md",
        "generated/mcp-update-check.md",
        "generated/catalog-review.md",
        "generated/fixture-test-report.md",
        "generated/release-audit.md",
        ".mcp.json",
        ".codex/config.toml",
        ".gemini/settings.json"
    )
    $trackedViolations = @($forbiddenTracked | Where-Object { $trackedFiles -contains $_ })
    if ($trackedViolations.Count -gt 0) {
        $errors += "Forbidden local/runtime files are tracked: $($trackedViolations -join ', ')"
    }

    $secretPatterns = @(
        ("GOC" + "SPX[-_A-Za-z0-9]+"),
        ("github" + "_pat_[A-Za-z0-9_]+"),
        ("gh" + "p_[A-Za-z0-9]+"),
        ("gh" + "o_[A-Za-z0-9]+"),
        "client_secret_\d+",
        "C:\\Users\\[^\\]+",
        "Downloads\\[^\\]+",
        "refresh_token\s*[:=]\s*[""']?(1//|1/)[A-Za-z0-9_\-]+",
        "access_token\s*[:=]\s*[""']?(ya29\.|glpat-|github_pat_|ghp_|gho_)[A-Za-z0-9_\-.]+",
        "private_key\s*[:=]",
        "GTM-[A-Z0-9]{6,}",
        "G-[A-Z0-9]{6,}",
        "UA-\d+-\d+"
    )

    $scanHits = @()
    foreach ($file in $trackedFiles) {
        $fullPath = Join-Path $Root $file
        if (-not (Test-Path -LiteralPath $fullPath)) { continue }
        $contentLines = @(Get-Content -LiteralPath $fullPath -ErrorAction SilentlyContinue)
        foreach ($pattern in $secretPatterns) {
            if (@($contentLines | Where-Object { $_ -cmatch $pattern }).Count -gt 0) {
                $scanHits += "$file ($pattern)"
            }
        }
    }
    if ($scanHits.Count -gt 0) {
        $errors += "Potential personal/credential patterns found: $($scanHits -join '; ')"
    }

    $diffCheck = git diff --check 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errors += "git diff --check failed: $($diffCheck -join ' ')"
    }

    git archive --format=zip --output=$zipPath HEAD
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zipPath)) {
        $errors += "Could not create release audit ZIP with git archive."
    }

    $zipEntries = @()
    if (Test-Path -LiteralPath $zipPath) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $zipEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName } | Sort-Object)
        } finally {
            $zip.Dispose()
        }
        $hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
        $lines += "- Archive: $zipPath"
        $lines += "- SHA256: $($hash.Hash)"
        $lines += "- Archive entries: $($zipEntries.Count)"
    }

    $lines += ""
    $lines += "## Tracked Files"
    $lines += ""
    foreach ($file in $trackedFiles) { $lines += "- $file" }

    $lines += ""
    $lines += "## Archive Entries"
    $lines += ""
    foreach ($entry in $zipEntries) { $lines += "- $entry" }

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
        Write-Host "Wrote release audit report: $reportPath"
        throw "Release audit failed with $($errors.Count) error(s)."
    }

    $lines += ""
    $lines += "Result: OK"
    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    Write-Host "Release audit passed."
    Write-Host "Wrote release audit report: $reportPath"
}
