# tests/State.Tests.ps1

$scriptPath = Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1'
. $scriptPath

Describe 'Execution state persistence' {

    BeforeAll {
        $script:StateFilePath = Join-Path $TestDrive 'state.json'
    }

    It 'persists and restores DirectAccess state' {
        Set-ExecutionState -Mode DirectAccess -ProxyVariables @{
            HTTP_PROXY = 'x'
        }

        $s = Get-PreviousExecutionState

        $s.Mode | Should -Be 'DirectAccess'
        $s.ProxyVariables.HTTP_PROXY | Should -Be 'x'
    }

    It 'returns null if state file is invalid' {
        Set-Content $StateFilePath '{invalid json'

        $s = Get-PreviousExecutionState
        $s | Should -BeNullOrEmpty
    }
}