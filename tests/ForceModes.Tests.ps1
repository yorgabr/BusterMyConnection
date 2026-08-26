#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Invoke-ForceDirect' {

    BeforeEach {
        Set-Variable -Name StateFilePath -Scope Script -Value (Join-Path $TestDrive 'state.json')
        Mock Remove-ProxyEnvironmentVariables { [pscustomobject]@{ Backup = @{}; Count = 0 } }
        Mock Set-ExecutionState {}
    }

    It 'returns true when direct connectivity succeeds' {
        Mock Test-InternetConnectivity { $true }
        Invoke-ForceDirect | Should -BeTrue
        Should -Invoke Set-ExecutionState -Times 1
    }

    It 'returns false when direct connectivity fails' {
        Mock Test-InternetConnectivity { $false }
        Invoke-ForceDirect | Should -BeFalse
    }
}

Describe 'Invoke-ForceProxy' {

    BeforeEach {
        Set-Variable -Name StateFilePath -Scope Script -Value (Join-Path $TestDrive 'state.json')
        $script:ini = Join-Path $TestDrive 'cntlm.ini'
        @'
Username userid
Domain   DOMINIO
Proxy    proxy.company.net:1234
Listen   3128
NoProxy  localhost
'@ | Set-Content $script:ini

        Mock Get-ProxyCredential {
            $sec = ConvertTo-SecureString 'pw' -AsPlainText -Force
            New-Object System.Management.Automation.PSCredential('DOMINIO\userid', $sec)
        }
        Mock Remove-ProxyEnvironmentVariables { [pscustomobject]@{ Backup = @{}; Count = 0 } }
        Mock Set-ExecutionState {}
        Mock Set-ProxyEnvironmentForCorporate {}
    }

    It 'fails fast when the ini file is absent' {
        Invoke-ForceProxy -IniPath (Join-Path $TestDrive 'missing.ini') | Should -BeFalse
    }

    It 'fails when the upstream proxy TCP port is unreachable' {
        Mock Test-TcpPort { $false }
        Invoke-ForceProxy -IniPath $script:ini | Should -BeFalse
    }

    It 'succeeds when proxy is reachable and connectivity passes' {
        Mock Test-TcpPort { $true }
        Mock Test-ProxyConnectivity { $true }
        Invoke-ForceProxy -IniPath $script:ini | Should -BeTrue
        Should -Invoke Set-ExecutionState -Times 1
    }

    It 'fails when connectivity test fails after configuration' {
        Mock Test-TcpPort { $true }
        Mock Test-ProxyConnectivity { $false }
        Invoke-ForceProxy -IniPath $script:ini | Should -BeFalse
    }
}

Describe 'Invoke-ForceCntlm' {

    BeforeEach {
        Set-Variable -Name StateFilePath -Scope Script -Value (Join-Path $TestDrive 'state.json')
        $script:ini = Join-Path $TestDrive 'cntlm.ini'
        @'
Proxy   proxy.company.net:1234
Listen  3128
NoProxy localhost
'@ | Set-Content $script:ini

        Mock Resolve-CntlmExecutable { 'C:\fake\cntlm.exe' }
        Mock Start-CntlmProcess {}
        Mock Set-ProxyEnvironmentForCntlm {}
        Mock Set-ExecutionState {}
    }

    It 'fails when CNTLM process does not come up' {
        Mock Test-CntlmRunning { $false }
        Invoke-ForceCntlm -CntlmPath 'C:\fake\cntlm.exe' -IniPath $script:ini | Should -BeFalse
    }

    It 'fails when CNTLM runs but the port is not listening' {
        Mock Test-CntlmRunning { $true }
        Mock Test-TcpPort { $false }
        Invoke-ForceCntlm -CntlmPath 'C:\fake\cntlm.exe' -IniPath $script:ini | Should -BeFalse
    }

    It 'succeeds when process, port and connectivity all check out' {
        Mock Test-CntlmRunning { $true }
        Mock Test-TcpPort { $true }
        Mock Test-ProxyConnectivity { $true }
        Invoke-ForceCntlm -CntlmPath 'C:\fake\cntlm.exe' -IniPath $script:ini | Should -BeTrue
        Should -Invoke Set-ExecutionState -Times 1
    }
}
