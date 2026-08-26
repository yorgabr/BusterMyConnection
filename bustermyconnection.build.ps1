#requires -Version 5.1

Import-Module InvokeBuild -ErrorAction Stop

$script:RequiredPesterVersion = [version]'6.0.0'
$script:RequiredPSScriptAnalyzerVersion = [version]'1.24.0'

function Install-RequiredModule {
    <#
        Ensures a module of at least $MinimumVersion is available, installing it
        into the current user's scope (no admin rights needed) when the highest
        locally installed version is missing or too old. Side-by-side installs
        via Install-Module never remove older versions, so this is safe to run
        even when other projects on the machine still depend on an older line.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$MinimumVersion
    )

    $installed = Get-Module -Name $Name -ListAvailable |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($installed -and $installed.Version -ge $MinimumVersion) {
        return
    }

    $foundText = if ($installed) { $installed.Version } else { '(none installed)' }
    Write-Host "$Name $MinimumVersion or newer is required (found: $foundText). Installing from PSGallery..."

    try {
        Install-Module -Name $Name -MinimumVersion $MinimumVersion -Force -Scope CurrentUser -SkipPublisherCheck -ErrorAction Stop
    } catch {
        throw "Failed to install $Name >= $MinimumVersion automatically: $($_.Exception.Message). " +
              "Install it manually with: Install-Module $Name -MinimumVersion $MinimumVersion -Scope CurrentUser -SkipPublisherCheck"
    }
}

task Default Test

task Clean {
    Write-Host "Cleaning artifacts..."
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
        ./coverage, ./artifacts
}

task Lint {
    Write-Host "Running PSScriptAnalyzer..."
    Install-RequiredModule -Name PSScriptAnalyzer -MinimumVersion $script:RequiredPSScriptAnalyzerVersion
    Import-Module PSScriptAnalyzer -MinimumVersion $script:RequiredPSScriptAnalyzerVersion -ErrorAction Stop

    $issues = Invoke-ScriptAnalyzer `
        -Path ./src `
        -Recurse `
        -Severity Error `
        -ExcludeRule PSUseApprovedVerbs

    if ($issues) {
        $issues | Format-Table -AutoSize | Out-String | Write-Host
        throw "PSScriptAnalyzer found $($issues.Count) error-level issue(s)."
    }
}

task Test {
    Write-Host "Running Pester tests..."
    Install-RequiredModule -Name Pester -MinimumVersion $script:RequiredPesterVersion
    Import-Module Pester -MinimumVersion $script:RequiredPesterVersion -ErrorAction Stop -Verbose

    $config = New-PesterConfiguration
    $config.Run.Path                           = './tests'
    $config.Run.Exit                           = $true
    $config.CodeCoverage.Enabled               = $true
    $config.CodeCoverage.Path                  = './src/bustermyconnection/Buster-MyConnection.ps1'
    $config.CodeCoverage.OutputPath            = './coverage/coverage.xml'
    $config.CodeCoverage.OutputFormat          = 'JaCoCo'
    # NOTE: this single-file script bundles its entrypoint (MAIN FLOW / JustCheck)
    # with its function library, so coverage is structurally capped. Extracting the
    # functions into a .psm1 module is the right path to 80%+ and is tracked as tech debt.
    $config.CodeCoverage.CoveragePercentTarget = 60
    $config.Output.Verbosity                   = 'Detailed'

    Invoke-Pester -Configuration $config
}

task Full Clean, Lint, Test