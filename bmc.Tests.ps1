#Requires -Version 5.1

BeforeAll {
    # Import target script definitions without executing the main orchestration flow
    . $PSScriptRoot/bmc.ps1 -DotSourceOnly

    # Provide stub command definitions so Pester can mock cmdlets that may not exist on the
    # current host (e.g. Get-NetAdapter / Get-DnsClient on non-Windows CI agents or when the
    # NetTCPIP/DnsClient modules are unavailable). Mocks override these stubs transparently.
    if (-not (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue)) {
        function Get-NetAdapter { param([switch] $ErrorAction) }
    }
    if (-not (Get-Command -Name 'Get-DnsClient' -ErrorAction SilentlyContinue)) {
        function Get-DnsClient { param([switch] $ErrorAction) }
    }
    if (-not (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue)) {
        function scoop { }
    }
    if (-not (Get-Command -Name 'git' -ErrorAction SilentlyContinue)) {
        function git { }
    }
    if (-not (Get-Command -Name 'npm' -ErrorAction SilentlyContinue)) {
        function npm { }
    }
}

Describe 'BusterMyConnection (bmc) - Unit Test Suite' {

    BeforeEach {
        # Suppress and capture all output helper calls to prevent console output leaking into test execution
        Mock Out-Info {}
        Mock Out-Warn {}
        Mock Out-Err {}
        Mock Out-Succ {}
    }

    Context 'Get-BmcConfig' {
        BeforeEach {
            $script:cfgPath = Join-Path -Path $TestDrive -ChildPath 'bmc.config.json'
        }

        It 'Falls back to the built-in template when the file is absent' {
            $missing = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.json'
            $cfg = Get-BmcConfig -Path $missing
            $cfg.tools | Should -Contain 'Scoop'
            $cfg.scenarios.Home.proxy | Should -Be 'none'
        }

        It 'Loads and parses an on-disk config file' {
            $json = '{ "scenarios": { "Office": { "proxy": "auto", "nexus": true } }, "tools": ["Git"] }'
            Set-Content -LiteralPath $script:cfgPath -Value $json -Encoding UTF8
            $cfg = Get-BmcConfig -Path $script:cfgPath
            $cfg.scenarios.Office.proxy | Should -Be 'auto'
        }

        It 'Falls back to template and warns on invalid JSON' {
            Set-Content -LiteralPath $script:cfgPath -Value '{ not valid json' -Encoding UTF8
            $cfg = Get-BmcConfig -Path $script:cfgPath
            $cfg.scenarios.Home.proxy | Should -Be 'none'
            Should -Invoke Out-Warn -Exactly 1
        }
    }

    Context 'Get-BmcScenario' {
        BeforeEach {
            $script:cfg = Get-BmcTemplateConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        }

        It 'Returns Vpn when an active adapter matches the VPN pattern' {
            Mock Get-NetAdapter {
                return @([PSCustomObject]@{ Status = 'Up'; Name = 'F5 VPN'; InterfaceDescription = 'F5 Networks Virtual Adapter' })
            }
            Mock Get-DnsClient { return @() }

            Get-BmcScenario -Config $script:cfg | Should -Be 'Vpn'
        }

        It 'Returns Office when a DNS suffix matches the office pattern' {
            Mock Get-NetAdapter { return @() }
            Mock Get-DnsClient {
                return @([PSCustomObject]@{ ConnectionSpecificSuffix = 'corp.example.com' })
            }

            Get-BmcScenario -Config $script:cfg | Should -Be 'Office'
        }

        It 'Returns Home when nothing matches' {
            Mock Get-NetAdapter { return @() }
            Mock Get-DnsClient { return @([PSCustomObject]@{ ConnectionSpecificSuffix = 'lan' }) }

            Get-BmcScenario -Config $script:cfg | Should -Be 'Home'
        }
    }

    Context 'Invoke-BmcCli' {
        It 'Returns the exit code of the native command' -Skip:($env:OS -ne 'Windows_NT') {
            Invoke-BmcCli -Tool 'cmd.exe' -Arguments @('/c', 'exit 3') | Should -Be 3
        }

        It 'Does not throw on native stderr output even when ErrorActionPreference is Stop' -Skip:($env:OS -ne 'Windows_NT') {
            {
                $ErrorActionPreference = 'Stop'
                Invoke-BmcCli -Tool 'cmd.exe' -Arguments @('/c', 'echo boom 1>&2 & exit 0')
            } | Should -Not -Throw
        }

        It 'Restores the caller ErrorActionPreference' -Skip:($env:OS -ne 'Windows_NT') {
            $ErrorActionPreference = 'Stop'
            $null = Invoke-BmcCli -Tool 'cmd.exe' -Arguments @('/c', 'exit 0')
            $ErrorActionPreference | Should -Be 'Stop'
        }
    }

    Context 'Set-BmcToolProxy' {
        BeforeEach {
            # Every external CLI call goes through Invoke-BmcCli. Mocking it keeps the real
            # scoop/git/npm configuration of the machine untouched while the suite runs.
            Mock Invoke-BmcCli { return 0 }
        }

        It 'Configures Scoop with host:port and Git with full URL when proxy is set' {
            Mock Get-Command { return [PSCustomObject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'git' } }   -ParameterFilter { $Name -eq 'git' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'npm' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'uv' }

            Set-BmcToolProxy -ProxyUrl 'http://127.0.0.1:3128'

            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'scoop' -and ($Arguments -join ' ') -eq 'config proxy 127.0.0.1:3128'
            }
            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'git' -and ($Arguments -join ' ') -eq 'config --global http.proxy http://127.0.0.1:3128'
            }
            Should -Invoke Invoke-BmcCli -Times 0 -Exactly -ParameterFilter { $Tool -eq 'npm' }
        }

        It 'Never sets the non-existent Git key https.proxy, only removes stale copies of it' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -in @('scoop', 'npm', 'uv') }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'git' } } -ParameterFilter { $Name -eq 'git' }

            Set-BmcToolProxy -ProxyUrl 'http://127.0.0.1:3128'

            Should -Invoke Invoke-BmcCli -Times 0 -Exactly -ParameterFilter {
                $Tool -eq 'git' -and ($Arguments -contains 'https.proxy') -and ($Arguments -notcontains '--unset')
            }
            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'git' -and ($Arguments -join ' ') -eq 'config --global --unset https.proxy'
            }
        }

        It 'Clears Scoop and Git proxy when invoked with an empty URL (Direct Access)' {
            Mock Get-Command { return [PSCustomObject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'git' } }   -ParameterFilter { $Name -eq 'git' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'npm' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'uv' }

            Set-BmcToolProxy -ProxyUrl $null

            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'scoop' -and ($Arguments -join ' ') -eq 'config rm proxy'
            }
            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'git' -and ($Arguments -join ' ') -eq 'config --global --unset http.proxy'
            }
        }

        It 'Sets npm proxy and https-proxy when npm is available' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -in @('scoop', 'git', 'uv') }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'npm' } } -ParameterFilter { $Name -eq 'npm' }

            Set-BmcToolProxy -ProxyUrl 'http://127.0.0.1:3128'

            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'npm' -and ($Arguments -join ' ') -eq 'config set proxy http://127.0.0.1:3128'
            }
            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'npm' -and ($Arguments -join ' ') -eq 'config set https-proxy http://127.0.0.1:3128'
            }
        }

        It 'Clears npm proxy settings in Direct Access' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -in @('scoop', 'git', 'uv') }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'npm' } } -ParameterFilter { $Name -eq 'npm' }

            Set-BmcToolProxy -ProxyUrl ''

            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'npm' -and ($Arguments -join ' ') -eq 'config delete proxy'
            }
            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'npm' -and ($Arguments -join ' ') -eq 'config delete https-proxy'
            }
        }

        It 'Warns instead of reporting success when Scoop returns a non-zero exit code' {
            Mock Get-Command { return $null } -ParameterFilter { $Name -in @('git', 'npm', 'uv') }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'scoop' } } -ParameterFilter { $Name -eq 'scoop' }
            Mock Invoke-BmcCli { return 1 } -ParameterFilter { $Tool -eq 'scoop' }

            Set-BmcToolProxy -ProxyUrl 'http://127.0.0.1:3128'

            Should -Invoke Out-Warn -Times 1 -Exactly
        }
    }

    Context 'Set-BmcNexusConfig' {
        BeforeEach {
            $script:cfg = Get-BmcTemplateConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'npm' }
        }

        It 'Sets UV/PIP index variables when enabled' {
            Set-BmcNexusConfig -Config $script:cfg -Enabled $true
            [Environment]::GetEnvironmentVariable('UV_INDEX_URL', 'Process')  | Should -Be $script:cfg.nexus.pypiIndexUrl
            [Environment]::GetEnvironmentVariable('PIP_INDEX_URL', 'Process') | Should -Be $script:cfg.nexus.pypiIndexUrl
        }

        It 'Clears UV/PIP index variables when disabled' {
            [Environment]::SetEnvironmentVariable('UV_INDEX_URL', 'http://old', 'Process')
            Set-BmcNexusConfig -Config $script:cfg -Enabled $false
            [Environment]::GetEnvironmentVariable('UV_INDEX_URL', 'Process') | Should -BeNullOrEmpty
        }
    }

    Context 'Set-BmcNexusConfig (npm registry)' {
        BeforeEach {
            $script:cfg = Get-BmcTemplateConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            Mock Get-Command { return [PSCustomObject]@{ Name = 'npm' } } -ParameterFilter { $Name -eq 'npm' }
            Mock Invoke-BmcCli { return 0 }
        }

        It 'Points npm at the Nexus registry when enabled' {
            Set-BmcNexusConfig -Config $script:cfg -Enabled $true

            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'npm' -and
                ($Arguments -join ' ') -eq 'config set registry https://nexus.corp.example.com/repository/npm-group/'
            }
        }

        It 'Restores the default npm registry when disabled' {
            Set-BmcNexusConfig -Config $script:cfg -Enabled $false

            Should -Invoke Invoke-BmcCli -Times 1 -Exactly -ParameterFilter {
                $Tool -eq 'npm' -and ($Arguments -join ' ') -eq 'config delete registry'
            }
        }
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
            $script:testAppDataPath = Join-Path -Path $TestDrive -ChildPath 'bmc'
            $script:testStatePath   = Join-Path -Path $script:testAppDataPath -ChildPath 'state.json'

            # Neutralize tool reconfiguration side effects in these focused I/O tests.
            Mock Set-BmcToolProxy {}
        }

        It 'Enable-BmcDirectAccess removes process proxy variables and persists state' {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:3128', 'Process')

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
        BeforeEach {
            # Pin a deterministic scenario and neutralize tool/Nexus side effects by default.
            Mock Get-BmcScenario { return 'Office' }
            Mock Set-BmcNexusConfig {}
            Mock Set-BmcToolProxy {}
        }

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

        It 'Enables Direct Access when the active scenario requests proxy=none (Home)' {
            Mock Get-BmcScenario { return 'Home' }
            Mock Get-BmcPacUrlFromRegistry { return 'http://pac.corp.local/proxy.pac' }
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