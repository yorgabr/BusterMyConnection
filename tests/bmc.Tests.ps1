#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester 5 tests for bmc.ps1.

    Strategy: the script is dot-sourced (it only defines functions in that case) and every adapter that touches the
    outside world (native tools, .NET network/proxy, user environment, registry, PATH lookup) is mocked. Real file
    handling is exercised inside TestDrive. Nothing here reads or writes the real profile.
#>

BeforeAll {
    $script:Sut = Join-Path $PSScriptRoot 'bmc.ps1'
    . $script:Sut

    # A complete, valid configuration. Domains use the reserved .test TLD (RFC 2606), which the placeholder guard allows.
    function New-TestConfig {
        [pscustomobject]@{
            detection = [pscustomobject]@{
                vpnAdapterPattern      = 'F5|BIG-IP'
                officeDnsSuffixPattern = '(^|\.)corp\.test$'
            }
            scenarios = [pscustomobject]@{
                Office = [pscustomobject]@{ proxy = 'auto'; nexus = $true }
                Vpn    = [pscustomobject]@{ proxy = 'auto'; nexus = $true }
                Home   = [pscustomobject]@{ proxy = 'none'; nexus = $false }
            }
            proxy     = [pscustomobject]@{
                overrideUrl = 'http://127.0.0.1:3128'
                noProxy     = 'localhost,.corp.test'
                probeUrl    = 'https://pypi.org'
            }
            nexus     = [pscustomobject]@{
                pypiIndexUrl   = 'https://nexus.corp.test/repository/pypi/simple'
                npmRegistryUrl = 'https://nexus.corp.test/repository/npm/'
            }
            git       = [pscustomobject]@{ useCurrentUserCredentials = $true }
        }
    }

    function New-TestNic {
        param([string] $Name = 'Ethernet', [string] $Description = 'Generic NIC', [bool] $IsUp = $true, [string] $DnsSuffix = '')
        [pscustomobject]@{ Name = $Name; Description = $Description; IsUp = $IsUp; DnsSuffix = $DnsSuffix }
    }

    function New-TestState {
        param([string] $Mode = 'auto', [string] $ProxyUrl = 'http://proxy.corp.test:8080', [bool] $Nexus = $true)
        $proxyHostPort = $null
        $noProxy = $null
        if ($ProxyUrl) { $proxyHostPort = 'proxy.corp.test:8080'; $noProxy = 'localhost,.corp.test' }
        [pscustomobject]@{
            Scenario       = 'Office'
            ProxyMode      = $Mode
            ProxyUrl       = $ProxyUrl
            ProxyHostPort  = $proxyHostPort
            NoProxy        = $noProxy
            UseNexus       = $Nexus
            PypiIndexUrl   = if ($Nexus) { 'https://nexus.corp.test/repository/pypi/simple' } else { $null }
            NpmRegistryUrl = if ($Nexus) { 'https://nexus.corp.test/repository/npm/' } else { $null }
        }
    }

    function New-TestPaths {
        @{
            Config      = Join-Path $TestDrive 'config.json'
            UvConfig    = Join-Path $TestDrive 'appdata\uv\uv.toml'
            NpmRc       = Join-Path $TestDrive 'home\.npmrc'
            ScoopConfig = Join-Path $TestDrive 'scoop\config.json'
        }
    }

    # In-memory stand-in for git and scoop used by the end-to-end tests.
    function Invoke-FakeNative {
        param([string] $FilePath, [string[]] $ArgumentList)
        $ok = { param($lines) [pscustomobject]@{ ExitCode = 0; Output = @($lines) } }
        if ($FilePath -eq 'git') {
            $key = $ArgumentList[-1]
            if ($ArgumentList -contains '--get') {
                if ($script:FakeGit.ContainsKey($key)) { return & $ok $script:FakeGit[$key] }
                return [pscustomobject]@{ ExitCode = 1; Output = @() }
            }
            if ($ArgumentList -contains '--unset') { $script:FakeGit.Remove($key); return & $ok @() }
            $script:FakeGit[$ArgumentList[2]] = $ArgumentList[3]
            return & $ok @()
        }
        if ($FilePath -eq 'scoop') {
            $directory = Split-Path $script:FakeScoopConfig -Parent
            if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            if ($ArgumentList[1] -eq 'rm') { Set-Content -Path $script:FakeScoopConfig -Value '{}' }
            else { Set-Content -Path $script:FakeScoopConfig -Value ((@{ proxy = $ArgumentList[2] }) | ConvertTo-Json) }
            return & $ok @()
        }
        throw "unexpected native call: $FilePath"
    }
}

Describe 'Merge-BmcManagedBlock' {
    It 'inserts the block into empty text' {
        $result = Merge-BmcManagedBlock -Text '' -Line @('a = 1')
        $result | Should -Match '# >>> bmc managed block'
        $result | Should -Match 'a = 1'
    }

    It 'treats a null text as empty' {
        Merge-BmcManagedBlock -Text $null -Line @('a = 1') | Should -Match 'a = 1'
    }

    It 'places the block before user content and keeps that content intact' {
        $result = Merge-BmcManagedBlock -Text "[tool]`r`nx = 1`r`n" -Line @('a = 1')
        $result.IndexOf('a = 1') | Should -BeLessThan $result.IndexOf('[tool]')
        $result | Should -Match '\[tool\]\r\nx = 1'
    }

    It 'is idempotent' {
        $once = Merge-BmcManagedBlock -Text "user = 1`r`n" -Line @('a = 1')
        $twice = Merge-BmcManagedBlock -Text $once -Line @('a = 1')
        $twice | Should -BeExactly $once
    }

    It 'replaces a previous block instead of stacking a second one' {
        $first = Merge-BmcManagedBlock -Text '' -Line @('a = 1')
        $second = Merge-BmcManagedBlock -Text $first -Line @('b = 2')
        $second | Should -Match 'b = 2'
        $second | Should -Not -Match 'a = 1'
        ([regex]::Matches($second, '>>> bmc managed block')).Count | Should -Be 1
    }

    It 'removes the block and leaves user content when no lines are given' {
        $with = Merge-BmcManagedBlock -Text "user = 1`r`n" -Line @('a = 1')
        Merge-BmcManagedBlock -Text $with -Line @() | Should -BeExactly "user = 1`r`n"
    }

    It 'returns empty text when only the block existed and it is removed' {
        $with = Merge-BmcManagedBlock -Text '' -Line @('a = 1')
        Merge-BmcManagedBlock -Text $with -Line $null | Should -BeExactly ''
    }

    It 'ignores blank lines in the request' {
        Merge-BmcManagedBlock -Text 'x' -Line @('', '  ') | Should -BeExactly 'x'
    }
}

Describe 'Test-BmcHttpUrl' {
    It 'accepts http and https URLs' {
        Test-BmcHttpUrl -Value 'https://nexus.corp.test/repo' | Should -BeTrue
        Test-BmcHttpUrl -Value 'http://proxy.corp.test:8080' | Should -BeTrue
    }
    It 'rejects empty, relative, non-http and quoted values' {
        Test-BmcHttpUrl -Value '' | Should -BeFalse
        Test-BmcHttpUrl -Value 'nexus.corp.test' | Should -BeFalse
        Test-BmcHttpUrl -Value 'ftp://nexus.corp.test' | Should -BeFalse
        Test-BmcHttpUrl -Value 'https://x.test/"y' | Should -BeFalse
    }
}

Describe 'Read-BmcConfig' {
    BeforeEach { $script:cfgPath = Join-Path $TestDrive 'cfg.json' }

    It 'loads a valid configuration' {
        New-TestConfig | ConvertTo-Json -Depth 6 | Set-Content $script:cfgPath
        (Read-BmcConfig -Path $script:cfgPath).scenarios.Home.proxy | Should -Be 'none'
    }

    It 'fails with guidance when the file is missing' {
        { Read-BmcConfig -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*-InitConfig*'
    }

    It 'rejects the unedited template (placeholder domains)' {
        Get-BmcTemplateConfig | ConvertTo-Json -Depth 6 | Set-Content $script:cfgPath
        { Read-BmcConfig -Path $script:cfgPath } | Should -Throw '*placeholders*'
    }

    It 'rejects malformed JSON' {
        Set-Content $script:cfgPath '{ not json'
        { Read-BmcConfig -Path $script:cfgPath } | Should -Throw '*not valid JSON*'
    }

    It 'reports every problem at once' {
        $cfg = New-TestConfig
        $cfg.scenarios.Home.proxy = 'sometimes'
        $cfg.scenarios.Office.nexus = 'yes'
        $cfg.nexus.pypiIndexUrl = 'not a url'
        $cfg.detection.vpnAdapterPattern = '('
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:cfgPath
        $message = $null
        try { Read-BmcConfig -Path $script:cfgPath } catch { $message = $_.Exception.Message }
        $message | Should -Match 'scenarios.Home.proxy'
        $message | Should -Match 'scenarios.Office.nexus'
        $message | Should -Match 'nexus.pypiIndexUrl'
        $message | Should -Match 'vpnAdapterPattern'
    }

    It 'requires overrideUrl when a scenario uses override' {
        $cfg = New-TestConfig
        $cfg.scenarios.Vpn.proxy = 'override'
        $cfg.proxy.overrideUrl = ''
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:cfgPath
        { Read-BmcConfig -Path $script:cfgPath } | Should -Throw '*overrideUrl*'
    }

    It 'rejects unknown tool names' {
        $cfg = New-TestConfig
        $cfg | Add-Member -NotePropertyName tools -NotePropertyValue @('Git', 'Pip')
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:cfgPath
        { Read-BmcConfig -Path $script:cfgPath } | Should -Throw "*unknown entry 'Pip'*"
    }

    It 'reports a missing scenario' {
        $cfg = New-TestConfig
        $cfg.scenarios.PSObject.Properties.Remove('Vpn')
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $script:cfgPath
        { Read-BmcConfig -Path $script:cfgPath } | Should -Throw "*scenarios.Vpn*"
    }
}

Describe 'Write-BmcConfigTemplate' {
    It 'creates the template once and never overwrites it' {
        $path = Join-Path $TestDrive 'new\config.json'
        Write-BmcConfigTemplate -Path $path | Should -BeTrue
        Test-Path $path | Should -BeTrue
        Set-Content $path 'custom'
        Write-BmcConfigTemplate -Path $path -WarningAction SilentlyContinue | Should -BeFalse
        (Get-Content $path -Raw).Trim() | Should -Be 'custom'
    }
}

Describe 'Resolve-BmcScenario' {
    BeforeAll { $script:config = New-TestConfig }

    It 'detects Vpn when a matching adapter is up' {
        $nics = @((New-TestNic -Name 'Ethernet'), (New-TestNic -Name 'F5 VPN' -Description 'F5 Networks VPN Virtual Miniport'))
        (Resolve-BmcScenario -Interface $nics -Config $script:config).Scenario | Should -Be 'Vpn'
    }

    It 'matches the VPN pattern against the description as well as the name' {
        $nics = @((New-TestNic -Name 'Ethernet 3' -Description 'BIG-IP Edge Client Virtual Adapter'))
        (Resolve-BmcScenario -Interface $nics -Config $script:config).Scenario | Should -Be 'Vpn'
    }

    It 'ignores a VPN adapter that is down' {
        $nics = @((New-TestNic -Name 'F5 VPN' -IsUp $false))
        (Resolve-BmcScenario -Interface $nics -Config $script:config).Scenario | Should -Be 'Home'
    }

    It 'detects Office from the DNS suffix' {
        $nics = @((New-TestNic -DnsSuffix 'hq.corp.test'))
        $result = Resolve-BmcScenario -Interface $nics -Config $script:config
        $result.Scenario | Should -Be 'Office'
        $result.Reason | Should -Match 'hq.corp.test'
    }

    It 'prefers Vpn over Office when the VPN adapter also carries the corporate suffix' {
        $nics = @((New-TestNic -DnsSuffix 'corp.test'), (New-TestNic -Name 'F5 VPN' -DnsSuffix 'corp.test'))
        (Resolve-BmcScenario -Interface $nics -Config $script:config).Scenario | Should -Be 'Vpn'
    }

    It 'ignores the corporate suffix on an adapter that is down' {
        $nics = @((New-TestNic -DnsSuffix 'corp.test' -IsUp $false))
        (Resolve-BmcScenario -Interface $nics -Config $script:config).Scenario | Should -Be 'Home'
    }

    It 'falls back to Home' {
        $nics = @((New-TestNic -DnsSuffix 'lan'))
        (Resolve-BmcScenario -Interface $nics -Config $script:config).Scenario | Should -Be 'Home'
    }

    It 'falls back to Home when there are no adapters' {
        (Resolve-BmcScenario -Interface @() -Config $script:config).Scenario | Should -Be 'Home'
    }
}

Describe 'Resolve-BmcDesiredState' {
    BeforeAll { $script:config = New-TestConfig }

    It 'uses the proxy resolved by Windows in auto mode' {
        Mock Get-BmcSystemProxy { [uri]'http://proxy.corp.test:8080' }
        $state = Resolve-BmcDesiredState -Config $script:config -Scenario Office
        $state.ProxyUrl | Should -BeExactly 'http://proxy.corp.test:8080'
        $state.ProxyHostPort | Should -BeExactly 'proxy.corp.test:8080'
        $state.NoProxy | Should -Be 'localhost,.corp.test'
        $state.UseNexus | Should -BeTrue
        $state.PypiIndexUrl | Should -Match 'nexus.corp.test'
        Should -Invoke Get-BmcSystemProxy -Times 1 -ParameterFilter { $Uri -eq 'https://pypi.org' }
    }

    It 'warns and goes direct when auto mode resolves no proxy' {
        Mock Get-BmcSystemProxy { $null }
        Mock Get-BmcPacUrl { 'http://pac.corp.test/proxy.pac' }
        $state = Resolve-BmcDesiredState -Config $script:config -Scenario Vpn -WarningVariable warnings -WarningAction SilentlyContinue
        $state.ProxyUrl | Should -BeNullOrEmpty
        $state.NoProxy | Should -BeNullOrEmpty
        $warnings | Should -Not -BeNullOrEmpty
    }

    It 'never consults Windows in none mode and disables Nexus when configured' {
        Mock Get-BmcSystemProxy { throw 'must not be called' }
        $state = Resolve-BmcDesiredState -Config $script:config -Scenario Home
        $state.ProxyUrl | Should -BeNullOrEmpty
        $state.UseNexus | Should -BeFalse
        $state.PypiIndexUrl | Should -BeNullOrEmpty
        $state.NpmRegistryUrl | Should -BeNullOrEmpty
        Should -Invoke Get-BmcSystemProxy -Times 0
    }

    It 'uses proxy.overrideUrl in override mode' {
        Mock Get-BmcSystemProxy { throw 'must not be called' }
        $config = New-TestConfig
        $config.scenarios.Office.proxy = 'override'
        $state = Resolve-BmcDesiredState -Config $config -Scenario Office
        $state.ProxyUrl | Should -BeExactly 'http://127.0.0.1:3128'
        $state.ProxyMode | Should -Be 'override'
    }
}

Describe 'Providers' {
    BeforeAll { $script:paths = New-TestPaths }

    Context 'Git' {
        It 'embeds current-user credentials for an auto proxy' {
            $action = Get-BmcGitAction -State (New-TestState) -Config (New-TestConfig) -Paths $script:paths
            $action.Arguments.Desired | Should -BeExactly 'http://:@proxy.corp.test:8080'
        }
        It 'uses the plain URL when current-user credentials are disabled' {
            $config = New-TestConfig
            $config.git.useCurrentUserCredentials = $false
            (Get-BmcGitAction -State (New-TestState) -Config $config -Paths $script:paths).Arguments.Desired |
                Should -BeExactly 'http://proxy.corp.test:8080'
        }
        It 'uses the plain URL in override mode' {
            $state = New-TestState -Mode 'override' -ProxyUrl 'http://127.0.0.1:3128'
            (Get-BmcGitAction -State $state -Config (New-TestConfig) -Paths $script:paths).Arguments.Desired |
                Should -BeExactly 'http://127.0.0.1:3128'
        }
        It 'asks for the key to be unset when there is no proxy' {
            $state = New-TestState -Mode 'none' -ProxyUrl $null -Nexus $false
            (Get-BmcGitAction -State $state -Config (New-TestConfig) -Paths $script:paths).Arguments.Desired | Should -BeNullOrEmpty
        }
    }

    Context 'Scoop' {
        It 'delegates proxy selection and credentials to Windows in auto mode' {
            (Get-BmcScoopAction -State (New-TestState) -Config (New-TestConfig) -Paths $script:paths).Arguments.Desired |
                Should -BeExactly 'currentuser@default'
        }
        It 'uses host:port in override mode' {
            $state = New-TestState -Mode 'override' -ProxyUrl 'http://127.0.0.1:3128'
            $state.ProxyHostPort = '127.0.0.1:3128'
            (Get-BmcScoopAction -State $state -Config (New-TestConfig) -Paths $script:paths).Arguments.Desired |
                Should -BeExactly '127.0.0.1:3128'
        }
        It 'removes the proxy when there is none' {
            $state = New-TestState -Mode 'none' -ProxyUrl $null -Nexus $false
            (Get-BmcScoopAction -State $state -Config (New-TestConfig) -Paths $script:paths).Arguments.Desired | Should -BeNullOrEmpty
        }
    }

    Context 'Uv and Npm' {
        It 'writes the Nexus index for uv' {
            $action = Get-BmcUvAction -State (New-TestState) -Config (New-TestConfig) -Paths $script:paths
            $action.Arguments.Line | Should -Contain 'index-url = "https://nexus.corp.test/repository/pypi/simple"'
        }
        It 'writes nothing for uv without Nexus' {
            $state = New-TestState -Nexus $false
            @((Get-BmcUvAction -State $state -Config (New-TestConfig) -Paths $script:paths).Arguments.Line).Count | Should -Be 0
        }
        It 'writes registry and proxy lines for npm' {
            $lines = (Get-BmcNpmAction -State (New-TestState) -Config (New-TestConfig) -Paths $script:paths).Arguments.Line
            $lines | Should -Contain 'registry=https://nexus.corp.test/repository/npm/'
            $lines | Should -Contain 'proxy=http://proxy.corp.test:8080'
            $lines | Should -Contain 'https-proxy=http://proxy.corp.test:8080'
            $lines | Should -Contain 'noproxy=localhost,.corp.test'
        }
        It 'writes no proxy lines for npm when direct' {
            $state = New-TestState -Mode 'none' -ProxyUrl $null
            $lines = (Get-BmcNpmAction -State $state -Config (New-TestConfig) -Paths $script:paths).Arguments.Line
            $lines | Should -Not -Contain 'proxy=http://proxy.corp.test:8080'
            @($lines | Where-Object { $_ -like '*proxy*' }).Count | Should -Be 0
        }
    }

    Context 'Environment' {
        It 'emits one action per variable' {
            $actions = @(Get-BmcEnvironmentAction -State (New-TestState) -Config (New-TestConfig) -Paths $script:paths)
            $actions.Count | Should -Be 3
            ($actions | ForEach-Object { $_.Arguments.Name }) | Should -Be @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY')
        }
        It 'clears every variable when direct' {
            $state = New-TestState -Mode 'none' -ProxyUrl $null
            $actions = @(Get-BmcEnvironmentAction -State $state -Config (New-TestConfig) -Paths $script:paths)
            @($actions | Where-Object { $_.Arguments.Desired }).Count | Should -Be 0
        }
    }

    Context 'Action contract' {
        # Test and Apply receive the same argument table; both handlers must therefore bind every key.
        It 'binds every argument on both handlers (<tool>)' -TestCases @(
            @{ tool = 'Git'; provider = 'Get-BmcGitAction' }
            @{ tool = 'Scoop'; provider = 'Get-BmcScoopAction' }
            @{ tool = 'Uv'; provider = 'Get-BmcUvAction' }
            @{ tool = 'Npm'; provider = 'Get-BmcNpmAction' }
            @{ tool = 'Environment'; provider = 'Get-BmcEnvironmentAction' }
        ) {
            foreach ($action in @(& $provider -State (New-TestState) -Config (New-TestConfig) -Paths (New-TestPaths))) {
                foreach ($handler in $action.Test, $action.Apply) {
                    $accepted = (Get-Command $handler).Parameters.Keys
                    foreach ($key in $action.Arguments.Keys) { $accepted | Should -Contain $key }
                }
            }
        }
    }

    Context 'Get-BmcPlan' {
        BeforeAll {
            $script:state = New-TestState
            $script:planConfig = New-TestConfig
        }
        It 'includes every provider by default' {
            $tools = @(Get-BmcPlan -State $script:state -Config $script:planConfig -Paths $script:paths | ForEach-Object Tool | Select-Object -Unique)
            $tools | Should -Be @('Git', 'Scoop', 'Uv', 'Npm', 'Environment')
        }
        It 'honours -Tool' {
            $tools = @(Get-BmcPlan -State $script:state -Config $script:planConfig -Paths $script:paths -Tool 'Git', 'Npm' | ForEach-Object Tool | Select-Object -Unique)
            $tools | Should -Be @('Git', 'Npm')
        }
        It 'honours configuration.tools when -Tool is absent' {
            $config = New-TestConfig
            $config | Add-Member -NotePropertyName tools -NotePropertyValue @('Uv')
            $tools = @(Get-BmcPlan -State $script:state -Config $config -Paths $script:paths | ForEach-Object Tool | Select-Object -Unique)
            $tools | Should -Be @('Uv')
        }
        It 'lets -Tool override configuration.tools' {
            $config = New-TestConfig
            $config | Add-Member -NotePropertyName tools -NotePropertyValue @('Uv')
            $tools = @(Get-BmcPlan -State $script:state -Config $config -Paths $script:paths -Tool 'Git' | ForEach-Object Tool | Select-Object -Unique)
            $tools | Should -Be @('Git')
        }
    }
}

Describe 'Handlers' {
    Context 'Git' {
        It 'reads the current value' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 0; Output = @('http://p:1') } }
            Get-BmcGitValue -Key 'http.proxy' | Should -Be 'http://p:1'
        }
        It 'returns null when the key is absent' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 1; Output = @() } }
            Get-BmcGitValue -Key 'http.proxy' | Should -BeNullOrEmpty
        }
        It 'Test is true when absent and nothing is desired' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 1; Output = @() } }
            Test-BmcGitKey -Key 'http.proxy' -Desired $null | Should -BeTrue
        }
        It 'Test is false when the value differs' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 0; Output = @('http://old:1') } }
            Test-BmcGitKey -Key 'http.proxy' -Desired 'http://new:1' | Should -BeFalse
        }
        It 'sets a value' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
            Write-BmcGitKey -Key 'http.proxy' -Desired 'http://new:1'
            Should -Invoke Invoke-BmcNative -Times 1 -ParameterFilter { $FilePath -eq 'git' -and $ArgumentList -contains 'http://new:1' }
        }
        It 'unsets a value and tolerates exit code 5 (already absent)' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 5; Output = @() } }
            { Write-BmcGitKey -Key 'http.proxy' -Desired $null } | Should -Not -Throw
            Should -Invoke Invoke-BmcNative -Times 1 -ParameterFilter { $ArgumentList -contains '--unset' }
        }
        It 'throws when git fails' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 128; Output = @('fatal') } }
            { Write-BmcGitKey -Key 'http.proxy' -Desired 'x' } | Should -Throw '*failed*'
            { Write-BmcGitKey -Key 'http.proxy' -Desired $null } | Should -Throw '*failed*'
        }
    }

    Context 'Scoop' {
        BeforeEach {
            $script:scoopCfg = Join-Path $TestDrive 'scoop-config.json'
            Remove-Item -LiteralPath $script:scoopCfg -Force -ErrorAction SilentlyContinue
        }

        It 'Test is true when the file is missing and nothing is desired' {
            Test-BmcScoopProxy -ConfigPath $script:scoopCfg -Desired $null | Should -BeTrue
        }
        It 'Test compares the stored proxy value' {
            Set-Content $script:scoopCfg '{ "proxy": "currentuser@default", "other": 1 }'
            Test-BmcScoopProxy -ConfigPath $script:scoopCfg -Desired 'currentuser@default' | Should -BeTrue
            Test-BmcScoopProxy -ConfigPath $script:scoopCfg -Desired $null | Should -BeFalse
        }
        It 'Test treats an unreadable file as unset' {
            Set-Content $script:scoopCfg '{ broken'
            Test-BmcScoopProxy -ConfigPath $script:scoopCfg -Desired $null | Should -BeTrue
        }
        It 'sets and removes the proxy through the scoop CLI' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
            Write-BmcScoopProxy -Desired 'currentuser@default'
            Should -Invoke Invoke-BmcNative -Times 1 -ParameterFilter { $FilePath -eq 'scoop' -and ($ArgumentList -join ' ') -eq 'config proxy currentuser@default' }
            Write-BmcScoopProxy -Desired $null
            Should -Invoke Invoke-BmcNative -Times 1 -ParameterFilter { ($ArgumentList -join ' ') -eq 'config rm proxy' }
        }
        It 'throws when scoop fails' {
            Mock Invoke-BmcNative { [pscustomobject]@{ ExitCode = 1; Output = @('boom') } }
            { Write-BmcScoopProxy -Desired 'x' } | Should -Throw '*scoop config failed*'
        }
    }

    Context 'Managed files' {
        BeforeEach { $script:file = Join-Path $TestDrive ('f{0}\conf.toml' -f (Get-Random)) }

        It 'creates the file (and its directory) and then reports it as current' {
            Test-BmcManagedFile -Path $script:file -Line @('a = 1') | Should -BeFalse
            Write-BmcManagedFile -Path $script:file -Line @('a = 1')
            Test-BmcManagedFile -Path $script:file -Line @('a = 1') | Should -BeTrue
        }
        It 'writes UTF-8 without a BOM' {
            Write-BmcManagedFile -Path $script:file -Line @('a = 1')
            $bytes = [System.IO.File]::ReadAllBytes($script:file)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        }
        It 'preserves user content on update and on removal' {
            Write-BmcTextFile -Path $script:file -Text "[tool]`r`nx = 1`r`n"
            Write-BmcManagedFile -Path $script:file -Line @('a = 1')
            (Read-BmcTextFile -Path $script:file) | Should -Match '\[tool\]'
            Write-BmcManagedFile -Path $script:file -Line @()
            (Read-BmcTextFile -Path $script:file) | Should -BeExactly "[tool]`r`nx = 1`r`n"
        }
        It 'is current when nothing is desired and the file does not exist' {
            Test-BmcManagedFile -Path $script:file -Line @() | Should -BeTrue
        }
        It 'reads a missing file as empty text' {
            Read-BmcTextFile -Path (Join-Path $TestDrive 'absent.txt') | Should -BeExactly ''
        }
        It 'reads an empty file as empty text' {
            New-Item -ItemType File -Path $script:file -Force | Out-Null
            Read-BmcTextFile -Path $script:file | Should -BeExactly ''
        }
    }

    Context 'User environment' {
        It 'Test compares against the stored user value' {
            Mock Get-BmcUserEnv { 'http://p:1' }
            Test-BmcUserEnv -Name 'HTTP_PROXY' -Desired 'http://p:1' | Should -BeTrue
            Test-BmcUserEnv -Name 'HTTP_PROXY' -Desired 'http://q:1' | Should -BeFalse
        }
        It 'Test is true when absent and nothing is desired' {
            Mock Get-BmcUserEnv { $null }
            Test-BmcUserEnv -Name 'HTTP_PROXY' -Desired $null | Should -BeTrue
        }
    }
}

Describe 'Invoke-BmcAction' {
    BeforeEach {
        Mock Test-BmcCommand { $true }
        $script:action = New-BmcAction -Tool 'Git' -Description 'demo' -Requires 'git' -Test 'Test-BmcGitKey' -Apply 'Write-BmcGitKey' `
            -Arguments @{ Key = 'http.proxy'; Desired = 'x' }
    }

    It 'skips when the required command is missing' {
        Mock Test-BmcCommand { $false }
        Mock Test-BmcGitKey { $false }
        Mock Write-BmcGitKey { }
        $result = Invoke-BmcAction -Action $script:action
        $result.Status | Should -Be 'Skipped'
        Should -Invoke Write-BmcGitKey -Times 0
    }

    It 'reports Unchanged and does not write when already converged' {
        Mock Test-BmcGitKey { $true }
        Mock Write-BmcGitKey { }
        (Invoke-BmcAction -Action $script:action).Status | Should -Be 'Unchanged'
        Should -Invoke Write-BmcGitKey -Times 0
    }

    It 'applies and verifies when drifting' {
        $script:checks = 0
        Mock Test-BmcGitKey { $script:checks++; $script:checks -gt 1 }
        Mock Write-BmcGitKey { }
        (Invoke-BmcAction -Action $script:action -Confirm:$false).Status | Should -Be 'Changed'
        Should -Invoke Write-BmcGitKey -Times 1
    }

    It 'does not write under -WhatIf' {
        Mock Test-BmcGitKey { $false }
        Mock Write-BmcGitKey { }
        (Invoke-BmcAction -Action $script:action -WhatIf).Status | Should -Be 'WouldChange'
        Should -Invoke Write-BmcGitKey -Times 0
    }

    It 'reports Failed when the handler throws, without propagating' {
        Mock Test-BmcGitKey { $false }
        Mock Write-BmcGitKey { throw 'disk on fire' }
        $result = Invoke-BmcAction -Action $script:action -Confirm:$false
        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -Match 'disk on fire'
    }

    It 'reports Failed when the state does not converge after applying' {
        Mock Test-BmcGitKey { $false }
        Mock Write-BmcGitKey { }
        $result = Invoke-BmcAction -Action $script:action -Confirm:$false
        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -Match 'did not converge'
    }
}

Describe 'Get-BmcPath' {
    It 'derives every location from the profile environment' {
        $saved = @{ A = $env:APPDATA; U = $env:USERPROFILE; X = $env:XDG_CONFIG_HOME }
        try {
            $env:APPDATA = Join-Path $TestDrive 'AppData'
            $env:USERPROFILE = Join-Path $TestDrive 'User'
            $env:XDG_CONFIG_HOME = $null
            $paths = Get-BmcPath
            $paths.Config | Should -BeLike '*AppData*bmc*config.json'
            $paths.UvConfig | Should -BeLike '*AppData*uv*uv.toml'
            $paths.NpmRc | Should -BeLike '*User*.npmrc'
            $paths.ScoopConfig | Should -BeLike '*User*.config*scoop*config.json'
            $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
            (Get-BmcPath).ScoopConfig | Should -BeLike '*xdg*scoop*config.json'
        }
        finally {
            $env:APPDATA = $saved.A; $env:USERPROFILE = $saved.U; $env:XDG_CONFIG_HOME = $saved.X
        }
    }
}

Describe 'Invoke-BmcNative' -Skip:($env:OS -ne 'Windows_NT') {
    It 'returns the exit code and output of a real program' {
        $result = Invoke-BmcNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo hello & exit 3')
        $result.ExitCode | Should -Be 3
        ($result.Output -join '') | Should -Match 'hello'
    }
    It 'does not throw on stderr output under ErrorActionPreference Stop' {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try { { Invoke-BmcNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo oops 1>&2') } | Should -Not -Throw }
        finally { $ErrorActionPreference = $previous }
    }
}

Describe 'Invoke-BmcMain (end to end, adapters faked)' {
    BeforeEach {
        $script:FakeGit = @{}
        $script:FakeEnv = @{}
        $script:FakeScoopConfig = Join-Path $TestDrive 'scoop\config.json'
        $script:Nics = @(New-TestNic -DnsSuffix 'corp.test')
        $script:Proxy = [uri]'http://proxy.corp.test:8080'

        foreach ($leftover in 'appdata', 'home', 'scoop') {
            Remove-Item -LiteralPath (Join-Path $TestDrive $leftover) -Recurse -Force -ErrorAction SilentlyContinue
        }
        $paths = New-TestPaths
        $script:E2EPaths = $paths
        New-TestConfig | ConvertTo-Json -Depth 6 | Set-Content $paths.Config

        Mock Get-BmcPath { $script:E2EPaths }
        Mock Get-BmcNetworkInterface { $script:Nics }
        Mock Get-BmcSystemProxy { $script:Proxy }
        Mock Get-BmcPacUrl { 'http://pac.corp.test/proxy.pac' }
        Mock Test-BmcCommand { $true }
        Mock Invoke-BmcNative { Invoke-FakeNative -FilePath $FilePath -ArgumentList $ArgumentList }
        Mock Get-BmcUserEnv { $script:FakeEnv[$Name] }
        Mock Write-BmcUserEnv { if ($Desired) { $script:FakeEnv[$Name] = $Desired } else { $script:FakeEnv.Remove($Name) } }
    }

    It 'DetectOnly reports the scenario and changes nothing' {
        $result = Invoke-BmcMain -DetectOnly
        $result.Scenario | Should -Be 'Office'
        Should -Invoke Invoke-BmcNative -Times 0
        Should -Invoke Write-BmcUserEnv -Times 0
    }

    It 'honours a forced scenario without probing the network' {
        (Invoke-BmcMain -Scenario Home -DetectOnly).Reason | Should -Match 'forced'
        Should -Invoke Get-BmcNetworkInterface -Times 0
    }

    It 'converges every tool for the office and is idempotent on the second run' {
        $first = @(Invoke-BmcMain -Confirm:$false)
        @($first | Where-Object Status -eq 'Failed') | Should -BeNullOrEmpty
        @($first | Where-Object Status -eq 'Changed').Count | Should -Be 7

        $script:FakeGit['http.proxy'] | Should -BeExactly 'http://:@proxy.corp.test:8080'
        (Get-Content $script:FakeScoopConfig -Raw) | Should -Match 'currentuser@default'
        (Get-Content $script:E2EPaths.UvConfig -Raw) | Should -Match 'index-url'
        (Get-Content $script:E2EPaths.NpmRc -Raw) | Should -Match 'https-proxy=http://proxy.corp.test:8080'
        $script:FakeEnv['HTTPS_PROXY'] | Should -BeExactly 'http://proxy.corp.test:8080'

        $second = @(Invoke-BmcMain -Confirm:$false)
        @($second | Where-Object Status -eq 'Unchanged').Count | Should -Be 7
    }

    It 'reverts everything when the machine moves to the home network' {
        $null = Invoke-BmcMain -Confirm:$false
        $script:Nics = @(New-TestNic -Name 'Wi-Fi' -DnsSuffix 'lan')

        $results = @(Invoke-BmcMain -Confirm:$false)
        @($results | Where-Object Status -eq 'Failed') | Should -BeNullOrEmpty
        $script:FakeGit.ContainsKey('http.proxy') | Should -BeFalse
        $script:FakeEnv.Count | Should -Be 0
        [string](Get-Content $script:E2EPaths.NpmRc -Raw) | Should -Not -Match 'proxy'
        [string](Get-Content $script:E2EPaths.UvConfig -Raw) | Should -Not -Match 'index-url'
        (Get-Content $script:FakeScoopConfig -Raw) | Should -Not -Match 'currentuser'
    }

    It 'does not change anything under -WhatIf' {
        $results = @(Invoke-BmcMain -WhatIf)
        @($results | Where-Object Status -eq 'WouldChange').Count | Should -Be 7
        Test-Path $script:E2EPaths.UvConfig | Should -BeFalse
        $script:FakeGit.Count | Should -Be 0
    }

    It 'limits the run with -Tool' {
        $results = @(Invoke-BmcMain -Tool 'Uv' -Confirm:$false)
        $results.Count | Should -Be 1
        $results[0].Tool | Should -Be 'Uv'
    }

    It 'isolates failures: one broken tool does not stop the others' {
        Mock Invoke-BmcNative { if ($FilePath -eq 'git') { [pscustomobject]@{ ExitCode = 128; Output = @('fatal') } } else { Invoke-FakeNative -FilePath $FilePath -ArgumentList $ArgumentList } }
        $results = @(Invoke-BmcMain -Confirm:$false)
        ($results | Where-Object Tool -eq 'Git').Status | Should -Be 'Failed'
        @($results | Where-Object Status -eq 'Changed').Count | Should -Be 6
    }

    It 'skips tools that are not installed' {
        Mock Test-BmcCommand { $Name -ne 'uv' }
        $results = @(Invoke-BmcMain -Confirm:$false)
        ($results | Where-Object Tool -eq 'Uv').Status | Should -Be 'Skipped'
    }

    It 'InitConfig writes the template once' {
        $path = Join-Path $TestDrive 'init\config.json'
        (Invoke-BmcMain -InitConfig -ConfigPath $path).Status | Should -Be 'Created'
        (Invoke-BmcMain -InitConfig -ConfigPath $path -WarningAction SilentlyContinue).Status | Should -Be 'Exists'
    }

    It 'fails clearly when the configuration is missing' {
        { Invoke-BmcMain -ConfigPath (Join-Path $TestDrive 'missing.json') } | Should -Throw '*-InitConfig*'
    }
}
