#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'New-CntlmConfiguration' {

    It 'writes a config file populated from the interactive answers' {
        # Sequence the Read-Host answers in prompt order.
        $script:answers = @(
            'DOMINIO',            # domain
            'userid',             # username
            'proxy.company.net',  # proxy address
            '1234',               # proxy port
            '3128',               # listen port
            'localhost'           # no proxy
        )
        $script:idx = 0
        Mock Read-Host {
            if ($AsSecureString) {
                return (ConvertTo-SecureString 'pw' -AsPlainText -Force)
            }
            $val = $script:answers[$script:idx]
            $script:idx++
            return $val
        }

        $out = Join-Path $TestDrive 'cntlm.ini'
        $result = New-CntlmConfiguration -OutputPath $out

        $result | Should -Be $out
        Test-Path $out | Should -BeTrue

        $content = Get-Content $out -Raw
        $content | Should -Match 'Username\s+userid'
        $content | Should -Match 'Domain\s+DOMINIO'
        $content | Should -Match 'Proxy\s+proxy\.company\.net:1234'
        $content | Should -Match 'Listen\s+3128'
    }

    It 'applies the default listen port when the answer is blank' {
        $script:answers2 = @('CORP','john','p.x','8080','','')
        $script:idx2 = 0
        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'pw' -AsPlainText -Force) }
            $val = $script:answers2[$script:idx2]
            $script:idx2++
            return $val
        }

        $out = Join-Path $TestDrive 'cntlm2.ini'
        New-CntlmConfiguration -OutputPath $out | Out-Null

        (Get-Content $out -Raw) | Should -Match 'Listen\s+3128'
    }
}
