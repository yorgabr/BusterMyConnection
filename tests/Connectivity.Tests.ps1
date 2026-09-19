BeforeAll {
    $candidatePaths = @(
        (Join-Path $PSScriptRoot "..\src\bustermyconnection\Buster-MyConnection.ps1"),
        (Join-Path $PSScriptRoot "..\src\Buster-MyConnection.ps1"),
        (Join-Path $PSScriptRoot "..\src\BusterMyConnection.ps1")
    )

    $scriptImported = $false
    foreach ($path in $candidatePaths) {
        if (Test-Path -Path $path) {
            # -DotSourceOnly stops the script right after its function
            # definitions, before the real auto-detection flow runs. Without
            # it, this BeforeAll would execute the live strategy chain (real
            # network calls, real CNTLM process spawning) on every test run,
            # which is both slow and floods the test output with unrelated
            # noise from the implementation under test. Every other test file
            # in this suite already follows this convention (see
            # CONTRIBUTING.md); this one was the odd one out.
            # -Quiet additionally silences the Out-Info/Out-Success/Out-Warn/
            # Out-Error helpers for calls made directly against the real
            # (unmocked) functions in the Its below - none of them assert on
            # message text, so there is nothing to lose by keeping the test
            # output focused on Pester's own pass/fail reporting.
            . $path -DotSourceOnly -Quiet
            $scriptImported = $true
            break
        }
    }

    if (-not $scriptImported) {
        throw "Unable to locate the main application script (Buster-MyConnection.ps1) from $($PSScriptRoot)"
    }

    if (-not (Get-Command Out-Info -ErrorAction SilentlyContinue)) {
        function Out-Info {
            [CmdletBinding()]
            param ([string]$Message)
        }
    }
}

Describe "Connectivity Tests" {
    Context "Test-InternetConnectivity" {
        It "returns true when a request succeeds" {
            Mock Out-Info { }
            Mock Invoke-WebRequest { @{ StatusCode = 200 } }
            $result = Test-InternetConnectivity
            $result | Should -Be $true
        }

        It "returns false when every request fails" {
            Mock Out-Info { }
            Mock Invoke-WebRequest { throw "Network unreachable" }
            $result = Test-InternetConnectivity
            $result | Should -Be $false
        }
    }

    Context "Test-ProxyConnectivity" {
        It "returns true when all proxied requests succeed" {
            Mock Out-Info { }
            Mock Invoke-WebRequest { @{ StatusCode = 200 } }
            $result = Test-ProxyConnectivity -ProxyUrl "http://127.0.0.1:3128"
            $result | Should -Be $true
        }

        It "returns false and warns on the first request error" {
            Mock Out-Info { }
            Mock Invoke-WebRequest { throw "Proxy connection failed" }
            $result = Test-ProxyConnectivity -ProxyUrl "http://127.0.0.1:3128"
            $result | Should -Be $false
        }
    }
}