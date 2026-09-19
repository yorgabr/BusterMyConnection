<#
.SYNOPSIS
    Build and test automation script for BusterMyConnection.
#>

task Clean {
    Write-Host "Cleaning build artifacts..."
    $artifactPath = "$PSScriptRoot\out"
    if (Test-Path $artifactPath) {
        Remove-Item -Path $artifactPath -Recurse -Force
    }
}

task Build Clean, {
    Write-Host "Preparing distribution files..."
    $outDir = "$PSScriptRoot\out\bustermyconnection"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Copy-Item -Path "$PSScriptRoot\src\bustermyconnection\*" -Destination $outDir -Recurse -Force
}

task Test Build, {
    Write-Host "Running Pester tests..."

    Import-Module Pester -ErrorAction SilentlyContinue

    $pesterConfig = [PesterConfiguration]::Default
    $pesterConfig.Output.Verbosity = 'Detailed'
    $pesterConfig.Run.Exit = $false

    $pesterConfig.CodeCoverage.Enabled = $true
    $pesterConfig.CodeCoverage.Path = "$PSScriptRoot\src\bustermyconnection\Buster-MyConnection.ps1"

    # Keeps warning stream available for test assertions while allowing test execution rendering
    $result = Invoke-Pester -Configuration $pesterConfig

    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) test(s) failed."
    }
}

task . Test