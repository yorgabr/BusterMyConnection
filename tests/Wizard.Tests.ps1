# tests/Wizard.Tests.ps1
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

    It 'stores the NTLM hash instead of the plaintext password when a working cntlm.exe is supplied' {
        $script:answers3 = @('DOMINIO','userid','proxy.company.net','1234','3128','localhost')
        $script:idx3 = 0
        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'S3cr3t!' -AsPlainText -Force) }
            $val = $script:answers3[$script:idx3]; $script:idx3++; return $val
        }
        # Pester 6 no longer falls through to the real cmdlet when a filtered mock
        # doesn't match; New-CntlmConfiguration also calls Test-Path on the output
        # directory, so an unconditional default mock is required here.
        Mock Test-Path { $true }
        Mock Get-CntlmNtlmHash {
            @('PassNTLMv2      AABBCCDDEEFF0011')
        }

        $out = Join-Path $TestDrive 'cntlm3.ini'
        $warnings = & {
            New-CntlmConfiguration -OutputPath $out -CntlmExePath 'C:\fake\cntlm.exe' | Out-Null
        } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        $content = Get-Content $out -Raw
        $content | Should -Match 'PassNTLMv2\s+AABBCCDDEEFF0011'
        $content | Should -Not -Match 'Password\s+S3cr3t!'
        ($warnings -join "`n") | Should -Not -Match 'cntlm -H -u userid -d DOMINIO'
    }

    It 'falls back to the plaintext password and warns when hash generation fails' {
        $script:answers4 = @('DOMINIO','userid','proxy.company.net','1234','3128','localhost')
        $script:idx4 = 0
        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'S3cr3t!' -AsPlainText -Force) }
            $val = $script:answers4[$script:idx4]; $script:idx4++; return $val
        }
        Mock Test-Path { $true }
        Mock Get-CntlmNtlmHash { throw 'cntlm -H exited with code 1' }

        $out = Join-Path $TestDrive 'cntlm4.ini'
        $warnings = & {
            New-CntlmConfiguration -OutputPath $out -CntlmExePath 'C:\fake\cntlm.exe' | Out-Null
        } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        (Get-Content $out -Raw) | Should -Match 'Password\s+S3cr3t!'
        ($warnings -join "`n") | Should -Match 'cntlm -H -u userid -d DOMINIO'
    }
}