#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Test-CntlmRunning' {

    It 'returns true when a cntlm process exists' {
        Mock Get-Process { [pscustomobject]@{ Name = 'cntlm' } }
        Test-CntlmRunning | Should -BeTrue
    }

    It 'returns false when no cntlm process exists' {
        Mock Get-Process { $null }
        Test-CntlmRunning | Should -BeFalse
    }
}

Describe 'Stop-CntlmProcess' {

    It 'stops running cntlm processes when present' {
        $proc = [pscustomobject]@{ Name = 'cntlm' }
        Mock Get-Process { $proc }
        Mock Stop-Process {}
        Mock Start-Sleep {}

        Stop-CntlmProcess
        Should -Invoke Stop-Process -Times 1
    }

    It 'does nothing when no cntlm process is present' {
        Mock Get-Process { $null }
        Mock Stop-Process {}

        Stop-CntlmProcess
        Should -Invoke Stop-Process -Times 0
    }
}

Describe 'Start-CntlmProcess' {

    It 'stops existing processes and starts a new one by default' {
        Mock Stop-CntlmProcess {}
        Mock Start-Process {}
        Mock Start-Sleep {}

        Start-CntlmProcess -ExePath 'C:\cntlm.exe' -IniPath 'C:\cntlm.ini'

        Should -Invoke Stop-CntlmProcess -Times 1
        Should -Invoke Start-Process -Times 1
    }
}

Describe 'Test-TcpPort' {

    It 'returns false when the connection times out' {
        # A reserved TEST-NET address (RFC 5737) will not answer; expect a timeout.
        Test-TcpPort -Address '192.0.2.1' -Port 9 -TimeoutSeconds 1 | Should -BeFalse
    }
}
