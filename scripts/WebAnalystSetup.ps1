[CmdletBinding()]
param(
    [ValidateSet("Prepare", "UseProfile", "Validate", "Doctor", "CredentialGuide", "BigQuerySafetyPlan", "FirstDayChecklist", "OnboardingReport", "ReleaseAudit", "CatalogReview", "TestFixtures", "PesterTests", "Prereqs", "CheckMcpUpdates", "Generate", "Apply", "Status", "Dashboard", "RunMcp", "GoogleOAuthFile", "GoogleAdcLogin", "RefreshGoogleDriveToken", "BigQueryAdcBearerToken", "ResetKit", "ResetCodexMcp", "All")]
    [string]$Action = "Status",

    [ValidateSet("All", "Codex", "Claude", "Gemini")]
    [string]$Client = "All",

    [string]$Profile,
    [string]$ServerName,
    [ValidateSet("npx", "pipx")]
    [string]$Runner = "npx",
    [string]$Package,
    [string[]]$McpArgs = @(),
    [string]$McpArgsJson,
    [string]$McpArgsBase64,
    [switch]$InstallPython,
    [switch]$ConfirmedMcpEndpointDeletion
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$SelectionPath = Join-Path $Root "config\tool-selection.json"
$SelectionExamplePath = Join-Path $Root "config\tool-selection.example.json"
$CatalogPath = Join-Path $Root "config\mcp-catalog.json"
$ProfilesPath = Join-Path $Root "config\tool-profiles.json"
$ClientCapabilitiesPath = Join-Path $Root "config\client-capabilities.json"
$EnvPath = Join-Path $Root "secrets\.env.local"
$EnvTemplatePath = Join-Path $Root "secrets\.env.template"
$GeneratedDir = Join-Path $Root "generated"
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

function Sync-DotEnvTemplateKeys {
    param([string]$TemplatePath, [string]$TargetPath)
    if (-not (Test-Path -LiteralPath $TemplatePath) -or -not (Test-Path -LiteralPath $TargetPath)) { return }

    $existing = @{}
    Get-Content -LiteralPath $TargetPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $existing[$line.Substring(0, $idx).Trim()] = $true
    }

    $missingLines = @()
    Get-Content -LiteralPath $TemplatePath | ForEach-Object {
        $line = $_
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { return }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { return }
        $key = $trimmed.Substring(0, $idx).Trim()
        if (-not $existing.ContainsKey($key)) {
            $missingLines += $line
            $existing[$key] = $true
        }
    }

    if ($missingLines.Count -gt 0) {
        Add-Content -LiteralPath $TargetPath -Value ""
        Add-Content -LiteralPath $TargetPath -Value "# Added from the current web analyst template."
        Add-Content -LiteralPath $TargetPath -Value $missingLines
    }
}

function Ensure-LocalFiles {
    New-Item -ItemType Directory -Force (Join-Path $Root "config") | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Root "secrets") | Out-Null
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null

    if (-not (Test-Path -LiteralPath $SelectionPath)) {
        Copy-Item -LiteralPath $SelectionExamplePath -Destination $SelectionPath
        Write-Host "Created config\tool-selection.json."
    }
    if (-not (Test-Path -LiteralPath $EnvPath)) {
        Copy-Item -LiteralPath $EnvTemplatePath -Destination $EnvPath
        Write-Host "Created secrets\.env.local."
    }
    Sync-DotEnvTemplateKeys -TemplatePath $EnvTemplatePath -TargetPath $EnvPath
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) { $hash[$key] = ConvertTo-Hashtable $InputObject[$key] }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $array = @()
            foreach ($item in $InputObject) { $array += ConvertTo-Hashtable $item }
            return $array
        }
        if ($InputObject.PSObject.Properties.Count -gt 0 -and $InputObject.GetType().Name -eq "PSCustomObject") {
            $hash = @{}
            foreach ($prop in $InputObject.PSObject.Properties) { $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value }
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

        $status = if ($enabled) { "Selected" } else { "Available" }
        $nextStep = [string]$item.testPrompt
        if ($enabled -and $missing.Count -gt 0) {
            $status = "Needs credentials"
            $nextStep = "Collect approved credential values for: " + ($missing -join ", ")
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

        $rows += [PSCustomObject]@{
            Tool = $tool.Name
            DisplayName = [string]$item.displayName
            Enabled = $enabled
            Provider = if ($item.selectedProvider) { [string]$item.selectedProvider } else { [string]$tool.Value.provider }
            Kind = [string]$item.kind
            Runtime = [string]$item.runtime
            Auth = [string]$item.authMode
            CredentialState = $credentialState
            Status = $status
            NextStep = $nextStep
            Configured = if ($enabled) { "Selected; run Apply if config changed" } else { "Not selected" }
            Authenticated = $authenticated
            Visible = "Check active client after Apply/reload"
            Verified = "Pending read-only proof"
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

function Invoke-UseProfile {
    Ensure-LocalFiles | Out-Null
    if (-not (Test-Path -LiteralPath $ProfilesPath)) {
        throw "Missing profile catalog: $ProfilesPath"
    }

    $profilesRoot = Read-JsonFile -Path $ProfilesPath
    $availableProfiles = @(Get-PropertyNames -Object $profilesRoot.profiles)
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        Write-Step "Available profiles"
        $availableProfiles | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "Run again with -Profile <name>."
        return
    }
    if ($availableProfiles -notcontains $Profile) {
        throw "Unknown profile '$Profile'. Available profiles: $($availableProfiles -join ', ')"
    }

    $profileObject = $profilesRoot.profiles.($Profile)
    $selection = Read-JsonFile -Path $SelectionPath
    $catalog = Read-JsonFile -Path $CatalogPath

    foreach ($tool in $selection.tools.PSObject.Properties) {
        $tool.Value.enabled = $false
    }

    foreach ($tool in $profileObject.tools.PSObject.Properties) {
        if (-not (Test-ObjectProperty -Object $catalog -Name $tool.Name)) {
            throw "Profile '$Profile' references unknown tool '$($tool.Name)'."
        }
        if (-not (Test-ObjectProperty -Object $selection.tools -Name $tool.Name)) {
            $selection.tools | Add-Member -NotePropertyName $tool.Name -NotePropertyValue ([PSCustomObject]@{ enabled = $false; provider = "" })
        }
        $selection.tools.($tool.Name).enabled = [bool]$tool.Value.enabled
        if (Test-ObjectProperty -Object $tool.Value -Name "provider") {
            $selection.tools.($tool.Name).provider = [string]$tool.Value.provider
        } elseif (Test-ObjectProperty -Object $catalog.($tool.Name) -Name "defaultProvider") {
            $selection.tools.($tool.Name).provider = [string]$catalog.($tool.Name).defaultProvider
        }
    }

    $selection | Add-Member -NotePropertyName "profile" -NotePropertyValue $Profile -Force
    Write-JsonFile -Object $selection -Path $SelectionPath
    Write-Host "Applied profile '$Profile' to config\tool-selection.json."
    if ($profileObject.description) {
        Write-Host ([string]$profileObject.description)
    }
}

function Invoke-ValidateKit {
    param([switch]$Quiet)

    $errors = @()
    $warnings = @()
    $requiredFiles = @(
        "README.md",
        "AGENTS.md",
        ".gitignore",
        "config\mcp-catalog.json",
        "config\tool-selection.example.json",
        "config\tool-profiles.json",
        "config\client-capabilities.json",
        "secrets\.env.template",
        "scripts\WebAnalystSetup.ps1",
        "scripts\lib\CatalogReview.ps1",
        "scripts\lib\FirstDayChecklist.ps1",
        "scripts\lib\PesterTests.ps1",
        "scripts\lib\ReleaseAudit.ps1",
        "scripts\lib\TestFixtures.ps1",
        "schemas\mcp-catalog.schema.json",
        "schemas\tool-selection.schema.json",
        "schemas\tool-profiles.schema.json",
        "schemas\client-capabilities.schema.json",
        "tests\fixtures\profile-server-names.json",
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
    $profiles = $null
    $clientCapabilities = $null
    foreach ($relative in @("config\mcp-catalog.json", "config\tool-selection.example.json", "config\tool-profiles.json", "config\client-capabilities.json", "tests\fixtures\profile-server-names.json", "schemas\mcp-catalog.schema.json", "schemas\tool-selection.schema.json", "schemas\tool-profiles.schema.json", "schemas\client-capabilities.schema.json")) {
        $path = Join-Path $Root $relative
        if (Test-Path -LiteralPath $path) {
            try {
                $json = Read-JsonFile -Path $path
                if ($relative -eq "config\mcp-catalog.json") { $catalog = $json }
                if ($relative -eq "config\tool-selection.example.json") { $selectionExample = $json }
                if ($relative -eq "config\tool-profiles.json") { $profiles = $json }
                if ($relative -eq "config\client-capabilities.json") { $clientCapabilities = $json }
            } catch {
                $errors += "Invalid JSON in $relative`: $($_.Exception.Message)"
            }
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
        $requiredCatalogFields = @("displayName", "kind", "trustLevel", "lifecycleStatus", "recommendedUse", "fallbackWhen", "knownLimitations", "officialness", "authFriction", "runtime", "dataExposure", "writeCapability", "riskLevel", "lastVerified", "author", "source", "authMode", "serverName", "credentialKeys", "notes", "testPrompt")
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

    if ($profiles -and $catalog) {
        foreach ($profileEntry in $profiles.profiles.PSObject.Properties) {
            foreach ($tool in $profileEntry.Value.tools.PSObject.Properties) {
                if (-not (Test-ObjectProperty -Object $catalog -Name $tool.Name)) {
                    $errors += "Profile '$($profileEntry.Name)' references unknown tool '$($tool.Name)'."
                    continue
                }
                if (Test-ObjectProperty -Object $tool.Value -Name "provider") {
                    $providerName = [string]$tool.Value.provider
                    $catalogItem = $catalog.($tool.Name)
                    $validProviders = @()
                    if ($catalogItem.defaultProvider) { $validProviders += [string]$catalogItem.defaultProvider }
                    if ($catalogItem.providers) { $validProviders += @(Get-PropertyNames -Object $catalogItem.providers) }
                    if ($providerName -and $validProviders.Count -gt 0 -and $validProviders -notcontains $providerName) {
                        $errors += "Profile '$($profileEntry.Name)' uses invalid provider '$providerName' for '$($tool.Name)'."
                    }
                }
            }
        }
    }

    if ($clientCapabilities) {
        foreach ($clientEntry in $clientCapabilities.clients.PSObject.Properties) {
            foreach ($field in @("displayName", "configTargets", "supportsRemoteHttp", "supportsProjectConfig", "supportsMcpLogin", "restartGuidance", "notes")) {
                if (-not (Test-ObjectProperty -Object $clientEntry.Value -Name $field)) {
                    $errors += "Client capability '$($clientEntry.Name)' is missing field '$field'."
                }
            }
        }
    }

    $gitignore = Join-Path $Root ".gitignore"
    if (Test-Path -LiteralPath $gitignore) {
        $ignoreText = Get-Content -Raw -LiteralPath $gitignore
        foreach ($pattern in @("secrets/*", "!secrets/.env.template", "config/tool-selection.json", "generated/*")) {
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
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    $reportPath = Join-Path $GeneratedDir "onboarding-report.md"
    $statePath = Join-Path $GeneratedDir "onboarding-state.json"
    $selectionFile = if (Test-Path -LiteralPath $SelectionPath) { $SelectionPath } else { $SelectionExamplePath }
    $selection = Read-JsonFile -Path $selectionFile
    $catalog = Read-JsonFile -Path $CatalogPath
    $toolRows = @(Get-ToolStatusRows -UseExampleWhenLocalSelectionMissing)
    $enabledRows = @($toolRows | Where-Object { $_.Enabled })
    $envMap = Import-DotEnvMap -Path $EnvPath
    $generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    $profileName = if (Test-ObjectProperty -Object $selection -Name "profile") { [string]$selection.profile } else { "" }
    if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = "custom or not selected" }
    $selectionSource = if ($profileName -eq "custom or not selected") { "manual/custom tool selection" } else { "profile '$profileName' (manual helper)" }

    $lines = @()
    $lines += "# Web Analyst Onboarding Report"
    $lines += ""
    $lines += "Generated: $generatedAt"
    $lines += ""
    $lines += "Selection source: $selectionSource"
    $lines += ""
    $lines += "This report intentionally lists credential key names only. It never prints secret values."
    $lines += ""
    $lines += "## Generated Files"
    $lines += ""
    $lines += "| File | Usage |"
    $lines += "| --- | --- |"
    $lines += "| `generated/onboarding-report.md` | User-facing handover summary. |"
    $lines += "| `generated/first-day-checklist.md` | User-facing next actions and read-only smoke tests. |"
    $lines += ""
    $lines += "Internal resume state is also kept for agents/scripts, but it is not a user document."
    $lines += ""
    $lines += "## MCP Configuration Status"
    $lines += ""
    if ($enabledRows.Count -eq 0) {
        $lines += "No tools are currently enabled."
    } else {
        $lines += "| Tool | Provider | Configured | Authenticated | Visible | Verified | Next Step |"
        $lines += "| --- | --- | --- | --- | --- | --- | --- |"
        foreach ($row in $enabledRows) {
            $lines += "| $($row.DisplayName) | $($row.Provider) | $($row.Configured) | $($row.Authenticated) | $($row.Visible) | $($row.Verified) | $($row.NextStep -replace '\|', '/') |"
        }
    }

    $lines += ""
    $lines += "## Credential Keys"
    $lines += ""
    $credentialKeys = @()
    foreach ($row in $enabledRows) {
        $selectionTool = $selection.tools.($row.Tool)
        $item = Resolve-CatalogItem -CatalogItem $catalog.($row.Tool) -Provider ([string]$selectionTool.provider)
        $allKeys = @($item.credentialKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $allKeys += @($item.optionalCredentialKeys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        foreach ($key in $allKeys) {
            if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $credentialKeys += [string]$key }
        }
    }
    $credentialKeys = @($credentialKeys | Select-Object -Unique | Sort-Object)
    if ($credentialKeys.Count -eq 0) {
        $lines += "No credential keys are required by the selected tools."
    } else {
        $lines += "| Key | State |"
        $lines += "| --- | --- |"
        foreach ($key in $credentialKeys) {
            $state = "missing or not needed yet"
            if ($envMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($envMap[$key])) {
                $state = "present in local env file"
            } elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($key, "User")) -or -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($key, "Process"))) {
                $state = "present in environment"
            }
            $lines += "| $key | $state |"
        }
    }

    $lines += ""
    $lines += "## Safe Smoke Tests"
    $lines += ""
    if ($enabledRows.Count -eq 0) {
        $lines += "No smoke tests to run yet."
    } else {
        foreach ($row in $enabledRows) {
            $selectionTool = $selection.tools.($row.Tool)
            $item = Resolve-CatalogItem -CatalogItem $catalog.($row.Tool) -Provider ([string]$selectionTool.provider)
            $smokeTest = if ($item) { [string]$item.testPrompt } else { [string]$row.NextStep }
            $lines += "- $($row.DisplayName): $smokeTest"
        }
    }

    $lines += ""
    $lines += "## Handover Notes"
    $lines += ""
    $lines += "- Keep local credentials and tokens after a real onboarding so daily tools keep working."
    $lines += "- Run `ResetKit` only after a test, when leaving a client/company, or before sharing the reusable folder."
    $lines += "- Confirm before using write-capable MCPs, costly BigQuery queries, or browser tools on sensitive logged-in pages."
    $lines += "- During MCP setup, delete or publish actions related to MCP endpoints require explicit approval and an exact target ID/name."

    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    $state = [PSCustomObject]@{
        generatedAt = $generatedAt
        profile = $profileName
        sourceSelectionFile = $selectionFile.Substring($Root.Path.Length + 1)
        selectedTools = @($enabledRows | ForEach-Object {
            [PSCustomObject]@{
                tool = $_.Tool
                displayName = $_.DisplayName
                provider = $_.Provider
                kind = $_.Kind
                runtime = $_.Runtime
                auth = $_.Auth
                credentialState = $_.CredentialState
                status = $_.Status
                configured = $_.Configured
                authenticated = $_.Authenticated
                visible = $_.Visible
                verified = $_.Verified
                nextStep = $_.NextStep
            }
        })
        credentialKeys = @($credentialKeys)
        reminders = @(
            "Keep local credentials and tokens after a real onboarding so daily tools keep working.",
            "Run ResetKit only after a test, when leaving a client/company, or before sharing the reusable folder.",
            "Confirm before using write-capable MCPs, costly BigQuery queries, or browser tools on sensitive logged-in pages.",
            "During MCP setup, delete or publish actions related to MCP endpoints require explicit approval and an exact target ID/name."
        )
    }
    Write-JsonFile -Object $state -Path $statePath
    Invoke-FirstDayChecklist
    Write-Host "Wrote onboarding report: $reportPath"
    Write-Host "Wrote onboarding state for agents/scripts: $statePath"
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

function Invoke-Prereqs {
    $selectedItems = @(Get-SelectedCatalogItems)
    $needsPython = [bool]$InstallPython
    $needsGcloud = $false
    foreach ($selected in $selectedItems) {
        $item = $selected.Item
        if ($item.runner -eq "pipx") { $needsPython = $true }
        if ($item.authMode -eq "application_default_credentials" -or $item.authMode -eq "company_oauth_adc") { $needsGcloud = $true }
        if ($item.authMode -ne "company_oauth_remote" -and $null -ne $item.requiredGoogleServices -and @($item.requiredGoogleServices).Count -gt 0) { $needsGcloud = $true }
    }

    Write-Step "Checking winget"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Install Windows Package Manager, then rerun this script."
    }
    Write-Host "winget: $(& winget --version)"

    Write-Step "Checking Node.js LTS"
    Ensure-NodeOnPath
    $node = Get-Command node -ErrorAction SilentlyContinue
    $nodeMajor = $null
    if ($node) {
        $raw = & node --version
        if ($raw -match "v(\d+)") { $nodeMajor = [int]$matches[1] }
    }
    if (-not $nodeMajor -or $nodeMajor -lt 18) {
        winget install --id OpenJS.NodeJS.LTS --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "node: $(& node --version)"
        winget upgrade --id OpenJS.NodeJS.LTS --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
    }
    Ensure-NodeOnPath
    $npmCommand = Resolve-Npm
    Write-Host "npm: $(& $npmCommand --version)"

    Write-Step "Checking Git"
    $git = Get-GitCommand
    if (-not $git) {
        winget install --id Git.Git --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
        $git = Get-GitCommand
    } else {
        Write-Host "git: $(& $git --version)"
    }
    if ($git) {
        $gitDir = Split-Path -Parent $git
        if ($env:PATH -notlike "*$gitDir*") { $env:PATH = "$gitDir;$env:PATH" }
    }

    if ($needsPython) { Ensure-PythonAndPipx }
    if ($needsGcloud) { Ensure-GoogleCloudCli }
    Invoke-CheckMcpUpdates
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

function Get-CatalogFreshnessStatus {
    param($Item)
    $lastVerified = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact([string]$Item.lastVerified, "yyyy-MM-dd", $null, [System.Globalization.DateTimeStyles]::None, [ref]$lastVerified)) {
        return "Invalid lastVerified: $($Item.lastVerified)"
    }
    $ageDays = [int]((Get-Date) - $lastVerified).TotalDays
    if ($ageDays -gt 180) { return "Stale: verified $ageDays days ago" }
    if ($ageDays -gt 90) { return "Aging: verified $ageDays days ago" }
    return "Fresh: verified $ageDays days ago"
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
    $selectedItems = @(Get-SelectedCatalogItems | Where-Object { $_.Item.kind -eq "mcp" })
    $envMap = Import-DotEnvMap -Path $EnvPath
    $rows = @()

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
                $status = if ($mode -eq "uses @latest") { "OK" } else { "Review" }
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "npm package" -Status $status -Detail "npm $lookupName latest $latest; configured $($item.package) ($mode)."
            } catch {
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "npm package" -Status "Check" -Detail "Could not check npm package $lookupName. Verify the package source before installing."
            }
            continue
        }

        if ($runner -eq "pipx") {
            $python = Get-PythonCommand
            if (-not $python) {
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "PyPI package" -Status "Skipped" -Detail "Python is not available yet; verify upstream before install."
                continue
            }

            try {
                $pipRaw = & $python -m pip index versions ([string]$item.package) 2>$null
                if ($LASTEXITCODE -ne 0) { throw "pip index failed" }
                $firstLine = @($pipRaw | Where-Object { $_ -match "\(([^)]+)\)" } | Select-Object -First 1)
                $latest = $null
                if ($firstLine -and $firstLine[0] -match "\(([^)]+)\)") { $latest = $matches[1] }
                if ([string]::IsNullOrWhiteSpace($latest)) { throw "pip did not return a version" }
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "PyPI package" -Status "OK" -Detail "pip $($item.package) latest $latest; configured $($item.package)."
            } catch {
                $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "PyPI package" -Status "Check" -Detail "Could not check pip package $($item.package). Verify the package source before installing."
            }
            continue
        }

        $rows += New-McpUpdateResult -Tool $tool -Provider $provider -Check "package" -Status "Skipped" -Detail "Runner $runner is not covered by the update checker yet."
    }

    Write-Host (($rows | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
    Write-McpUpdateReport -Rows $rows
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
    $lines += "1. Use company-approved credentials or vault items first."
    $lines += "2. If Google OAuth credentials are missing and the company permits a new project, open the project selector URL, create/select the project, then enable only the APIs listed above."
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
    $lines += "- Estimated bytes exceed the local/company guardrail."
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

        $servers += [PSCustomObject]@{
            ToolName = $tool.Name
            ServerName = [string]$item.serverName
            Transport = $transport
            Runner = $runner
            Package = [string]$item.package
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
    param($Server)

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
    param($Servers)
    $mcpServers = @{}
    foreach ($server in $Servers) {
        if ($server.Transport -eq "http") {
            $mcpServers[$server.ServerName] = @{
                url = $server.Url
            }
            if (-not [string]::IsNullOrWhiteSpace($server.BearerTokenEnvVar)) {
                $mcpServers[$server.ServerName].bearer_token_env_var = $server.BearerTokenEnvVar
            }
            if ($server.RequiredScopes.Count -gt 0) {
                $mcpServers[$server.ServerName].scopes = @($server.RequiredScopes)
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
    param($Servers)
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
            $baseArgs = @(Get-RunMcpLauncherArgs -Server $server)
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

function Update-ManagedTextBlock {
    param([string]$Path, [string]$Block, [string[]]$ServerNames = @())
    $pattern = "(?s)\r?\n?# BEGIN WEB_ANALYST_MCP_MANAGED.*?# END WEB_ANALYST_MCP_MANAGED\r?\n?"
    $content = ""
    if (Test-Path -LiteralPath $Path) {
        $content = [regex]::Replace((Get-Content -Raw -LiteralPath $Path), $pattern, [Environment]::NewLine)
    }
    foreach ($serverName in $ServerNames) {
        $escapedName = [regex]::Escape($serverName)
        $serverPattern = "(?ms)^\[mcp_servers\.$escapedName\]\r?\n.*?(?=^\[|\z)"
        $content = [regex]::Replace($content, $serverPattern, "")
    }
    $newContent = $content.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $Block + [Environment]::NewLine
    Set-Content -LiteralPath $Path -Value $newContent -Encoding UTF8
}

function Merge-McpJsonFile {
    param([string]$Path, $NewObject)
    if (Test-Path -LiteralPath $Path) {
        $existing = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    } else {
        $existing = @{}
    }
    if (-not $existing.ContainsKey("mcpServers") -or $null -eq $existing["mcpServers"]) {
        $existing["mcpServers"] = @{}
    }
    foreach ($name in $NewObject.mcpServers.Keys) {
        $existing["mcpServers"][$name] = $NewObject.mcpServers[$name]
    }
    Write-JsonFile -Object $existing -Path $Path
}

function Invoke-Generate {
    $servers = @(Get-EnabledMcpServers)
    $jsonObject = New-McpJsonObject -Servers $servers
    $codexToml = New-CodexToml -Servers $servers
    New-Item -ItemType Directory -Force $GeneratedDir | Out-Null
    Write-JsonFile -Object $jsonObject -Path (Join-Path $GeneratedDir "mcp.json")
    Set-Content -LiteralPath (Join-Path $GeneratedDir "codex.config-snippet.toml") -Value $codexToml -Encoding UTF8
    Write-Host "Generated MCP config for $($servers.Count) server(s)."
}

function Invoke-Apply {
    Invoke-Generate
    $servers = @(Get-EnabledMcpServers)
    $jsonObject = New-McpJsonObject -Servers $servers
    $codexToml = New-CodexToml -Servers $servers
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $scope = [string]$selection.installScope
    if (-not $scope) { $scope = "user" }

    if ($Client -eq "All" -or $Client -eq "Codex") {
        if ($scope -eq "project") {
            $codexDir = Join-Path $Root ".codex"
        } else {
            $codexDir = Join-Path $env:USERPROFILE ".codex"
        }
        New-Item -ItemType Directory -Force $codexDir | Out-Null
        $codexConfig = Join-Path $codexDir "config.toml"
        Update-ManagedTextBlock -Path $codexConfig -Block $codexToml -ServerNames @($servers | ForEach-Object { $_.ServerName })
        Write-Host "Updated Codex config: $codexConfig"
    }

    if ($Client -eq "All" -or $Client -eq "Claude") {
        $claudeMcp = Join-Path $Root ".mcp.json"
        Merge-McpJsonFile -Path $claudeMcp -NewObject $jsonObject
        Write-Host "Updated Claude project MCP config: $claudeMcp"
    }

    if ($Client -eq "All" -or $Client -eq "Gemini") {
        if ($scope -eq "project") {
            $geminiDir = Join-Path $Root ".gemini"
        } else {
            $geminiDir = Join-Path $env:USERPROFILE ".gemini"
        }
        New-Item -ItemType Directory -Force $geminiDir | Out-Null
        $geminiSettings = Join-Path $geminiDir "settings.json"
        Merge-McpJsonFile -Path $geminiSettings -NewObject $jsonObject
        Write-Host "Updated Gemini settings: $geminiSettings"
    }
}

function Invoke-Status {
    Ensure-LocalFiles | Out-Null
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $envMap = Import-DotEnvMap -Path $EnvPath

    Write-Step "Selected tool status"
    $statusRows = @()
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
        if ($item.authMode -eq "company_oauth_browser") { $status = "Needs company OAuth client or browser auth" }
        if ($item.authMode -eq "application_default_credentials" -or $item.authMode -eq "company_oauth_adc") { $status = "Needs Google ADC login if credentials missing" }
        if ($item.authMode -eq "api_header") { $status = "API header credentials present" }
        if ($item.authMode -eq "api_token") { $status = "API token credentials present" }
        if ($item.authMode -eq "service_account") { $status = "Needs approved service-account credentials" }
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

        $statusRows += [PSCustomObject]@{
            Tool = [string]$item.displayName
            Configured = "Selected"
            Authentication = $status
            Visible = "See AI client status below"
            Verified = "Pending read-only smoke test"
        }
    }
    if ($statusRows.Count -gt 0) {
        Write-Host (($statusRows | Format-Table -AutoSize | Out-String -Width 240).TrimEnd())
    } else {
        Write-Host "No enabled tools."
    }

    Write-Step "AI client status"
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        codex mcp list
    } else {
        Write-Host "Codex CLI: not found on PATH"
    }
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        claude mcp list
    } else {
        Write-Host "Claude Code: not found on PATH"
    }
    if (Get-Command gemini -ErrorAction SilentlyContinue) {
        Write-Host "Gemini CLI: found at $((Get-Command gemini).Source)"
    } else {
        Write-Host "Gemini CLI: not found on PATH"
    }
}

function Invoke-Dashboard {
    Ensure-LocalFiles | Out-Null
    $selection = Get-Content -Raw -LiteralPath $SelectionPath | ConvertFrom-Json
    $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    $envMap = Import-DotEnvMap -Path $EnvPath
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
            $status = "Company OAuth/IAM"
            $note = "Use the MCP client's remote-login flow with company Google Cloud access; confirm project, dataset, and IAM roles first."
        }
        if ($tool.Name -eq "bigQuery") {
            $status = "BigQuery auth choice"
            $note = "Official recommendation: remote MCP with company Google Cloud OAuth/IAM. Codex day-one workaround: run BigQueryAdcBearerToken to set a short-lived ADC bearer token, then restart/reload Codex and test with a dry-run read-only query."
        }
        if ($item.authMode -eq "static_oauth_client") {
            $status = "OAuth client required"
            $note = "Create an OAuth client ID/secret in Google Auth Platform and configure it in an MCP client that supports static OAuth client credentials. Codex simple login currently fails dynamic registration."
        }
        if ($item.authMode -eq "company_oauth_browser") {
            $status = "Company OAuth"
            $note = "Paste the approved company Google client ID/secret, then run GoogleOAuthFile and the browser auth command."
        }
        if ($item.authMode -eq "application_default_credentials" -or $item.authMode -eq "company_oauth_adc") {
            $status = "Google ADC"
            $note = "Prefer the approved company Google client ID/secret; run GoogleAdcLogin to create ADC by browser login."
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
            $note = "Use only with company approval; add the service-account email to the target property with the minimum role."
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
                $note = "Run GoogleOAuthFile after saving GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET, or set GOOGLE_ADC_CLIENT_JSON to an approved OAuth JSON file."
            } elseif ($tokenPath -and -not (Test-Path -LiteralPath $tokenPath)) {
                $status = "Needs browser auth"
                $note = "Run the Google Drive auth command below and sign in with your company Google account."
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
                $note = "Run GoogleOAuthFile after saving GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET, or set GOOGLE_ADC_CLIENT_JSON to an approved OAuth JSON file."
            } elseif ($tokenPath -and -not (Test-Path -LiteralPath $tokenPath)) {
                $status = "Needs browser auth"
                $note = "Run the Gmail auth command below and sign in with your company Google account."
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
                    $loginCommand = "codex mcp login $($item.serverName)"
                    $commandLines += "$($item.displayName): $loginCommand"
                }
            } elseif ($item.package) {
                $runnerName = [string]$item.runner
                if (-not $runnerName) { $runnerName = "npx" }
                $base = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Action RunMcp -ServerName $($item.serverName) -Runner $runnerName -Package $($item.package)"
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

function Invoke-ResetCodexMcp {
    if (-not $ConfirmedMcpEndpointDeletion) {
        throw "ResetCodexMcp removes MCP endpoint configuration. During MCP setup, get explicit approval first, then rerun with -ConfirmedMcpEndpointDeletion."
    }

    $codexDir = Join-Path $env:USERPROFILE ".codex"
    $codexConfig = Join-Path $codexDir "config.toml"
    if (-not (Test-Path -LiteralPath $codexConfig)) {
        Write-Host "No Codex config found at $codexConfig"
        return
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = Join-Path $codexDir "config.toml.web-analyst-backup-$stamp"
    Copy-Item -LiteralPath $codexConfig -Destination $backup

    $content = Get-Content -Raw -LiteralPath $codexConfig
    $managedPattern = "(?s)\r?\n?# BEGIN WEB_ANALYST_MCP_MANAGED.*?# END WEB_ANALYST_MCP_MANAGED\r?\n?"
    $content = [regex]::Replace($content, $managedPattern, [Environment]::NewLine)

    foreach ($serverName in Get-CatalogServerNames) {
        $escapedName = [regex]::Escape($serverName)
        $serverPattern = "(?ms)^\[mcp_servers\.$escapedName\]\r?\n.*?(?=^\[|\z)"
        $content = [regex]::Replace($content, $serverPattern, "")
    }

    $content = $content.TrimEnd()
    if ($content) {
        Set-Content -LiteralPath $codexConfig -Value ($content + [Environment]::NewLine) -Encoding UTF8
    } else {
        Set-Content -LiteralPath $codexConfig -Value "" -Encoding UTF8
    }

    Write-Host "Backed up Codex config: $backup"
    Write-Host "Removed Web Analyst MCP server configuration from: $codexConfig"
}

function Invoke-ResetKit {
    Write-Step "Resetting local kit state"
    $envMap = @{}
    if (Test-Path -LiteralPath $EnvPath) {
        $envMap = Import-DotEnvMap -Path $EnvPath
    }

    foreach ($target in @($SelectionPath, $EnvPath, (Join-Path $Root ".mcp.json"), (Join-Path $Root ".codex\config.toml"), (Join-Path $Root ".gemini\settings.json"))) {
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

    Write-Host "Kit reset complete. Templates, catalog, script, and docs were kept."
}

function Protect-LocalGoogleOAuthMcpEnvironment {
    if ($ServerName -in @("google-drive", "gmail")) {
        # Some Google MCP packages prefer GOOGLE_APPLICATION_CREDENTIALS over their
        # local browser-OAuth token. Keep GA4 ADC from leaking into Drive/Gmail.
        [Environment]::SetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", $null, "Process")
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

    Import-DotEnvMap -Path $EnvPath -IntoProcess | Out-Null

    $googleClientId = [Environment]::GetEnvironmentVariable("GOOGLE_CLIENT_ID", "Process")
    $googleClientSecret = [Environment]::GetEnvironmentVariable("GOOGLE_CLIENT_SECRET", "Process")
    $googleRefreshToken = [Environment]::GetEnvironmentVariable("GOOGLE_REFRESH_TOKEN", "Process")
    if ($googleClientId -and -not [Environment]::GetEnvironmentVariable("CLIENT_ID", "Process")) {
        [Environment]::SetEnvironmentVariable("CLIENT_ID", $googleClientId, "Process")
    }
    if ($googleClientSecret -and -not [Environment]::GetEnvironmentVariable("CLIENT_SECRET", "Process")) {
        [Environment]::SetEnvironmentVariable("CLIENT_SECRET", $googleClientSecret, "Process")
    }
    if ($googleRefreshToken) {
        if (-not [Environment]::GetEnvironmentVariable("REFRESH_TOKEN", "Process")) {
            [Environment]::SetEnvironmentVariable("REFRESH_TOKEN", $googleRefreshToken, "Process")
        }
        if (-not [Environment]::GetEnvironmentVariable("GOOGLE_REFRESH_TOKEN", "Process")) {
            [Environment]::SetEnvironmentVariable("GOOGLE_REFRESH_TOKEN", $googleRefreshToken, "Process")
        }
    }

    foreach ($pathKey in @("GDRIVE_OAUTH_PATH", "GDRIVE_CREDENTIALS_PATH", "GMAIL_OAUTH_PATH", "GMAIL_CREDENTIALS_PATH", "GOOGLE_APPLICATION_CREDENTIALS")) {
        $pathValue = [Environment]::GetEnvironmentVariable($pathKey, "Process")
        if ($pathValue) {
            $expanded = [Environment]::ExpandEnvironmentVariables($pathValue)
            [Environment]::SetEnvironmentVariable($pathKey, $expanded, "Process")
            $parent = Split-Path -Parent $expanded
            if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
        }
    }

    $driveOAuthPath = [Environment]::GetEnvironmentVariable("GDRIVE_OAUTH_PATH", "Process")
    if ($driveOAuthPath -and -not [Environment]::GetEnvironmentVariable("GOOGLE_DRIVE_OAUTH_CREDENTIALS", "Process")) {
        [Environment]::SetEnvironmentVariable("GOOGLE_DRIVE_OAUTH_CREDENTIALS", $driveOAuthPath, "Process")
    }
    $driveTokenPath = [Environment]::GetEnvironmentVariable("GDRIVE_CREDENTIALS_PATH", "Process")
    if ($driveTokenPath -and -not [Environment]::GetEnvironmentVariable("GOOGLE_DRIVE_MCP_TOKEN_PATH", "Process")) {
        [Environment]::SetEnvironmentVariable("GOOGLE_DRIVE_MCP_TOKEN_PATH", $driveTokenPath, "Process")
    }

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

switch ($Action) {
    "Prepare" {
        Ensure-LocalFiles
        Write-Host "Prepared local config files:"
        Write-Host "  $SelectionPath"
        Write-Host "  $EnvPath"
        Write-Host "Edit them through the agent conversation, then run -Action Prereqs or -Action Dashboard."
    }
    "UseProfile" {
        Invoke-UseProfile
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
    "FirstDayChecklist" {
        Invoke-FirstDayChecklist
    }
    "OnboardingReport" {
        Invoke-OnboardingReport
    }
    "ReleaseAudit" {
        Invoke-ReleaseAudit
    }
    "CatalogReview" {
        Invoke-CatalogReview
    }
    "TestFixtures" {
        Invoke-TestFixtures
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
    "ResetCodexMcp" {
        Invoke-ResetCodexMcp
    }
    "RunMcp" {
        Invoke-RunMcp
    }
    "All" {
        Ensure-LocalFiles
        Invoke-Prereqs
        Invoke-Apply
        Invoke-Dashboard
    }
}
