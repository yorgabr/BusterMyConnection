#Requires -Version 5.1

BeforeAll {
    # Import target script definitions without executing the main orchestration flow
    . $PSScriptRoot/bmc.ps1 -DotSourceOnly
}

Describe 'BusterMyConnection (bmc) - Unit Test Suite' {

    BeforeEach {
        # Suppress and capture all output helper calls to prevent console output leaking into test execution
        Mock Out-Info {}
        Mock Out-Warn {}
        Mock Out-Err {}
        Mock Out-Succ {}
    }

    Context 'Get-BmcPacUrlFromRegistry' {
        It 'Returns PAC URL when present in Windows Registry' {
            Mock Test-Path { return $true }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{ AutoConfigURL = 'http://pac.corp.local/proxy.pac' }
            }

            $result = Get-BmcPacUrlFromRegistry
            $result | Should -Be 'http://pac.corp.local/proxy.pac'
        }

        It 'Returns $null when AutoConfigURL property is empty or missing' {
            Mock Test-Path { return $true }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{ AutoConfigURL = $null }
            }

            $result = Get-BmcPacUrlFromRegistry
            $result | Should -BeNullOrEmpty
        }

        It 'Handles Registry access failures by returning $null and logging a warning' {
            Mock Test-Path { return $true }
            Mock Get-ItemProperty { throw "Registry access denied" }

            $result = Get-BmcPacUrlFromRegistry
            $result | Should -BeNullOrEmpty
            Should -Invoke Out-Warn -Exactly 1
        }
    }

    Context 'Get-BmcPxBinaryPath' {
        It 'Locates px.exe when present in system PATH' {
            Mock Get-Command {
                return [PSCustomObject]@{ Source = 'C:\Tools\px.exe' }
            } -ParameterFilter { $Name -eq 'px.exe' }

            $result = Get-BmcPxBinaryPath
            $result | Should -Be 'C:\Tools\px.exe'
        }

        It 'Locates px.exe in default Scoop directory if not in PATH' {
            Mock Get-Command { return $null }
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*scoop\apps\px\current\px.exe' }

            $result = Get-BmcPxBinaryPath
            $result | Should -Match 'px\.exe$'
        }

        It 'Returns $null when Px Proxy executable is not found' {
            Mock Get-Command { return $null }
            Mock Test-Path { return $false }

            $result = Get-BmcPxBinaryPath
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Install-BmcPxProxy' {
        It 'Returns path immediately if Px Proxy is already installed' {
            Mock Get-BmcPxBinaryPath { return 'C:\Scoop\apps\px\current\px.exe' }

            $path = Install-BmcPxProxy
            $path | Should -Be 'C:\Scoop\apps\px\current\px.exe'
            Should -Invoke Out-Info -Exactly 1
        }

        It 'Triggers Scoop installation when binary is missing' {
            $script:installed = $false
            Mock Get-BmcPxBinaryPath {
                if ($script:installed) { return 'C:\Users\Test\scoop\apps\px\current\px.exe' }
                return $null
            }
            Mock Get-Command { return [PSCustomObject]@{ Source = 'C:\Scoop\shims\scoop.cmd' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock Start-Process {
                $script:installed = $true
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $path = Install-BmcPxProxy
            $path | Should -Be 'C:\Users\Test\scoop\apps\px\current\px.exe'
            Should -Invoke Start-Process -Exactly 1 -ParameterFilter { $FilePath -eq 'scoop' -and $ArgumentList -contains 'px' }
            Should -Invoke Out-Succ -Exactly 1
        }

        It 'Throws exception when Scoop is not installed on system' {
            Mock Get-BmcPxBinaryPath { return $null }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'scoop' }

            { Install-BmcPxProxy } | Should -Throw "*Scoop was not found*"
        }

        It 'Throws exception if Scoop installation fails with exit code' {
            Mock Get-BmcPxBinaryPath { return $null }
            Mock Get-Command { return [PSCustomObject]@{ Source = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }

            { Install-BmcPxProxy } | Should -Throw "*Exit Code: 1*"
        }
    }

    Context 'Test-BmcPacEndpoint' {
        It 'Simulates connection failure and returns $false for unreachable PAC endpoints' {
            $result = Test-BmcPacEndpoint -PacUrl 'http://127.0.0.1:65534/nonexistent.pac' -TimeoutSeconds 1
            $result | Should -Be $false
        }
    }

    Context 'Get-BmcRunningPxProcess' {
        It 'Returns process object associated with listening port' {
            Mock Get-Process { return [PSCustomObject]@{ Id = 5678; ProcessName = 'px' } } -ParameterFilter { $Name -eq 'px' }
            Mock Get-NetTCPConnection { return [PSCustomObject]@{ OwningProcess = 5678; LocalPort = 3128 } } -ParameterFilter { $LocalPort -eq 3128 }

            $proc = Get-BmcRunningPxProcess -TargetPort 3128
            $proc.Id | Should -Be 5678
        }

        It 'Returns $null when no Px Proxy process is found' {
            Mock Get-Process { return $null } -ParameterFilter { $Name -eq 'px' }

            $proc = Get-BmcRunningPxProcess -TargetPort 3128
            $proc | Should -BeNullOrEmpty
        }
    }

    Context 'State Management and Environment Variables (Simulated I/O)' {
        BeforeEach {
            # Instead of relying on the Pester PSDrive resolution inside the functions (the source of the
            # previous bug), we use the real physical TestDrive path via $TestDrive. That path is an
            # ordinary filesystem directory, resolved identically by both the functions and the
            # assertions, eliminating any divergence between the PSDrive view and the native provider.
            $script:testAppDataPath = Join-Path -Path $TestDrive -ChildPath 'bmc'
            $script:testStatePath   = Join-Path -Path $script:testAppDataPath -ChildPath 'state.json'
        }

        It 'Enable-BmcDirectAccess removes process proxy variables and persists state' {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:3128', 'Process')

            # Inject the test paths explicitly, with no dependence on global variable scope.
            Enable-BmcDirectAccess -AppDataPath $script:testAppDataPath -StatePath $script:testStatePath

            [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process') | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:testStatePath | Should -Be $true
            Should -Invoke Out-Warn -Exactly 1
            Should -Invoke Out-Succ -Exactly 1
        }

        It 'Restore-BmcProxyEnvironment sets proxy environment variables pointing to configured port' {
            Restore-BmcProxyEnvironment -LocalPort 3128 -AppDataPath $script:testAppDataPath -StatePath $script:testStatePath

            [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process') | Should -Be 'http://127.0.0.1:3128'
            [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process') | Should -Be 'http://127.0.0.1:3128'
            Should -Invoke Out-Succ -Exactly 1
        }
    }

    Context 'Main Orchestration Flow (Start-BmcOrchestration)' {
        It 'Enables Direct Access when Registry does not contain PAC URL' {
            Mock Get-BmcPacUrlFromRegistry { return $null }
            Mock Enable-BmcDirectAccess {}

            Start-BmcOrchestration -LocalPort 3128

            Should -Invoke Enable-BmcDirectAccess -Exactly 1
        }

        It 'Enables Direct Access when PAC file is network unreachable' {
            Mock Get-BmcPacUrlFromRegistry { return 'http://pac.corp.local/proxy.pac' }
            Mock Test-BmcPacEndpoint { return $false }
            Mock Enable-BmcDirectAccess {}

            Start-BmcOrchestration -LocalPort 3128

            Should -Invoke Enable-BmcDirectAccess -Exactly 1
        }

        It 'Initializes Px Proxy by passing CLI parameters directly (--pac)' {
            Mock Get-BmcPacUrlFromRegistry { return 'http://pac.corp.local/proxy.pac' }
            Mock Test-BmcPacEndpoint { return $true }
            Mock Install-BmcPxProxy { return 'C:\scoop\apps\px\current\px.exe' }

            $script:pxStarted = $false
            Mock Get-BmcRunningPxProcess {
                if ($script:pxStarted) { return [PSCustomObject]@{ Id = 1010 } }
                return $null
            }
            Mock Start-Process {
                $script:pxStarted = $true
                return $null
            }
            Mock Restore-BmcProxyEnvironment {}

            Start-BmcOrchestration -LocalPort 3128

            Should -Invoke Start-Process -Exactly 1 -ParameterFilter {
                $FilePath -eq 'C:\scoop\apps\px\current\px.exe' -and
                $ArgumentList -contains '--pac=http://pac.corp.local/proxy.pac' -and
                $ArgumentList -contains '--listen=127.0.0.1' -and
                $ArgumentList -contains '--port=3128'
            }
            Should -Invoke Restore-BmcProxyEnvironment -Exactly 1
        }
    }
}