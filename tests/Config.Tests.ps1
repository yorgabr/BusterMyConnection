#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Get-CntlmConfiguration' {

    It 'parses a well-formed cntlm.ini' {
        $ini = Join-Path $TestDrive 'cntlm.ini'
        @'
Username    userid
Domain      DOMINIO
Proxy       proxy.company.net:1234
Listen      3128
NoProxy     localhost, 127.0.0.1, *.company.net
'@ | Set-Content $ini

        $cfg = Get-CntlmConfiguration -IniPath $ini

        $cfg.Username  | Should -Be 'userid'
        $cfg.Domain    | Should -Be 'DOMINIO'
        $cfg.Proxy     | Should -Be 'proxy.company.net'
        $cfg.ProxyPort | Should -Be 1234
        $cfg.Listen    | Should -Be 3128
        $cfg.NoProxy   | Should -Be 'localhost,127.0.0.1,*.company.net'
    }

    It 'parses Listen with ip:port form' {
        $ini = Join-Path $TestDrive 'cntlm2.ini'
        @'
Proxy   p.x:8080
Listen  127.0.0.1:3129
'@ | Set-Content $ini

        (Get-CntlmConfiguration -IniPath $ini).Listen | Should -Be 3129
    }

    It 'throws when Proxy directive is missing' {
        $ini = Join-Path $TestDrive 'bad.ini'
        'Listen 3128' | Set-Content $ini
        { Get-CntlmConfiguration -IniPath $ini } | Should -Throw
    }

    It 'throws when the file does not exist' {
        { Get-CntlmConfiguration -IniPath (Join-Path $TestDrive 'nope.ini') } | Should -Throw
    }
}
