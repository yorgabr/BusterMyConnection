#requires -Version 5.1
#requires -Modules Pester

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\bustermyconnection\Buster-MyConnection.ps1')).Path
    . $script:ScriptPath -DotSourceOnly
}

Describe 'Test-InternetConnectivity' {

    It 'returns true when a request succeeds' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Test-InternetConnectivity -TimeoutSeconds 1 | Should -BeTrue
    }

    It 'returns false when every request fails' {
        Mock Invoke-WebRequest { throw 'no network' }
        Test-InternetConnectivity -TimeoutSeconds 1 | Should -BeFalse
    }
}

Describe 'Test-ProxyConnectivity' {

    It 'returns true when all proxied requests succeed' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Test-ProxyConnectivity -ProxyUrl 'http://127.0.0.1:3128' -TimeoutSeconds 1 | Should -BeTrue
    }

    It 'returns false and warns on the first request error' {
        Mock Invoke-WebRequest { throw 'proxy refused' }

        $result = $null
        $warnings = & {
            $script:r = Test-ProxyConnectivity -ProxyUrl 'http://127.0.0.1:3128' -TimeoutSeconds 1
        } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        $result = $script:r

        $result   | Should -BeFalse
        $warnings | Should -Not -BeNullOrEmpty
        ($warnings -join "`n") | Should -Match 'proxy refused'
        ($warnings -join "`n") | Should -Match 'http://127\.0\.0\.1:3128'
    }

    It 'passes ProxyCredential through when supplied' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        $sec  = ConvertTo-SecureString 'p' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential('u', $sec)

        Test-ProxyConnectivity -ProxyUrl 'http://127.0.0.1:3128' -TimeoutSeconds 1 -Credential $cred | Should -BeTrue
        Should -Invoke Invoke-WebRequest -ParameterFilter { $ProxyCredential -ne $null }
    }
}

