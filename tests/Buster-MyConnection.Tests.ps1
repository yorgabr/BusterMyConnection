# tests/Buster-MyConnection.Tests.ps1
#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
}

Describe 'Script integrity' {

    It 'dot-sources without throwing under StrictMode' {
        { . $script:ScriptPath -DotSourceOnly } | Should -Not -Throw
    }

    It 'defines required metadata variables' {
        . $script:ScriptPath -DotSourceOnly
        $SCRIPT_VERSION | Should -Not -BeNullOrEmpty
        $SCRIPT_NAME    | Should -Be 'Buster-MyConnection'
        $SCRIPT_VERSION | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'reports version 2.8.1' {
        . $script:ScriptPath -DotSourceOnly
        $SCRIPT_VERSION | Should -Be '2.8.1'
    }
}

Describe 'ConvertTo-ProxyUserInfo (regression: domain must not leak into URL)' {

    BeforeAll {
        . $script:ScriptPath -DotSourceOnly
    }

    It 'strips DOMAIN\user form and keeps only the bare user' {
        ConvertTo-ProxyUserInfo -Username 'CORP\jdoe' -Password 'p@ss' | Should -Be 'jdoe:p%40ss@'
    }

    It 'strips user@DOMAIN (UPN) form' {
        ConvertTo-ProxyUserInfo -Username 'jdoe@corp.local' -Password 'pw' | Should -Be 'jdoe:pw@'
    }

    It 'url-encodes reserved characters in password' {
        ConvertTo-ProxyUserInfo -Username 'jdoe' -Password 'p@ss:w/rd' | Should -Be 'jdoe:p%40ss%3Aw%2Frd@'
    }

    It 'url-encodes reserved characters in username' {
        ConvertTo-ProxyUserInfo -Username 'jo hn' -Password 'pw' | Should -Be 'jo%20hn:pw@'
    }

    It 'returns empty string when username is empty' {
        ConvertTo-ProxyUserInfo -Username '' -Password 'pw' | Should -Be ''
    }

    It 'omits the colon when password is empty' {
        ConvertTo-ProxyUserInfo -Username 'jdoe' -Password '' | Should -Be 'jdoe@'
    }
}

Describe 'Set-ProxyEnvironmentForCorporate (regression: no backslash in HTTP_PROXY)' {

    BeforeAll {
        . $script:ScriptPath -DotSourceOnly
    }

    AfterEach {
        Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY, Env:NO_PROXY -ErrorAction SilentlyContinue
    }

    It 'builds a proxy URL without DOMAIN\ prefix' {
        $cred = [PSCredential]::new('CORP\jdoe', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))
        Set-ProxyEnvironmentForCorporate -ProxyAddress 'proxy.company.net' -ProxyPort 1234 -Credential $cred -NoProxy 'localhost'

        $env:HTTP_PROXY | Should -Be 'http://jdoe:p%40ss@proxy.company.net:1234'
        $env:HTTP_PROXY | Should -Not -Match '\\'
    }

    It 'omits userinfo entirely when no credential is supplied' {
        Set-ProxyEnvironmentForCorporate -ProxyAddress 'proxy.company.net' -ProxyPort 1234 -NoProxy 'localhost'
        $env:HTTP_PROXY | Should -Be 'http://proxy.company.net:1234'
    }
}