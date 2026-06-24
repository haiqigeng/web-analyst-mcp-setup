function Invoke-PesterTests {
    $testPath = Join-Path $Root "tests\WebAnalystSetup.Tests.ps1"
    if (-not (Test-Path -LiteralPath $testPath)) {
        throw "Missing Pester test file: $testPath"
    }

    $pesterModule = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pesterModule -or $pesterModule.Version.Major -lt 5) {
        Write-Step "Installing Pester"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
            if (-not $nuget -or $nuget.Version -lt [Version]"2.8.5.201") {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
            }
            $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($psGallery -and $psGallery.InstallationPolicy -ne "Trusted") {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            }
            Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0 -ErrorAction Stop
        } catch {
            throw "Pester 5+ is required for this test action. Install it with: Install-PackageProvider NuGet -Scope CurrentUser -Force; Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck. Original error: $($_.Exception.Message)"
        }
    }

    Import-Module Pester -MinimumVersion 5.0 -Force
    Write-Step "Running Pester tests"

    if (Get-Command New-PesterConfiguration -ErrorAction SilentlyContinue) {
        $config = New-PesterConfiguration
        $config.Run.Path = $testPath
        $config.Run.PassThru = $true
        $config.Output.Verbosity = "Detailed"
        $result = Invoke-Pester -Configuration $config
    } else {
        $result = Invoke-Pester -Path $testPath -PassThru
    }

    if ($result.FailedCount -gt 0) {
        throw "Pester tests failed with $($result.FailedCount) failure(s)."
    }
}
