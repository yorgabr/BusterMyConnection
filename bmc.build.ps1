#Requires -Version 5.1
<#
.SYNOPSIS
    Invoke-Build script orchestrating the bmc development cycle (Windows PowerShell 5.1).

.DESCRIPTION
    Tasks:
      Clean    - removes dist/ and reports/.
      Analyze  - parser check, PSScriptAnalyzer (including 5.1 syntax compatibility) on bmc.ps1 and this file.
      Test     - Pester 5 run with code coverage of bmc.ps1; fails below -CoverageTarget percent.
      Build    - stages dist/ (script, sample configuration, SHA-256 file).
      Install  - copies dist/ to %LOCALAPPDATA%\Programs\bmc and writes a bmc.cmd launcher (no admin, PATH untouched).
      .        - default: Clean, Analyze, Test, Build.

    Dependencies are vendored: modules are looked up first in .\vendor\<Name>\<Version>\ (the layout produced by
    Save-Module -Path .\vendor) and only then in the regular module path. Nothing is downloaded by this script.

.EXAMPLE
    Invoke-Build            # full cycle
    Invoke-Build Test       # tests and coverage only
    Invoke-Build Test -CoverageTarget 80
#>
param(
    [ValidateRange(0, 100)]
    [int] $CoverageTarget = 60
)

$BmcScript = Join-Path $BuildRoot 'bmc.ps1'
$BmcTests = Join-Path $BuildRoot 'bmc.Tests.ps1'
$BmcBuildFile = Join-Path $BuildRoot 'bmc.build.ps1'
$Dist = Join-Path $BuildRoot 'dist'
$Reports = Join-Path $BuildRoot 'reports'
$VendorPath = Join-Path $BuildRoot 'vendor'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\bmc'

function Import-VendoredModule {
    <# Prefers the newest vendored copy; falls back to an installed module of at least MinimumVersion. #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][version] $MinimumVersion
    )

    $candidates = @()
    $moduleRoot = Join-Path $VendorPath $Name
    if (Test-Path -LiteralPath $moduleRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $moduleRoot -Directory) {
            $parsed = $null
            if ([version]::TryParse($directory.Name, [ref]$parsed) -and $parsed -ge $MinimumVersion) {
                $candidates += [pscustomobject]@{ Version = $parsed; Manifest = Join-Path $directory.FullName "$Name.psd1" }
            }
        }
    }

    if ($candidates.Count -gt 0) {
        $best = $candidates | Sort-Object Version -Descending | Select-Object -First 1
        Import-Module -Name $best.Manifest -Force -ErrorAction Stop
        return
    }

    $installed = Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed) {
        throw "$Name >= $MinimumVersion not found. Vendor it with: Save-Module -Name $Name -Path '$VendorPath'"
    }
    Import-Module -Name $installed.Path -Force -ErrorAction Stop
}

task Clean {
    remove $Dist, $Reports
}

task Analyze {
    # 1. Hard syntax gate: the parser of the host running the build (Windows PowerShell 5.1 for the real target).
    foreach ($file in $BmcScript, $BmcTests, $BmcBuildFile) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
        assert (-not $parseErrors) ("Syntax errors in {0}: {1}" -f $file, (($parseErrors | ForEach-Object Message) -join '; '))
    }

    # 2. Static analysis, including a check that nothing newer than 5.1 syntax slipped in.
    Import-VendoredModule -Name 'PSScriptAnalyzer' -MinimumVersion '1.21.0'
    $settings = @{
        IncludeRules = @('*')
        Severity     = @('Warning', 'Error')
        Rules        = @{
            PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
        }
    }
    $findings = @(
        Invoke-ScriptAnalyzer -Path $BmcScript -Settings $settings
        Invoke-ScriptAnalyzer -Path $BmcBuildFile -Settings $settings
    )
    if ($findings.Count -gt 0) { Write-Build Yellow ($findings | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String) }
    assert ($findings.Count -eq 0) "PSScriptAnalyzer reported $($findings.Count) finding(s)."
}

task Test {
    Import-VendoredModule -Name 'Pester' -MinimumVersion '5.0.0'
    $null = New-Item -ItemType Directory -Path $Reports -Force

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $BmcTests
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path $Reports 'testResults.xml'
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = $BmcScript
    $configuration.CodeCoverage.OutputPath = Join-Path $Reports 'coverage.xml'
    $configuration.CodeCoverage.CoveragePercentTarget = $CoverageTarget

    $result = Invoke-Pester -Configuration $configuration
    assert ($result.FailedCount -eq 0) "$($result.FailedCount) test(s) failed."

    $coverage = [math]::Round($result.CodeCoverage.CoveragePercent, 2)
    Write-Build Cyan "Coverage: $coverage % (target $CoverageTarget %)"
    assert ($coverage -ge $CoverageTarget) "Coverage $coverage % is below the $CoverageTarget % target."
}

task Build {
    $null = New-Item -ItemType Directory -Path $Dist -Force
    Copy-Item -LiteralPath $BmcScript -Destination $Dist -Force

    # The sample configuration is produced by the script itself so that it can never drift from the schema.
    . $BmcScript
    $sample = Get-BmcTemplateConfig | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $Dist 'bmc.config.sample.json'), $sample + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    $hash = (Get-FileHash -LiteralPath (Join-Path $Dist 'bmc.ps1') -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText((Join-Path $Dist 'bmc.ps1.sha256'), "$hash  bmc.ps1`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Build Green "Staged $Dist (SHA-256 $hash)"
}

task Install Build, {
    $null = New-Item -ItemType Directory -Path $InstallDir -Force
    Copy-Item -Path (Join-Path $Dist '*') -Destination $InstallDir -Force

    # A .cmd launcher makes 'bmc' work from cmd.exe and PowerShell alike without touching the execution policy
    # machine-wide; Bypass applies to this one process only.
    $launcher = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0bmc.ps1`" %*`r`n"
    [System.IO.File]::WriteAllText((Join-Path $InstallDir 'bmc.cmd'), $launcher, [System.Text.Encoding]::ASCII)
    Write-Build Green "Installed to $InstallDir. Add it to your user PATH to call 'bmc' from anywhere."
}

task . Clean, Analyze, Test, Build
