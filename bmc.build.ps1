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
    - Install: Deploys bmc to the current user's PowerShell scripts folder (no administrator rights),
      the same location Install-Script -Scope CurrentUser uses, and puts it on the user PATH.
    - Uninstall: Removes what Install deployed (user PATH entry, config and state are left untouched).

.PARAMETER CoverageTarget
    Minimum code coverage percentage required by the Test task.

.PARAMETER InstallPath
    Folder that receives bmc.ps1 and the bmc.cmd launcher. Defaults to the PowerShellGet
    CurrentUser scripts folder, <Documents>\WindowsPowerShell\Scripts. Documents is resolved through
    the shell folder API because it is commonly redirected (OneDrive, roaming profile, GPO).
#>

# Suppress false-positive PSScriptAnalyzer findings for Invoke-Build DSL keywords
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CoverageTarget')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InstallPath')]
param(
    [ValidateRange(0, 100)]
    [int] $CoverageTarget = 60,

    [string] $InstallPath = (Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WindowsPowerShell\Scripts')
)

# Global project path configurations relative to the build root
$BmcScript    = Join-Path -Path $BuildRoot -ChildPath 'bmc.ps1'
$BmcTests     = Join-Path -Path $BuildRoot -ChildPath 'bmc.Tests.ps1'
$BmcBuildFile = Join-Path -Path $BuildRoot -ChildPath 'bmc.build.ps1'
$Dist         = Join-Path -Path $BuildRoot -ChildPath 'dist'
$Reports      = Join-Path -Path $BuildRoot -ChildPath 'reports'
$VendorPath   = Join-Path -Path $BuildRoot -ChildPath 'vendor'

# Per-user data folder owned by bmc itself (config and state); must match $BmcAppDataPath in bmc.ps1
$BmcDataPath  = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'bmc'

<#
    Dependency resolution mechanism (vendoring):
    Imports modules prioritizing local vendored paths (.\vendor\<Name>\<Version>\)
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

<#
    Adds a directory to the *user* PATH (HKCU\Environment) and to the current process.
    Returns $true when the entry was added, $false when it was already present.

    Why the registry instead of [Environment]::SetEnvironmentVariable('Path', ..., 'User'):
    the .NET call hands back the already-expanded value and writes it as REG_SZ, which silently
    replaces entries such as %USERPROFILE%\bin with literal paths. Reading the raw value and writing
    it back as REG_EXPAND_SZ preserves them.
#>
function Add-UserPathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory
    )

    $wanted  = $Directory.TrimEnd('\')
    $key     = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    $added   = $false

    try {
        $raw     = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($raw -split ';' | Where-Object { $_ })

        $present = $false
        foreach ($entry in $entries) {
            # -eq is case-insensitive, matching how Windows compares paths
            if ([Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\') -eq $wanted) {
                $present = $true
                break
            }
        }

        if (-not $present) {
            $newValue = (@($entries) + $Directory) -join ';'
            $key.SetValue('Path', $newValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            $added = $true
        }
    }
    finally {
        $key.Close()
    }

    if ($added) {
        # Writing the registry directly does not notify running programs. Setting and clearing a
        # throwaway user variable makes .NET broadcast WM_SETTINGCHANGE so new shells see the change.
        [Environment]::SetEnvironmentVariable('BMC_PATH_REFRESH', '1', 'User')
        [Environment]::SetEnvironmentVariable('BMC_PATH_REFRESH', $null, 'User')
    }

    # Make the command available in the current session as well
    $inProcess = @($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $wanted
    if (-not $inProcess) {
        $env:Path = "$env:Path;$Directory"
    }

    return $added
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

<#
    Per-user installation following Windows PowerShell 5.1 conventions (no administrator rights):
    - bmc.ps1 goes to <Documents>\WindowsPowerShell\Scripts, the folder Install-Script
      -Scope CurrentUser uses, so `bmc` runs by name from any PowerShell session once the folder is
      on the user PATH.
    - bmc.cmd is a launcher for cmd.exe and for machines whose execution policy blocks .ps1 files.
      It resolves bmc.ps1 relative to itself, so the folder can be relocated.
    - Configuration and state stay in %LOCALAPPDATA%\bmc, owned by bmc.ps1; only the sample config
      is refreshed there. An existing bmc.config.json is never touched.
#>
task Install Build, {
    $null = New-Item -ItemType Directory -Path $InstallPath -Force
    $null = New-Item -ItemType Directory -Path $BmcDataPath -Force

    # 1. Deploy the script and verify it against the hash produced by the Build task
    $installedScript = Join-Path -Path $InstallPath -ChildPath 'bmc.ps1'
    Copy-Item -LiteralPath (Join-Path -Path $Dist -ChildPath 'bmc.ps1') -Destination $installedScript -Force

    $hashLine = Get-Content -LiteralPath (Join-Path -Path $Dist -ChildPath 'bmc.ps1.sha256') -TotalCount 1
    $expected = ($hashLine -split '\s+')[0]
    $actual   = (Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash
    assert ($actual -eq $expected) "Integrity check failed for $installedScript (expected $expected, got $actual)."

    # 2. Launcher for cmd.exe. RemoteSigned applies to this process only and still honours Group Policy.
    $launcherPath = Join-Path -Path $InstallPath -ChildPath 'bmc.cmd'
    $launcher = "@echo off`r`n" +
        "powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File `"%~dp0bmc.ps1`" %*`r`n" +
        "exit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($launcherPath, $launcher, [System.Text.Encoding]::ASCII)

    # 3. Refresh the sample config next to the user's real config
    Copy-Item -LiteralPath (Join-Path -Path $Dist -ChildPath 'bmc.config.sample.json') -Destination $BmcDataPath -Force

    # 4. Make `bmc` resolvable by name
    if (Add-UserPathEntry -Directory $InstallPath) {
        Write-Build Green "Added $InstallPath to the user PATH. Open a new terminal for other sessions to pick it up."
    } else {
        Write-Build Cyan "$InstallPath is already on the user PATH."
    }

    # 5. Post-install diagnostics
    $policy = Get-ExecutionPolicy
    if ($policy -in 'Restricted', 'AllSigned') {
        Write-Build Yellow "Effective execution policy is '$policy': 'bmc' will not run from PowerShell. Use the bmc.cmd launcher, or run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned (Group Policy may forbid it)."
    }

    $userConfig = Join-Path -Path $BmcDataPath -ChildPath 'bmc.config.json'
    if (-not (Test-Path -LiteralPath $userConfig)) {
        Write-Build Yellow "No $userConfig yet. Copy bmc.config.sample.json to bmc.config.json and set detection.officeDnsSuffixPattern."
    }

    Write-Build Green "Installed bmc (SHA-256 verified) to $InstallPath"
}

# Remove what Install deployed. The PATH entry, config and state are intentionally kept.
task Uninstall {
    remove (Join-Path -Path $InstallPath -ChildPath 'bmc.ps1'), (Join-Path -Path $InstallPath -ChildPath 'bmc.cmd')
    Write-Build Green "Removed bmc from $InstallPath"
    Write-Build Cyan "Left in place: user PATH entry, $BmcDataPath (config and state). Delete them manually if unwanted."
}

# Default target pipeline
task . Clean, Analyze, Test, Build