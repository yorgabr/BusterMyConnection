#requires -Version 5.1

param(
    [string]$Task = 'Default'
)

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

    Invoke-ScriptAnalyzer `
        -Path ./src `
        -Recurse `
        -Severity Error `
        -ExcludeRule PSUseApprovedVerbs
}

task Test {
    Write-Host "Running Pester tests..."
    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

    Invoke-Pester `
        -Path ./tests `
        -CI `
        -CodeCoverage ./src/bustermyconnection/Buster-MyConnection.ps1 `
        -CodeCoverageOutputFile ./coverage/coverage.xml `
        -CodeCoverageOutputFormat JaCoCo
}

task Full Clean, Lint, Test