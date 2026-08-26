#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Execution state persistence' {

    BeforeEach {
        # Redirect the module-level state path into the test sandbox.
        Set-Variable -Name StateFilePath -Scope Script -Value (Join-Path $TestDrive 'state.json')
    }

    It 'persists and restores DirectAccess state' {
        Set-ExecutionState -Mode DirectAccess -ProxyVariables @{ HTTP_PROXY = 'x' }

        $s = Get-PreviousExecutionState
        $s.Mode                     | Should -Be 'DirectAccess'
        $s.ProxyVariables.HTTP_PROXY | Should -Be 'x'
    }

    It 'records the script version into the state' {
        Set-ExecutionState -Mode Proxied
        (Get-PreviousExecutionState).Version | Should -Be $SCRIPT_VERSION
    }

    It 'returns null and warns when the state file is invalid JSON' {
        Set-Content $StateFilePath '{invalid json'

        $result = $null
        $warnings = & {
            $script:r = Get-PreviousExecutionState
        } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $result = $script:r

        $result   | Should -BeNullOrEmpty
        $warnings | Should -Not -BeNullOrEmpty
        ($warnings -join "`n") | Should -Match 'Failed to read previous execution state'
    }

    It 'returns null when no state file exists' {
        Remove-Item $StateFilePath -ErrorAction SilentlyContinue
        Get-PreviousExecutionState | Should -BeNullOrEmpty
    }
}
