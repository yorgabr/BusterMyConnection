# tests/Connectivity.Tests.ps1

$scriptPath = Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1'
. $scriptPath

Describe 'Connectivity checks' {

    Mock Invoke-WebRequest {
        [pscustomobject]@{ StatusCode = 200 }
    }

    It 'validates direct internet connectivity' {
        Test-InternetConnectivity -TimeoutSeconds 1 | Should -BeTrue
    }

    Mock Invoke-WebRequest { throw }

    It 'fails proxy connectivity on request error' {
        Test-ProxyConnectivity -ProxyPort 3128 -TimeoutSeconds 1 | Should -BeFalse
    }
}