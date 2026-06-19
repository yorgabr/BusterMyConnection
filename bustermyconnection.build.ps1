#requires -Version 5.1

Import-Module InvokeBuild -ErrorAction Stop

task Default Test

task Clean {
    Write-Host "Cleaning artifacts..."
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
        ./coverage, ./artifacts
}

task Lint {
    Write-Host "Running PSScriptAnalyzer..."
    Import-Module PSScriptAnalyzer -ErrorAction Stop

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
    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

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
