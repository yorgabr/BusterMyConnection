#Requires -Version 5.1

<#
.SYNOPSIS
    Invoke-Build orchestration script for bmc module development lifecycle.

.DESCRIPTION
    Executes tasks in the build pipeline:
    - Clean: Removes build artifacts (dist/, reports/).
    - Analyze: Performs AST syntax validation and PSScriptAnalyzer checks with PowerShell 5.1 compatibility.
    - Test: Runs Pester 5 test suite and validates code coverage target.
    - Build: Prepares distribution artifacts, config schema template, and SHA-256 hash.
    - Install: Deploys the application locally to %LOCALAPPDATA% with a launcher wrapper.
#>

# Suppress false-positive PSScriptAnalyzer findings for Invoke-Build DSL keywords
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CoverageTarget')]
param(
    [ValidateRange(0, 100)]
    [int] $CoverageTarget = 60
)

# Global project path configurations relative to the build root
$BmcScript    = Join-Path -Path $BuildRoot -ChildPath 'bmc.ps1'
$BmcTests     = Join-Path -Path $BuildRoot -ChildPath 'bmc.Tests.ps1'
$BmcBuildFile = Join-Path -Path $BuildRoot -ChildPath 'bmc.build.ps1'
$Dist         = Join-Path -Path $BuildRoot -ChildPath 'dist'
$Reports      = Join-Path -Path $BuildRoot -ChildPath 'reports'
$VendorPath   = Join-Path -Path $BuildRoot -ChildPath 'vendor'

<#
    Dependency resolution mechanism (vendoring):
    Imports modules prioritizing local vendored paths (.\vendor\$
    before falling back to globally installed modules meeting the minimum version requirement.
#>
function Import-VendoredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [version] $MinimumVersion
    )

    # Unload existing sessions of the target module to prevent version clashes
    Get-Module -Name $Name | Remove-Module -Force -ErrorAction SilentlyContinue

    $candidates = @()
    $moduleRoot = Join-Path -Path $VendorPath -ChildPath $Name

    if (Test-Path -LiteralPath $moduleRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $moduleRoot -Directory) {
            $parsed = $null
            if ([version]::TryParse($directory.Name, [ref]$parsed) -and $parsed -ge $MinimumVersion) {
                $candidates += [pscustomobject]@{
                    Version  = $parsed
                    Manifest = Join-Path -Path $directory.FullName -ChildPath "$Name.psd1"
                }
            }
        }
    }

    if ($candidates.Count -gt 0) {
        $best = $candidates | Sort-Object -Property Version -Descending | Select-Object -First 1
        Import-Module -Name $best.Manifest -Force -ErrorAction Stop
        return
    }

    $installed = Get-Module -ListAvailable -Name $Name |
        Where-Object { $_.Version -ge $MinimumVersion } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if (-not $installed) {
        throw "Required module '$Name' (>=$MinimumVersion) was not found in vendor or system modules."
    }

    Import-Module -Name $installed.Path -Force -ErrorAction Stop
}

# Clean build artifacts and reports
task Clean {
    remove $Dist, $Reports
}

# Static analysis and PowerShell 5.1 compatibility check
task Analyze {
    # 1. AST parser validation to intercept syntax errors before running PSScriptAnalyzer
    $filesToAnalyze = @($BmcScript, $BmcTests, $BmcBuildFile)
    foreach ($file in $filesToAnalyze) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
        assert (-not $parseErrors) ("Syntax error in {0}: {1}" -f $file, (($parseErrors | ForEach-Object -Process { $_.Message }) -join '; '))
    }

    Import-VendoredModule -Name 'PSScriptAnalyzer' -MinimumVersion '1.21.0'

    # Strict analysis rule set for core module logic
    $settings = @{
        IncludeRules = @('*')
        Severity     = @('Warning', 'Error')
        Rules        = @{
            PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
        }
    }

    # Custom rule set suppressing DSL alias warnings for the build script itself
    $buildSettings = @{
        IncludeRules = @('*')
        ExcludeRules = @('PSAvoidUsingCmdletAliases', 'PSReviewUnusedParameter')
        Severity     = @('Warning', 'Error')
        Rules        = @{
            PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
        }
    }

    $findings = @(
        Invoke-ScriptAnalyzer -Path $BmcScript -Settings $settings
        Invoke-ScriptAnalyzer -Path $BmcBuildFile -Settings $buildSettings
    )

    if ($findings.Count -gt 0) {
        Write-Build Yellow ($findings | Format-Table -Property RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String)
    }

    assert ($findings.Count -eq 0) "PSScriptAnalyzer reported $($findings.Count) finding(s)."
}

# Execute Pester 5 test suite and enforce code coverage threshold
task Test {
    Import-VendoredModule -Name 'Pester' -MinimumVersion '5.0.0'
    $null = New-Item -ItemType Directory -Path $Reports -Force

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $BmcTests
    $configuration.Run.PassThru = $true
    # 'Detailed' verbosity expands the per-test tree (Describe/Context/It), restoring the individual
    # test-case lines that 'Normal' collapses into a single per-file summary row.
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path -Path $Reports -ChildPath 'testResults.xml'
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = $BmcScript
    $configuration.CodeCoverage.OutputPath = Join-Path -Path $Reports -ChildPath 'coverage.xml'
    $configuration.CodeCoverage.CoveragePercentTarget = $CoverageTarget

    $result = Invoke-Pester -Configuration $configuration
    assert ($result.FailedCount -eq 0) "$($result.FailedCount) test(s) failed."

    $coverage = [math]::Round($result.CodeCoverage.CoveragePercent, 2)
    Write-Build Cyan "Code coverage: ${coverage}% (Target: ${CoverageTarget}%)"
    assert ($coverage -ge $CoverageTarget) "Code coverage of ${coverage}% is below the required target of ${CoverageTarget}%."
}

# Stage distribution package, JSON config schema template, and SHA-256 integrity hash
task Build {
    $null = New-Item -ItemType Directory -Path $Dist -Force
    Copy-Item -LiteralPath $BmcScript -Destination $Dist -Force

    # Dot-source the main script to load its function definitions. The -DotSourceOnly switch is
    # mandatory: it makes bmc.ps1 return right after defining functions, preventing the real
    # orchestration (Start-BmcOrchestration) from firing during the build. The line break between the
    # dot-source and the assignment is equally essential — without it, "$sample = ..." would be parsed
    # as positional arguments passed to the script, corrupting the -Port parameter.
    . $BmcScript -DotSourceOnly
    $sample = Get-BmcTemplateConfig | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path -Path $Dist -ChildPath 'bmc.config.sample.json'), $sample + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    # Compute SHA-256 checksum for deployment verification
    $hash = (Get-FileHash -LiteralPath (Join-Path -Path $Dist -ChildPath 'bmc.ps1') -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText((Join-Path -Path $Dist -ChildPath 'bmc.ps1.sha256'), "$hash  bmc.ps1`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Build Green "Staged artifacts in $Dist (SHA-256: $hash)"
}

# Deploy local package following Scoop directory structure and native shim generation
task Install Build, {
    # Resolve Scoop base directory from environment or standard user location
    $scoopDir = if ($env:SCOOP) { $env:SCOOP } else { Join-Path -Path $env:USERPROFILE -ChildPath 'scoop' }
    $appDir   = Join-Path -Path $scoopDir -ChildPath 'apps\bmc\current'
    $shimsDir = Join-Path -Path $scoopDir -ChildPath 'shims'

    # Ensure required Scoop directories exist
    $null = New-Item -ItemType Directory -Path $appDir -Force
    $null = New-Item -ItemType Directory -Path $shimsDir -Force

    # Copy distribution artifacts to current app version folder
    $distFiles = Join-Path -Path $Dist -ChildPath '*'
    Copy-Item -Path $distFiles -Destination $appDir -Force

    # Target script path inside Scoop directory structure
    $targetScript = Join-Path -Path $appDir -ChildPath 'bmc.ps1'

    # Scoop Shim Artifacts
    $scoopShimBinary = Join-Path -Path $shimsDir -ChildPath 'shim.exe'
    $bmcShimBinary   = Join-Path -Path $shimsDir -ChildPath 'bmc.exe'
    $bmcShimConfig   = Join-Path -Path $shimsDir -ChildPath 'bmc.shim'

    if (Test-Path -LiteralPath $scoopShimBinary) {
        # Standard Scoop Shim generation: copy shim.exe binary and write matching .shim configuration file
        Copy-Item -LiteralPath $scoopShimBinary -Destination $bmcShimBinary -Force

        # Define path to binary/script and optional arguments for the shim executor
        $shimContent = "path = `"$targetScript`"`r`nargs = `"`""
        [System.IO.File]::WriteAllText($bmcShimConfig, $shimContent, [System.Text.Encoding]::UTF8)

        Write-Build Green "Scoop shim successfully created: $bmcShimBinary -> $targetScript"
    } else {
        # Fallback script shim generation when Scoop is not installed in the environment
        $cmdShim = Join-Path -Path $shimsDir -ChildPath 'bmc.cmd'
        $launcher = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$targetScript`" %*`r`n"
        [System.IO.File]::WriteAllText($cmdShim, $launcher, [System.Text.Encoding]::ASCII)

        Write-Build Yellow "Scoop base installation not found. Created fallback script shim at $cmdShim"
    }

    Write-Build Green "Successfully deployed bmc to Scoop app directory: $appDir"
}

# Default target pipeline
task . Clean, Analyze, Test, Build