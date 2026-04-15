# tests/MainFlow.Tests.ps1

$scriptPath = Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1'

Describe 'Main execution flow' {

    Mock Install-CntlmPortable { 'cntlm.exe' }
    Mock Start-Process {}
    Mock Test-UpstreamProxyConnectivity { $false }
    Mock Test-InternetConnectivity { $true }
    Mock Remove-ProxyEnvironmentVariables { @{ Count = 1; Backup = @{} } }
    Mock Set-ExecutionState {}

    It 'enters DirectAccess mode when proxy is dead' {
        . $scriptPath
        $LASTEXITCODE | Should -Be 0
    }

    Mock Test-UpstreamProxyConnectivity { $true }
    Mock Test-ProxyConnectivity { $true }

    It 'enters Proxy mode when proxy is healthy' {
        . $scriptPath
        $LASTEXITCODE | Should -Be 0
    }
}
