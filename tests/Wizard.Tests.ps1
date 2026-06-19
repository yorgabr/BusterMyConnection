#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'New-CntlmConfiguration' {

    It 'writes a config file and warns about NTLM hash generation' {
        $script:answers = @('DOMINIO','userid','proxy.company.net','1234','3128','localhost')
        $script:idx = 0
        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'pw' -AsPlainText -Force) }
            $val = $script:answers[$script:idx]; $script:idx++; return $val
        }

        $out = Join-Path $TestDrive 'cntlm.ini'
        $warnings = & {
            $script:r = New-CntlmConfiguration -OutputPath $out
        } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $script:r | Should -Be $out
        Test-Path $out | Should -BeTrue

        $content = Get-Content $out -Raw
        $content | Should -Match 'Username\s+userid'
        $content | Should -Match 'Proxy\s+proxy\.company\.net:1234'

        # The wizard must warn the user to generate a real NTLM hash.
        ($warnings -join "`n") | Should -Match 'cntlm -H -u userid -d DOMINIO'
    }

    It 'applies the default listen port and still warns about NTLM hash' {
        $script:answers2 = @('CORP','john','p.x','8080','','')
        $script:idx2 = 0
        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'pw' -AsPlainText -Force) }
            $val = $script:answers2[$script:idx2]; $script:idx2++; return $val
        }

        $out = Join-Path $TestDrive 'cntlm2.ini'
        $warnings = & {
            New-CntlmConfiguration -OutputPath $out | Out-Null
        } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        (Get-Content $out -Raw) | Should -Match 'Listen\s+3128'
        ($warnings -join "`n")  | Should -Match 'cntlm -H -u john -d CORP'
    }
}
