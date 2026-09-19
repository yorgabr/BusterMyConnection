# File: tests/ForceModes.Tests.ps1

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
        function Out-Info { [CmdletBinding()] param ([string]$Message) }
    }
    if (-not (Get-Command Out-Error -ErrorAction SilentlyContinue)) {
        function Out-Error { [CmdletBinding()] param ([string]$Message) }
    }
}

Describe "Force Modes Tests" {
    BeforeEach {
        # Preserve original environment variable states
        $script:origHttp    = $env:HTTP_PROXY
        $script:origHttps   = $env:HTTPS_PROXY
        $script:origNoProxy = $env:NO_PROXY
        $script:origCntlm   = $env:CNTLM_EXE
        $script:origIni     = $env:CNTLM_INI
        $script:origPac     = $env:PAC_URL

        # Populate path and proxy environment variables with non-empty dummy values.
        # This prevents internal functions from passing null/empty strings to Test-Path,
        # which causes ParameterBindingValidationException prior to Mock execution.
        $env:HTTP_PROXY  = "http://proxy.company.net:1234"
        $env:HTTPS_PROXY = "http://proxy.company.net:1234"
        $env:NO_PROXY    = "localhost,127.0.0.1"
        $env:CNTLM_EXE   = "C:\tools\cntlm\cntlm.exe"
        $env:CNTLM_INI   = "C:\tools\cntlm\cntlm.ini"
        $env:PAC_URL     = "C:\tools\cntlm\proxy.pac"
    }

    AfterEach {
        # Restore original environment variables
        $env:HTTP_PROXY  = $script:origHttp
        $env:HTTPS_PROXY = $script:origHttps
        $env:NO_PROXY    = $script:origNoProxy
        $env:CNTLM_EXE   = $script:origCntlm
        $env:CNTLM_INI   = $script:origIni
        $env:PAC_URL     = $script:origPac
    }

    Context "Invoke-ForceDirect" {
        It "returns true when direct connectivity succeeds" {
            Mock Out-Info { }
            Mock Out-Error { }
            Mock Test-InternetConnectivity { $true }

            $result = Invoke-ForceDirect
            $result | Should -Be $true
        }

        It "returns false when direct connectivity fails" {
            Mock Out-Info { }
            Mock Out-Error { }
            Mock Test-InternetConnectivity { $false }

            $result = Invoke-ForceDirect
            $result | Should -Be $false
        }
    }

    Context "Invoke-ForceProxy" {
        It "returns true when proxy mode succeeds" {
            Mock Out-Info { }
            Mock Out-Error { }
            Mock Test-Path { $true }
            # Get-CntlmConfiguration parses this via Get-Content; supply a fake
            # ini body so the function never touches the real filesystem.
            Mock Get-Content {
                @(
                    'Proxy proxy.company.net:1234'
                    'Listen 3128'
                    'Domain CORP'
                    'Username testuser'
                    'NoProxy localhost,127.0.0.1'
                )
            }
            # Bypasses the cached-credential lookup (Import-Clixml) and the
            # interactive Read-Host prompt; only the returned PSCredential
            # shape matters to Invoke-ForceProxy.
            Mock Get-ProxyCredential {
                New-Object System.Management.Automation.PSCredential(
                    'testuser', (ConvertTo-SecureString 'dummy' -AsPlainText -Force))
            }
            # Upstream proxy reachability check; isolate from the real network.
            Mock Test-TcpPort { $true }
            Mock Test-ProxyConnectivity { $true }
            Mock Test-InternetConnectivity { $true }

            $result = Invoke-ForceProxy
            $result | Should -Be $true
        }

        It "returns false when proxy mode fails" {
            Mock Out-Info { }
            Mock Out-Error { }
            Mock Test-Path { $true }
            Mock Get-Content {
                @(
                    'Proxy proxy.company.net:1234'
                    'Listen 3128'
                    'Domain CORP'
                    'Username testuser'
                    'NoProxy localhost,127.0.0.1'
                )
            }
            Mock Get-ProxyCredential {
                New-Object System.Management.Automation.PSCredential(
                    'testuser', (ConvertTo-SecureString 'dummy' -AsPlainText -Force))
            }
            Mock Test-TcpPort { $true }
            Mock Test-ProxyConnectivity { $false }
            Mock Test-InternetConnectivity { $false }

            $result = Invoke-ForceProxy
            $result | Should -Be $false
        }
    }

    Context "Invoke-ForceCntlm" {
        It "returns true when CNTLM mode succeeds" {
            Mock Out-Info { }
            Mock Out-Error { }
            Mock Start-Process { } -ErrorAction SilentlyContinue
            Mock Start-CntlmProcess { $true } -ErrorAction SilentlyContinue
            Mock Test-ProxyConnectivity { $true }
            Mock Test-InternetConnectivity { $true }
            Mock Test-Path { $true }
            Mock Get-Process { [pscustomobject]@{ Name = 'cntlm'; Id = 1234 } } -ErrorAction SilentlyContinue
            # Same rationale as the Invoke-ForceProxy tests above: parse a fake
            # ini body instead of touching the filesystem, and isolate the
            # loopback listen-port check from the real network stack. Neither
            # of these was mocked before, so the happy path could never
            # actually complete: Get-Content failed against a nonexistent
            # file, and even past that, the real Test-TcpPort call had no
            # CNTLM instance to find listening on 127.0.0.1.
            Mock Get-Content {
                @(
                    'Proxy proxy.company.net:1234'
                    'Listen 3128'
                    'Domain CORP'
                    'Username testuser'
                    'NoProxy localhost,127.0.0.1'
                )
            }
            Mock Test-TcpPort { $true }

            $result = Invoke-ForceCntlm
            $result | Should -Be $true
        }

        It "returns false when CNTLM mode fails" {
            Mock Out-Info { }
            Mock Out-Error { }
            Mock Start-Process { } -ErrorAction SilentlyContinue
            Mock Start-CntlmProcess { $true } -ErrorAction SilentlyContinue
            Mock Test-ProxyConnectivity { $false }
            Mock Test-InternetConnectivity { $false }
            Mock Test-Path { $true }

            $result = Invoke-ForceCntlm
            $result | Should -Be $false
        }
    }
}