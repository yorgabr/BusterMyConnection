#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    # Load function definitions only; never trigger the main flow.
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Script integrity' {

    It 'dot-sources without throwing under StrictMode' {
        { . $script:ScriptPath -DotSourceOnly } | Should -Not -Throw
    }

    It 'defines required metadata variables' {
        $SCRIPT_VERSION | Should -Match '^\d+\.\d+\.\d+$'
        $SCRIPT_NAME    | Should -Be 'Buster-MyConnection'
    }

    It 'reports version 2.8.0' {
        $SCRIPT_VERSION | Should -Be '2.8.0'
    }
}

Describe 'ConvertTo-ProxyUserInfo (regression: domain must not leak into URL)' {

    It 'strips DOMAIN\user form and keeps only the bare user' {
        $info = ConvertTo-ProxyUserInfo -Username 'DOMINIO\userid' -Password 'pw'
        $info | Should -Be 'userid:pw@'
    }

    It 'strips user@DOMAIN (UPN) form' {
        $info = ConvertTo-ProxyUserInfo -Username 'userid@DOMINIO' -Password 'pw'
        $info | Should -Be 'userid:pw@'
    }

    It 'url-encodes reserved characters in password' {
        $info = ConvertTo-ProxyUserInfo -Username 'userid' -Password 'p@ss:w/rd'
        $info | Should -Be 'userid:p%40ss%3Aw%2Frd@'
    }

    It 'url-encodes reserved characters in username' {
        $info = ConvertTo-ProxyUserInfo -Username 'DOMINIO\jo@o' -Password 'x'
        $info | Should -Be 'jo%40o:x@'
    }

    It 'returns empty string when username is empty' {
        ConvertTo-ProxyUserInfo -Username '' -Password 'x' | Should -Be ''
    }

    It 'omits the colon when password is empty' {
        ConvertTo-ProxyUserInfo -Username 'userid' -Password '' | Should -Be 'userid@'
    }
}

Describe 'Set-ProxyEnvironmentForCorporate (regression: no backslash in HTTP_PROXY)' {

    AfterEach {
        foreach ($v in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
            [System.Environment]::SetEnvironmentVariable($v, $null, 'Process')
        }
    }

    It 'builds a proxy URL without DOMAIN\ prefix' {
        $sec  = ConvertTo-SecureString 'hiddenpwd' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential('DOMINIO\userid', $sec)

        Set-ProxyEnvironmentForCorporate -ProxyAddress 'proxy.company.net' -ProxyPort 1234 -Credential $cred -NoProxy 'localhost'

        $env:HTTP_PROXY | Should -Be 'http://userid:hiddenpwd@proxy.company.net:1234'
        $env:HTTP_PROXY | Should -Not -Match '\\'
    }

    It 'omits userinfo entirely when no credential is supplied' {
        Set-ProxyEnvironmentForCorporate -ProxyAddress 'proxy.company.net' -ProxyPort 1234 -NoProxy 'localhost'
        $env:HTTP_PROXY | Should -Be 'http://proxy.company.net:1234'
    }
}