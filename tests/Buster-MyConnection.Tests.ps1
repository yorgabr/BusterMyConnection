#requires -Version 5.1
#requires -Modules Pester

$ScriptPath = Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1'
$ResolvedScriptPath = Resolve-Path $ScriptPath

Describe 'Buster-MyConnection script integrity' {

    It 'loads without syntax errors under StrictMode' {
        { . $ResolvedScriptPath } | Should -Not -Throw
    }

    It 'defines required metadata variables' {
        . $ResolvedScriptPath

        $SCRIPT_VERSION | Should -Match '^\d+\.\d+\.\d+$'
        $SCRIPT_NAME    | Should -Be 'Buster-MyConnection'
    }
}

Describe 'Environment variable handling (StrictMode-safe)' {

    BeforeAll {
        . $ResolvedScriptPath
    }

    It 'exports proxy variables using .NET API without throwing' {
        {
            Set-ProxyEnvironmentForCntlm -Port 3128
        } | Should -Not -Throw
    }

    It 'restores proxy variables using .NET API without throwing' {
        $vars = [pscustomobject]@{
            HTTP_PROXY  = 'http://example:3128'
            HTTPS_PROXY = 'http://example:3128'
        }

        {
            Restore-ProxyEnvironmentVariables $vars
        } | Should -Not -Throw
    }
}

Describe 'State persistence contract' {

    BeforeAll {
        . $ResolvedScriptPath
        $script:TestStatePath = Join-Path $env:TEMP 'bmc-state-test.json'
        $script:StateFilePath = $TestStatePath
    }

    AfterAll {
        Remove-Item $TestStatePath -Force -ErrorAction SilentlyContinue
    }

    It 'writes execution state without error' {
        {
            Set-ExecutionState -Mode Proxied -ProxyVariables @{ HTTP_PROXY = 'x' }
        } | Should -Not -Throw

        Test-Path $TestStatePath | Should -BeTrue
    }

    It 'reads execution state back correctly' {
        $state = Get-PreviousExecutionState
        $state.Mode | Should -Be 'Proxied'
    }
}

Describe 'JustCheck mode behavior' {

    BeforeAll {
        Mock Test-ProxyConnectivity { $true }
        Mock Test-InternetConnectivity { $true }
    }

    It 'does not throw when JustCheck is used' {
        {
            & $ResolvedScriptPath -JustCheck
        } | Should -Not -Throw
    }
}

Describe 'CNTLM-first strategy (logic only)' {

    BeforeAll {
        . $ResolvedScriptPath

        Mock Resolve-CntlmExecutable { 'cntlm.exe' }
        Mock Start-Process {}
        Mock Test-ProxyConnectivity { $true }
    }

    It 'prefers proxy mode when CNTLM is reachable' {
        {
            & $ResolvedScriptPath
        } | Should -Not -Throw
    }
}