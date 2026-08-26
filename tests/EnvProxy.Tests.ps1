#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Proxy environment variable lifecycle' {

    AfterEach {
        foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','PROXY_FOO') {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }

    It 'backs up only proxy-related variables' {
        [System.Environment]::SetEnvironmentVariable('HTTP_PROXY','x','Process')

        $b = Backup-ProxyEnvironmentVariables

        $b.Keys | Should -Contain 'HTTP_PROXY'
        $b.Keys | Should -Not -Contain 'PATH'
    }

    It 'removes only proxy-related variables and returns a backup with count' {
        [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY','x','Process')

        $r = Remove-ProxyEnvironmentVariables

        $env:HTTPS_PROXY    | Should -BeNullOrEmpty
        $r.Backup.Keys      | Should -Contain 'HTTPS_PROXY'
        $r.Count            | Should -BeGreaterOrEqual 1
    }

    It 'restores non-null values only (hashtable input)' {
        Restore-ProxyEnvironmentVariables -Variables @{
            HTTP_PROXY  = 'ok'
            HTTPS_PROXY = $null
        }

        $env:HTTP_PROXY  | Should -Be 'ok'
        $env:HTTPS_PROXY | Should -BeNullOrEmpty
    }

    It 'restores from a PSCustomObject (JSON round-trip shape)' {
        $obj = [pscustomobject]@{ HTTP_PROXY = 'fromjson'; HTTPS_PROXY = $null }
        Restore-ProxyEnvironmentVariables -Variables $obj
        $env:HTTP_PROXY | Should -Be 'fromjson'
    }
}

Describe 'Set-ProxyEnvironmentForCntlm' {

    AfterEach {
        foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }

    It 'points all proxy variables at the local CNTLM listener' {
        Set-ProxyEnvironmentForCntlm -Port 3128 -NoProxy 'localhost,127.0.0.1'

        $env:HTTP_PROXY  | Should -Be 'http://127.0.0.1:3128'
        $env:HTTPS_PROXY | Should -Be 'http://127.0.0.1:3128'
        $env:ALL_PROXY   | Should -Be 'http://127.0.0.1:3128'
        $env:NO_PROXY    | Should -Be 'localhost,127.0.0.1'
    }
}

Describe 'Proxy environment variable lifecycle' {

    AfterEach {
        foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','PROXY_FOO','PIP_INDEX_URL','UV_INDEX_URL') {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }

    It 'backs up only proxy-related variables' {
        [System.Environment]::SetEnvironmentVariable('HTTP_PROXY','x','Process')

        $b = Backup-ProxyEnvironmentVariables

        $b.Keys | Should -Contain 'HTTP_PROXY'
        $b.Keys | Should -Not -Contain 'PATH'
    }

    It 'backs up and removes pip and uv index variables' {
        [System.Environment]::SetEnvironmentVariable('PIP_INDEX_URL','https://nexus.corp/simple','Process')
        [System.Environment]::SetEnvironmentVariable('UV_INDEX_URL','https://nexus.corp/simple','Process')

        $r = Remove-ProxyEnvironmentVariables

        $env:PIP_INDEX_URL | Should -BeNullOrEmpty
        $env:UV_INDEX_URL  | Should -BeNullOrEmpty
        $r.Backup.Keys     | Should -Contain 'PIP_INDEX_URL'
        $r.Backup.Keys     | Should -Contain 'UV_INDEX_URL'
    }

    It 'removes only proxy-related variables and returns a backup with count' {
        [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY','x','Process')

        $r = Remove-ProxyEnvironmentVariables

        $env:HTTPS_PROXY    | Should -BeNullOrEmpty
        $r.Backup.Keys      | Should -Contain 'HTTPS_PROXY'
        $r.Count            | Should -BeGreaterOrEqual 1
    }

    It 'restores non-null values only (hashtable input)' {
        Restore-ProxyEnvironmentVariables -Variables @{
            HTTP_PROXY    = 'ok'
            HTTPS_PROXY   = $null
            PIP_INDEX_URL = 'https://nexus.corp/simple'
        }

        $env:HTTP_PROXY    | Should -Be 'ok'
        $env:HTTPS_PROXY   | Should -BeNullOrEmpty
        $env:PIP_INDEX_URL | Should -Be 'https://nexus.corp/simple'
    }

    It 'restores from a PSCustomObject (JSON round-trip shape)' {
        $obj = [pscustomobject]@{ HTTP_PROXY = 'fromjson'; HTTPS_PROXY = $null; UV_INDEX_URL = 'https://nexus.corp/simple' }
        Restore-ProxyEnvironmentVariables -Variables $obj
        $env:HTTP_PROXY   | Should -Be 'fromjson'
        $env:UV_INDEX_URL | Should -Be 'https://nexus.corp/simple'
    }
}
