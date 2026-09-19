# tests/EnvProxy.Tests.ps1
#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    # -DotSourceOnly skips the real auto-detection flow; -Quiet silences
    # the Out-Info/Out-Success/Out-Warn/Out-Error helpers so the tests
    # below (which don't assert on message text) don't spam the console.
    . $script:ScriptPath -DotSourceOnly -Quiet
}

Describe 'Proxy environment variable lifecycle' {

    AfterEach {
        foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','PROXY_FOO','PIP_INDEX_URL','UV_INDEX_URL','UV_DEFAULT_INDEX','UV_NO_PIP_CONFIG') {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }

    It 'backs up only proxy and python package index related variables' {
        [System.Environment]::SetEnvironmentVariable('HTTP_PROXY','x','Process')
        [System.Environment]::SetEnvironmentVariable('UV_INDEX_URL','http://nexus.corp/simple','Process')

        $b = Backup-ProxyEnvironmentVariables

        $b.Keys | Should -Contain 'HTTP_PROXY'
        $b.Keys | Should -Contain 'UV_INDEX_URL'
        $b.Keys | Should -Not -Contain 'PATH'
    }

    It 'backs up, removes pip and uv index variables, and injects direct access overrides' {
        [System.Environment]::SetEnvironmentVariable('PIP_INDEX_URL','https://nexus.corp/simple','Process')
        [System.Environment]::SetEnvironmentVariable('UV_INDEX_URL','https://nexus.corp/simple','Process')

        $r = Remove-ProxyEnvironmentVariables

        $env:PIP_INDEX_URL     | Should -BeNullOrEmpty
        $env:UV_INDEX_URL      | Should -BeNullOrEmpty
        $env:UV_DEFAULT_INDEX  | Should -Be 'https://pypi.org/simple'
        $env:UV_NO_PIP_CONFIG  | Should -Be '1'
        $r.Backup.Keys         | Should -Contain 'PIP_INDEX_URL'
        $r.Backup.Keys         | Should -Contain 'UV_INDEX_URL'
    }

    It 'restores non-null values only and removes UV direct access flags (hashtable input)' {
        [System.Environment]::SetEnvironmentVariable('UV_NO_PIP_CONFIG', '1', 'Process')
        [System.Environment]::SetEnvironmentVariable('UV_DEFAULT_INDEX', 'https://pypi.org/simple', 'Process')

        Restore-ProxyEnvironmentVariables -Variables @{
            HTTP_PROXY    = 'ok'
            HTTPS_PROXY   = $null
            PIP_INDEX_URL = 'https://nexus.corp/simple'
        }

        $env:HTTP_PROXY        | Should -Be 'ok'
        $env:HTTPS_PROXY       | Should -BeNullOrEmpty
        $env:PIP_INDEX_URL     | Should -Be 'https://nexus.corp/simple'
        $env:UV_NO_PIP_CONFIG  | Should -BeNullOrEmpty
        $env:UV_DEFAULT_INDEX  | Should -BeNullOrEmpty
    }

    It 'restores from a PSCustomObject and removes direct flags (JSON round-trip shape)' {
        [System.Environment]::SetEnvironmentVariable('UV_NO_PIP_CONFIG', '1', 'Process')

        $obj = [pscustomobject]@{ HTTP_PROXY = 'fromjson'; HTTPS_PROXY = $null; UV_INDEX_URL = 'https://nexus.corp/simple' }
        Restore-ProxyEnvironmentVariables -Variables $obj

        $env:HTTP_PROXY        | Should -Be 'fromjson'
        $env:UV_INDEX_URL      | Should -Be 'https://nexus.corp/simple'
        $env:UV_NO_PIP_CONFIG  | Should -BeNullOrEmpty
    }
}

Describe 'Set-ProxyEnvironmentForCntlm' {

    AfterEach {
        foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','UV_NO_PIP_CONFIG') {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }

    It 'points all proxy variables at the local CNTLM listener and cleans UV direct flags' {
        [System.Environment]::SetEnvironmentVariable('UV_NO_PIP_CONFIG', '1', 'Process')

        Set-ProxyEnvironmentForCntlm -Port 3128 -NoProxy 'localhost,127.0.0.1'

        $env:HTTP_PROXY        | Should -Be 'http://127.0.0.1:3128'
        $env:HTTPS_PROXY       | Should -Be 'http://127.0.0.1:3128'
        $env:ALL_PROXY         | Should -Be 'http://127.0.0.1:3128'
        $env:NO_PROXY          | Should -Be 'localhost,127.0.0.1'
        $env:UV_NO_PIP_CONFIG  | Should -BeNullOrEmpty
    }
}