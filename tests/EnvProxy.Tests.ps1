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
