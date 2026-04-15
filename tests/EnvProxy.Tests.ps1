# tests/EnvProxy.Tests.ps1
# Requires -Module Pester

$scriptPath = Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1'
. $scriptPath

Describe 'Proxy environment variable lifecycle' {

    BeforeAll {
        $originalEnv = @{}
        Get-ChildItem Env: | ForEach-Object {
            $originalEnv[$_.Key] = $_.Value
        }
    }

    AfterAll {
        Get-ChildItem Env: | ForEach-Object {
            Remove-Item "Env:\$($_.Key)" -ErrorAction SilentlyContinue
        }
        foreach ($k in $originalEnv.Keys) {
            :SetEnvironmentVariable($k, $originalEnv[$k], 'Process')
        }
    }

    It 'backs up only proxy-related variables' {
        :SetEnvironmentVariable('HTTP_PROXY','x','Process')
        :SetEnvironmentVariable('PATH','y','Process')

        $b = Backup-ProxyEnvironmentVariables

        $b.Keys | Should -Contain 'HTTP_PROXY'
        $b.Keys | Should -Not -Contain 'PATH'
    }

    It 'removes only proxy-related variables and returns backup' {
        :SetEnvironmentVariable('HTTPS_PROXY','x','Process')

        $r = Remove-ProxyEnvironmentVariables

        $env:HTTPS_PROXY | Should -BeNullOrEmpty
        $r.Backup.Keys | Should -Contain 'HTTPS_PROXY'
        $r.Count | Should -Be 1
    }

    It 'restores non-null values only' {
        Restore-ProxyEnvironmentVariables -Variables @{
            HTTP_PROXY = 'ok'
            HTTPS_PROXY = $null
        } | Out-Null

        $env:HTTP_PROXY | Should -Be 'ok'
        $env:HTTPS_PROXY | Should -BeNullOrEmpty
    }
}