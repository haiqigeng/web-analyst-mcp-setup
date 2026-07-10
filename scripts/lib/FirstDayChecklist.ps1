function Get-ChecklistBucket {
    param($Row, $CatalogItem)

    $status = [string]$Row.Status
    $credentialState = [string]$Row.CredentialState
    $auth = [string]$Row.Auth

    if ($credentialState -like "Missing:*" -or $status -like "Needs credentials*") {
        return "Needs credentials"
    }
    if ($auth -match "oauth|adc" -or $status -match "authentication|browser auth|ADC|OAuth|Token present") {
        return "Needs login or token check"
    }
    if ($CatalogItem.riskLevel -eq "high" -or $CatalogItem.writeCapability -match "write|send|publish|cost|delete") {
        return "Needs approval before write/cost actions"
    }
    return "Ready for smoke test"
}

function Get-ChecklistPriority {
    param($Item)

    if ($Item.CredentialState -like "Needs auth choice:*") { return 5 }
    if ($Item.Auth -match "adc" -and $Item.CredentialState -notlike "Present:*") { return 5 }
    if ($Item.WriteCapability -match "cost" -and $Item.CredentialState -notlike "Short-lived*" -and $Item.CredentialState -notlike "Present:*") { return 5 }
    if ($Item.Auth -eq "none") { return 1 }
    if ($Item.Auth -eq "user_oauth_remote") { return 2 }
    if ($Item.Auth -match "adc" -and $Item.CredentialState -like "Present:*") { return 3 }
    if ($Item.WriteCapability -match "cost" -and ($Item.CredentialState -like "Short-lived*" -or $Item.CredentialState -like "Present:*")) { return 3 }
    if ($Item.Auth -match "oauth|browser" -and $Item.CredentialState -notlike "Missing:*") { return 2 }
    if ($Item.CredentialState -like "Missing:*") { return 4 }
    if ($Item.Risk -eq "high" -or $Item.WriteCapability -match "cost|publish|delete|send|write") { return 3 }
    return 2
}

function Get-ChecklistAuthStatus {
    param($Item)

    if ($Item.Auth -eq "none") { return "No auth needed" }
    if ($Item.CredentialState -eq "No credentials required" -and $Item.Auth -match "oauth|adc") { return "Needs browser/login check" }
    if ($Item.CredentialState -eq "No credentials required") { return "No local secret required" }
    if ($Item.CredentialState -like "Present:*" -or $Item.CredentialState -like "Token present*" -or $Item.CredentialState -like "Short-lived*") { return "Credential/token present" }
    if ($Item.CredentialState -like "Missing:*") { return "Needs credential" }
    if ($Item.Auth -match "oauth|adc") { return "Needs login check" }
    return $Item.CredentialState
}

function Invoke-FirstDayChecklist {
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $checklistPath = Join-Path $GeneratedDir "first-day-checklist.md"

    $selectionFile = if (Test-Path -LiteralPath $SelectionPath) { $SelectionPath } else { $SelectionExamplePath }
    $selection = Read-JsonFile -Path $selectionFile
    $catalog = Read-JsonFile -Path $CatalogPath
    $toolRows = @(Get-ToolStatusRows -UseExampleWhenLocalSelectionMissing | Where-Object { $_.Enabled })
    $profileName = if (Test-ObjectProperty -Object $selection -Name "profile") { [string]$selection.profile } else { "" }
    if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = "custom or not selected" }
    $selectionSource = if ($profileName -eq "custom or not selected") { "manual/custom tool selection" } else { "profile '$profileName' (manual helper)" }

    $items = @()
    foreach ($row in $toolRows) {
        $selectionTool = $selection.tools.($row.Tool)
        $item = Resolve-CatalogItem -CatalogItem $catalog.($row.Tool) -Provider ([string]$selectionTool.provider)
        if (-not $item) { continue }
        $bucket = Get-ChecklistBucket -Row $row -CatalogItem $item
        $items += [PSCustomObject]@{
            Tool = [string]$row.DisplayName
            Bucket = $bucket
            Provider = [string]$row.Provider
            Runtime = [string]$row.Runtime
            Auth = [string]$row.Auth
            CredentialState = [string]$row.CredentialState
            Configured = [string]$row.Configured
            Visible = [string]$row.Visible
            Verified = [string]$row.Verified
            Risk = [string]$item.riskLevel
            WriteCapability = [string]$item.writeCapability
            NextStep = [string]$row.NextStep
            SmokeTest = [string]$item.testPrompt
        }
    }

    $lines = @()
    $lines += "# First-Day Checklist"
    $lines += ""
    $lines += "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))"
    $lines += "Selection source: $selectionSource"
    $lines += ""
    $lines += "This checklist is generated from the local tool selection and credential key presence. It does not print secret values."
    $lines += "Use it as the user-facing day-one action list. `onboarding-state.json` is internal resume state for agents/scripts."
    $lines += ""

    if ($items.Count -eq 0) {
        $lines += "No tools are enabled yet."
        $lines += ""
        $lines += "Next step: choose tools with the user, then rerun ``FirstDayChecklist``."
        Set-Content -LiteralPath $checklistPath -Value $lines -Encoding UTF8
        Write-Host "Wrote first-day checklist: $checklistPath"
        return
    }

    $lines += "## MCP Configuration Status"
    $lines += ""
    $lines += "| Tool | Configured | Authenticated | Visible In Current AI Session | Verified | Next Step |"
    $lines += "| --- | --- | --- | --- | --- | --- |"
    foreach ($item in @($items | Sort-Object @{ Expression = { Get-ChecklistPriority -Item $_ } }, Tool)) {
        $safeNextStep = $item.NextStep -replace "\|", "/"
        $authStatus = Get-ChecklistAuthStatus -Item $item
        $lines += "| $($item.Tool) | $($item.Configured) | $authStatus | $($item.Visible) | $($item.Verified) | $safeNextStep |"
    }
    $lines += ""

    $lines += "## Recommended Setup Order"
    $lines += ""
    foreach ($item in @($items | Sort-Object @{ Expression = { Get-ChecklistPriority -Item $_ } }, Tool)) {
        $safeNextStep = $item.NextStep -replace "\|", "/"
        $lines += "- $($item.Tool): $safeNextStep"
    }
    $lines += ""

    $bucketOrder = @(
        "Needs credentials",
        "Needs login or token check",
        "Ready for smoke test",
        "Needs approval before write/cost actions"
    )

    foreach ($bucket in $bucketOrder) {
        $bucketItems = @($items | Where-Object { $_.Bucket -eq $bucket } | Sort-Object Tool)
        $lines += "## $bucket"
        $lines += ""
        if ($bucketItems.Count -eq 0) {
            $lines += "- None."
            $lines += ""
            continue
        }

        $lines += "| Tool | Credential State | Next Step |"
        $lines += "| --- | --- | --- |"
        foreach ($item in $bucketItems) {
            $safeNextStep = $item.NextStep -replace "\|", "/"
            $lines += "| $($item.Tool) | $($item.CredentialState) | $safeNextStep |"
        }
        $lines += ""
    }

    $lines += "## Smoke Tests"
    $lines += ""
    $lines += "| Tool | Harmless Test |"
    $lines += "| --- | --- |"
    foreach ($item in @($items | Sort-Object Tool)) {
        $safeSmokeTest = $item.SmokeTest -replace "\|", "/"
        $lines += "| $($item.Tool) | $safeSmokeTest |"
    }

    $lines += ""
    $lines += "## Safety Reminders"
    $lines += ""
    $lines += "- Start with read-only smoke tests."
    $lines += "- Confirm before Gmail send/delete, Drive file edits, GTM publish, broad or costly BigQuery SQL, vendor setting changes, or browser inspection of sensitive authenticated pages."
    $lines += "- During MCP setup, delete or publish actions related to MCP endpoints require explicit approval and an exact target ID/name."
    $lines += "- Keep credentials and generated files local; do not commit `secrets/.env.local`, tokens, generated MCP config, or this checklist."

    Set-Content -LiteralPath $checklistPath -Value $lines -Encoding UTF8
    Write-Host "Wrote first-day checklist: $checklistPath"
}
