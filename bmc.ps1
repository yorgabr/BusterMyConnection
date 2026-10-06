#Requires -Version 5.1

<#
.SYNOPSIS
    BusterMyConnection (bmc) - Self-healing Px Proxy orchestrator for Windows.

.DESCRIPTION
    BusterMyConnection (bmc) is an orchestration layer designed to absorb corporate network instability on Windows environments.
    Instead of relying on rigid NTLM credentials or legacy proxy helpers like CNTLM, bmc integrates with Px Proxy—a modern HTTP proxy with automatic Windows Single Sign-On (SSO), Kerberos, NTLM, and PAC file evaluation support.

    Core Capabilities & Architecture:
    1. Registry-based PAC Discovery.
    2. Upstream health checks & endpoint validation.
    3. Automated scoop provisioning.
    4. Zero-config command line execution.
    5. Graceful fallback (direct access mode).
    6. State persistence & environmental symmetry.
    7. Scenario-aware tool reconfiguration (Scoop, Git, npm, uv) and Nexus mirror selection.

.PARAMETER JustCheck
    Executes in read-only diagnostic mode.

.PARAMETER DotSourceOnly
    Exits execution immediately after loading function definitions into session scope.
    Used for unit testing with Pester.

.PARAMETER Port
    Specifies the local listening port for Px Proxy. Default is 3128.

.PARAMETER SkipToolCheck
    Skips the post-configuration access check of Git, Scoop, npm and uv.

.PARAMETER ConfigPath
    Path to the bmc JSON configuration file. Defaults to %LOCALAPPDATA%\bmc\bmc.config.json.
    When absent, the built-in template config (Get-BmcTemplateConfig) is used.

.EXAMPLE
    bmc

.EXAMPLE
    bmc -JustCheck
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch] $JustCheck,
    [switch] $DotSourceOnly,
    [int] $Port = 3128,
    [string] $ConfigPath,
    [switch] $SkipToolCheck
)

# Global Constants & Paths
$SCRIPT_VERSION = '2.1.0'
$BmcAppDataPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'bmc'
$StateFilePath   = Join-Path -Path $BmcAppDataPath -ChildPath 'state.json'
$ConfigFilePath  = Join-Path -Path $BmcAppDataPath -ChildPath 'bmc.config.json'
$RegSettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# Console Logging Output Helpers
function Out-Info {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string] $Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Out-Warn {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string] $Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Out-Err {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string] $Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Out-Succ {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string] $Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

# Configuration Template Provider
function Get-BmcTemplateConfig {
    <#
    .SYNOPSIS
        Returns the canonical configuration template as an ordered hashtable, consumed by the build
        pipeline to emit bmc.config.sample.json.
    .DESCRIPTION
        Uses [ordered] to guarantee deterministic key ordering in the serialized JSON artifact.
    #>
    return [ordered]@{
        detection = [ordered]@{
            vpnAdapterPattern      = 'F5|BIG-IP'
            officeDnsSuffixPattern = '(^|\.)corp\.example\.com$'
            pacProbe               = $true
        }
        scenarios = [ordered]@{
            Office = [ordered]@{ proxy = 'auto'; nexus = $true }
            Vpn    = [ordered]@{ proxy = 'auto'; nexus = $true }
            Home   = [ordered]@{ proxy = 'none'; nexus = $false }
        }
        proxy = [ordered]@{
            overrideUrl = 'http://127.0.0.1:3128'
            noProxy     = 'localhost,127.0.0.1,.corp.example.com'
            probeUrl    = 'https://pypi.org'
        }
        nexus = [ordered]@{
            pypiIndexUrl   = 'https://nexus.corp.example.com/repository/pypi-group/simple'
            npmRegistryUrl = 'https://nexus.corp.example.com/repository/npm-group/'
        }
        git = [ordered]@{
            useCurrentUserCredentials = $true
        }
        probes = [ordered]@{
            git   = 'https://github.com/octocat/Hello-World.git'
            scoop = 'https://github.com'
        }
        tools = @('Git', 'Scoop', 'Uv', 'Npm', 'Environment')
    }
}

# Configuration Loader
function Get-BmcConfig {
    <#
    .SYNOPSIS
        Loads the bmc JSON configuration file, falling back to the built-in template when the file
        is absent or unreadable. Always returns a PSCustomObject with the canonical topology.
    #>
    param(
        [string] $Path = $ConfigFilePath
    )

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            return ($raw | ConvertFrom-Json)
        }
        catch {
            Out-Warn "Failed to parse config file ($Path): $_. Falling back to built-in template."
        }
    }

    # Normalize the ordered hashtable template into a PSCustomObject for uniform property access.
    return (Get-BmcTemplateConfig | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

# Scenario Detection (Office / Vpn / Home)
function Get-BmcScenario {
    <#
    .SYNOPSIS
        Determines the active network scenario using the detection patterns in the config:
        - 'Vpn'    when an active network adapter matches detection.vpnAdapterPattern.
        - 'Office' when a connection-specific DNS suffix matches detection.officeDnsSuffixPattern.
        - 'Office' when no pattern matched but the corporate PAC endpoint (from the registry) is
          reachable without any proxy: that server is only reachable from inside the corporate
          network, so reaching it is strong evidence of being on it. Disable it with
          detection.pacProbe = false.
        - 'Home'   otherwise.
    .PARAMETER PacUrl
        PAC URL found in the registry. Optional; enables the reachability-based Office detection.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [string] $PacUrl
    )

    $vpnPattern    = $Config.detection.vpnAdapterPattern
    $officePattern = $Config.detection.officeDnsSuffixPattern

    # 1. VPN detection: inspect active adapter interface descriptions.
    if ($vpnPattern) {
        try {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                if ($adapter.InterfaceDescription -match $vpnPattern -or $adapter.Name -match $vpnPattern) {
                    return 'Vpn'
                }
            }
        }
        catch {
            Out-Warn "VPN adapter detection failed: $_"
        }
    }

    # 2. Office detection: inspect connection-specific DNS suffixes.
    if ($officePattern) {
        if ($officePattern -match 'example') {
            Out-Warn "detection.officeDnsSuffixPattern still holds the template placeholder ($officePattern); it cannot match your network. Set the real DNS suffix in your bmc config."
        }
        try {
            $suffixes = (Get-DnsClient -ErrorAction SilentlyContinue).ConnectionSpecificSuffix |
                Where-Object { $_ }
            foreach ($suffix in $suffixes) {
                if ($suffix -match $officePattern) {
                    return 'Office'
                }
            }
        }
        catch {
            Out-Warn "Office DNS suffix detection failed: $_"
        }
    }

    # 3. Office detection by PAC reachability (works even when no DNS suffix pattern is configured).
    if ($PacUrl -and ($Config.detection.pacProbe -ne $false)) {
        if (Test-BmcPacEndpoint -PacUrl $PacUrl -TimeoutSeconds 3) {
            Out-Info "Corporate PAC endpoint is reachable without proxy: assuming the corporate network."
            return 'Office'
        }
    }

    return 'Home'
}

# Native CLI Invocation Wrapper
function Invoke-BmcCli {
    <#
    .SYNOPSIS
        Single seam for every external CLI call (scoop, git, npm). Returns the process exit code.
    .DESCRIPTION
        Keeping native calls in one function makes them reliably mockable in Pester (mocking
        executables and shims directly let the real scoop/git run during the test suite).

        Windows PowerShell 5.1 detail: with 2>&1 the native stderr lines become ErrorRecord
        objects, and $ErrorActionPreference = 'Stop' turns the first one into a terminating
        error even when the tool succeeded. Output is therefore consumed under 'Continue' and
        the exit code is the single source of truth.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $Tool,

        [string[]] $Arguments = @()
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $Tool @Arguments 2>&1
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

# Nexus Index Reconfiguration (pip/uv + npm registries)
function Set-BmcNexusConfig {
    <#
    .SYNOPSIS
        Points package managers at the corporate Nexus mirrors (enabled) or restores defaults
        (disabled), driven by the per-scenario 'nexus' boolean and the 'nexus' index URLs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [bool] $Enabled
    )

    $pypiIndex = $Config.nexus.pypiIndexUrl
    $npmReg    = $Config.nexus.npmRegistryUrl

    # --- uv / pip (via UV_INDEX_URL / PIP_INDEX_URL process variables) ---
    if ($Enabled -and $pypiIndex) {
        [Environment]::SetEnvironmentVariable('UV_INDEX_URL', $pypiIndex, 'Process')
        [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $pypiIndex, 'Process')
        Out-Info "Nexus PyPI index set to: $pypiIndex"
    } else {
        [Environment]::SetEnvironmentVariable('UV_INDEX_URL', $null, 'Process')
        [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $null, 'Process')
        Out-Info "Nexus PyPI index cleared (using defaults)."
    }

    # --- npm registry ---
    if (Get-Command -Name 'npm' -ErrorAction SilentlyContinue) {
        try {
            if ($Enabled -and $npmReg) {
                $exitCode = Invoke-BmcCli -Tool 'npm' -Arguments @('config', 'set', 'registry', $npmReg)
                if ($exitCode -ne 0) {
                    Out-Warn "npm exited with code $exitCode while setting the registry."
                } else {
                    Out-Info "Nexus npm registry set to: $npmReg"
                }
            } else {
                # Exit code intentionally ignored: deleting an unset key is not an error.
                $null = Invoke-BmcCli -Tool 'npm' -Arguments @('config', 'delete', 'registry')
                Out-Info "Nexus npm registry cleared (using defaults)."
            }
        }
        catch {
            Out-Warn "Failed to reconfigure npm registry: $_"
        }
    }
}

# Tool-Specific Proxy Reconfiguration
function Set-BmcToolProxy {
    <#
    .SYNOPSIS
        Reconfigures external tools (Scoop, Git, npm, uv) to use the local Px proxy, or clears them
        when in Direct Access. POSIX environment variables alone are insufficient: each tool has its
        own proxy configuration mechanism.
    .PARAMETER ProxyUrl
        Local proxy URL (e.g. http://127.0.0.1:3128). Pass $null/'' to clear (Direct Access).
    .PARAMETER UseCurrentUserCredentials
        When set, Git credential handling is left to the current Windows user; no proxy credentials
        are embedded in the Git config (Px handles SSO upstream).
    #>
    param(
        [string] $ProxyUrl,
        [bool] $UseCurrentUserCredentials = $true
    )

    $isDirect = [string]::IsNullOrWhiteSpace($ProxyUrl)

    # --- Scoop ---
    if (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue) {
        try {
            if ($isDirect) {
                # Exit code intentionally ignored: removing an unset key is not an error.
                $null = Invoke-BmcCli -Tool 'scoop' -Arguments @('config', 'rm', 'proxy')
                Out-Info "Scoop proxy configuration cleared (Direct Access)."
            } else {
                # Scoop expects host:port (no scheme). Strip the http(s):// prefix.
                $scoopProxy = $ProxyUrl -replace '^https?://', ''
                $exitCode = Invoke-BmcCli -Tool 'scoop' -Arguments @('config', 'proxy', $scoopProxy)
                if ($exitCode -ne 0) {
                    Out-Warn "Scoop exited with code $exitCode while setting the proxy."
                } else {
                    Out-Info "Scoop proxy set to: $scoopProxy"
                }
            }
        }
        catch {
            Out-Warn "Failed to reconfigure Scoop proxy: $_"
        }
    }

    # --- Git ---
    if (Get-Command -Name 'git' -ErrorAction SilentlyContinue) {
        try {
            # Git only honours http.proxy (it applies to https:// remotes too); 'https.proxy' is not
            # a Git setting. Always drop it so entries written by earlier bmc versions are cleaned up.
            # Exit codes of --unset are ignored: Git returns 5 when the key does not exist.
            $null = Invoke-BmcCli -Tool 'git' -Arguments @('config', '--global', '--unset', 'https.proxy')
            if ($isDirect) {
                $null = Invoke-BmcCli -Tool 'git' -Arguments @('config', '--global', '--unset', 'http.proxy')
                Out-Info "Git proxy configuration cleared (Direct Access)."
            } else {
                $exitCode = Invoke-BmcCli -Tool 'git' -Arguments @('config', '--global', 'http.proxy', $ProxyUrl)
                if ($UseCurrentUserCredentials) {
                    # Px performs SSO upstream; ensure no stale embedded proxy credentials remain.
                    $null = Invoke-BmcCli -Tool 'git' -Arguments @('config', '--global', '--unset', 'http.proxyAuthMethod')
                }
                if ($exitCode -ne 0) {
                    Out-Warn "Git exited with code $exitCode while setting the proxy."
                } else {
                    Out-Info "Git proxy set to: $ProxyUrl"
                }
            }
        }
        catch {
            Out-Warn "Failed to reconfigure Git proxy: $_"
        }
    }

    # --- npm ---
    if (Get-Command -Name 'npm' -ErrorAction SilentlyContinue) {
        try {
            if ($isDirect) {
                $null = Invoke-BmcCli -Tool 'npm' -Arguments @('config', 'delete', 'proxy')
                $null = Invoke-BmcCli -Tool 'npm' -Arguments @('config', 'delete', 'https-proxy')
                Out-Info "npm proxy configuration cleared (Direct Access)."
            } else {
                $exitCode = Invoke-BmcCli -Tool 'npm' -Arguments @('config', 'set', 'proxy', $ProxyUrl)
                if ($exitCode -eq 0) {
                    $exitCode = Invoke-BmcCli -Tool 'npm' -Arguments @('config', 'set', 'https-proxy', $ProxyUrl)
                }
                if ($exitCode -ne 0) {
                    Out-Warn "npm exited with code $exitCode while setting the proxy."
                } else {
                    Out-Info "npm proxy set to: $ProxyUrl"
                }
            }
        }
        catch {
            Out-Warn "Failed to reconfigure npm proxy: $_"
        }
    }

    # --- uv (relies on HTTP_PROXY/HTTPS_PROXY process variables, managed elsewhere) ---
    if (Get-Command -Name 'uv' -ErrorAction SilentlyContinue) {
        if ($isDirect) {
            Out-Info "uv relies on process proxy variables; cleared via Direct Access."
        } else {
            Out-Info "uv relies on process proxy variables; set to: $ProxyUrl"
        }
    }
}

# Windows Registry PAC Discovery
function Get-BmcPacUrlFromRegistry {
    <#
    .SYNOPSIS
        Retrieves the corporate PAC file URL from Windows Internet Settings registry key.
    #>
    try {
        if (Test-Path -Path $RegSettingsKey) {
            $regProps = Get-ItemProperty -Path $RegSettingsKey -ErrorAction Stop
            if ($regProps.AutoConfigURL) {
                return $regProps.AutoConfigURL.Trim()
            }
        }
    }
    catch {
        Out-Warn "Failed to read Windows Registry ($RegSettingsKey): $_"
    }
    return $null
}

# Scoop & Px Proxy Binary Provisioning
function Get-BmcPxBinaryPath {
    <#
    .SYNOPSIS
        Locates px.exe in PATH or Scoop directories.
    #>
    $pxCommand = Get-Command -Name 'px.exe' -ErrorAction SilentlyContinue
    if ($pxCommand) {
        return $pxCommand.Source
    }

    $scoopPx = Join-Path -Path $env:USERPROFILE -ChildPath 'scoop\apps\px\current\px.exe'
    if (Test-Path -LiteralPath $scoopPx) {
        return $scoopPx
    }

    return $null
}

function Install-BmcPxProxy {
    <#
    .SYNOPSIS
        Installs Px Proxy using Scoop if not already available.
    #>
    $existingPath = Get-BmcPxBinaryPath
    if ($existingPath) {
        Out-Info "Px Proxy located at: $existingPath"
        return $existingPath
    }

    Out-Info "Px Proxy not found on system. Attempting installation via Scoop..."

    $scoopCmd = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue
    if (-not $scoopCmd) {
        throw "Scoop was not found in PATH. Install Scoop first to enable automated Px Proxy provisioning."
    }

    $process = Start-Process -FilePath 'scoop' -ArgumentList 'install', 'px' -Wait -NoNewWindow -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Failed to install Px Proxy via Scoop (Exit Code: $($process.ExitCode))."
    }

    $newPath = Get-BmcPxBinaryPath
    if (-not $newPath) {
        throw "Px Proxy was installed via Scoop, but the px.exe executable was not found."
    }

    Out-Succ "Px Proxy successfully installed via Scoop at: $newPath"
    return $newPath
}

# Health Checks
function Test-BmcHttpAccess {
    <#
    .SYNOPSIS
        HEAD request that reports whether a URL answers, optionally through a proxy.
    .DESCRIPTION
        Any HTTP answer counts as network reachability (a server that replies 404/405 to HEAD is
        reachable), except 407 and 502/503/504, which indicate a proxy or upstream failure.
        Without -ProxyUrl the request goes direct (no system/PAC proxy), so it measures what the
        local network itself can reach. Returns Success, Detail and ElapsedMs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [string] $ProxyUrl,

        [int] $TimeoutSeconds = 10
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $success = $false
    $detail  = ''

    try {
        # .NET Framework behind Windows PowerShell 5.1 may default to legacy TLS versions.
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        $request = [System.Net.WebRequest]::Create($Url)
        $request.Timeout = $TimeoutSeconds * 1000
        $request.Method = 'HEAD'
        if ($ProxyUrl) {
            $webProxy = New-Object System.Net.WebProxy($ProxyUrl, $false)
            $webProxy.UseDefaultCredentials = $true
            $request.Proxy = $webProxy
        } else {
            $request.Proxy = $null
        }

        $response = $request.GetResponse()
        $detail = "HTTP $([int]$response.StatusCode)"
        $response.Close()
        $success = $true
    }
    catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
        if ($webResponse) {
            $statusCode = [int]$webResponse.StatusCode
            $webResponse.Close()
            if ($statusCode -in 407, 502, 503, 504) {
                $detail = "HTTP $statusCode (proxy or upstream failure)"
            } else {
                $success = $true
                $detail = "HTTP $statusCode"
            }
        } else {
            $detail = $_.Exception.Message
        }
    }
    catch {
        $detail = $_.Exception.Message
    }

    $stopwatch.Stop()
    return [PSCustomObject]@{
        Success   = $success
        Detail    = $detail
        ElapsedMs = $stopwatch.ElapsedMilliseconds
    }
}

function Test-BmcPacEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PacUrl,

        [int] $TimeoutSeconds = 5
    )

    return [bool](Test-BmcHttpAccess -Url $PacUrl -TimeoutSeconds $TimeoutSeconds).Success
}

function Test-BmcToolAccess {
    <#
    .SYNOPSIS
        Verifies, after the environment was configured for the scenario, that each tool can really
        reach its network target. Reports per tool and returns the result objects.
    .DESCRIPTION
        - Git : git ls-remote against probes.git (uses the global http.proxy just configured).
        - npm : npm ping against the active registry (Nexus when enabled, public otherwise).
        - uv  : HTTP probe of the active PyPI index. uv has no ping command; it honours the
                HTTP(S)_PROXY process variables, which the probe reproduces with -ProxyUrl.
        - Scoop: HTTP probe of probes.scoop through the same proxy Scoop is configured with
                (Scoop has no connectivity command and `scoop update` would change state).
        Read-only: nothing is installed or modified.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [string] $ProxyUrl,

        [bool] $NexusEnabled = $false,

        [int] $TimeoutSeconds = 15
    )

    $route = if ($ProxyUrl) { "via $ProxyUrl" } else { 'direct' }

    $pypiTarget = if ($Config.proxy.probeUrl) { $Config.proxy.probeUrl } else { 'https://pypi.org' }
    $npmTarget  = 'https://registry.npmjs.org/'
    if ($NexusEnabled) {
        if ($Config.nexus.pypiIndexUrl)   { $pypiTarget = $Config.nexus.pypiIndexUrl }
        if ($Config.nexus.npmRegistryUrl) { $npmTarget  = $Config.nexus.npmRegistryUrl }
    }
    $gitTarget   = if ($Config.probes.git)   { $Config.probes.git }   else { 'https://github.com/octocat/Hello-World.git' }
    $scoopTarget = if ($Config.probes.scoop) { $Config.probes.scoop } else { 'https://github.com' }

    $newResult = {
        param($Tool, $Target, $Success, $Detail, $ElapsedMs)
        [PSCustomObject]@{ Tool = $Tool; Target = $Target; Success = [bool]$Success; Detail = $Detail; ElapsedMs = $ElapsedMs }
    }
    $results = New-Object System.Collections.Generic.List[object]

    Out-Info "Checking tool access ($route)..."

    # --- Git ---
    if (Get-Command -Name 'git' -ErrorAction SilentlyContinue) {
        $previousPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'   # never block waiting for credentials
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $exitCode = Invoke-BmcCli -Tool 'git' -Arguments @(
                '-c', 'http.lowSpeedLimit=1', '-c', "http.lowSpeedTime=$TimeoutSeconds",
                'ls-remote', '--exit-code', $gitTarget, 'HEAD')
            $detail = "exit code $exitCode"
        }
        catch {
            $exitCode = -1
            $detail = "$_"
        }
        finally {
            $env:GIT_TERMINAL_PROMPT = $previousPrompt
        }
        $results.Add((& $newResult 'Git' $gitTarget ($exitCode -eq 0) $detail $stopwatch.ElapsedMilliseconds))
    }

    # --- npm ---
    if (Get-Command -Name 'npm' -ErrorAction SilentlyContinue) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $exitCode = Invoke-BmcCli -Tool 'npm' -Arguments @(
                'ping', '--registry', $npmTarget, '--fetch-retries=0', "--fetch-timeout=$($TimeoutSeconds * 1000)")
            $detail = "exit code $exitCode"
        }
        catch {
            $exitCode = -1
            $detail = "$_"
        }
        $results.Add((& $newResult 'npm' $npmTarget ($exitCode -eq 0) $detail $stopwatch.ElapsedMilliseconds))
    }

    # --- uv ---
    if (Get-Command -Name 'uv' -ErrorAction SilentlyContinue) {
        $probe = Test-BmcHttpAccess -Url $pypiTarget -ProxyUrl $ProxyUrl -TimeoutSeconds $TimeoutSeconds
        $results.Add((& $newResult 'uv' $pypiTarget $probe.Success "$($probe.Detail) [HTTP probe]" $probe.ElapsedMs))
    }

    # --- Scoop ---
    if (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue) {
        $probe = Test-BmcHttpAccess -Url $scoopTarget -ProxyUrl $ProxyUrl -TimeoutSeconds $TimeoutSeconds
        $results.Add((& $newResult 'Scoop' $scoopTarget $probe.Success "$($probe.Detail) [HTTP probe]" $probe.ElapsedMs))
    }

    foreach ($result in $results) {
        $line = "{0,-5} {1} - {2} ({3} ms)" -f $result.Tool, $result.Target, $result.Detail, $result.ElapsedMs
        if ($result.Success) { Out-Succ $line } else { Out-Warn $line }
    }

    $failed = @($results | Where-Object { -not $_.Success })
    if ($results.Count -eq 0) {
        Out-Warn "No supported tool (git, npm, uv, scoop) found to check."
    } elseif ($failed.Count -eq 0) {
        Out-Succ "All $($results.Count) tool(s) can reach their targets ($route)."
    } else {
        Out-Warn "$($failed.Count) of $($results.Count) tool(s) cannot reach their targets ($route): $(($failed | ForEach-Object { $_.Tool }) -join ', ')."
    }

    return $results.ToArray()
}

function Get-BmcNetworkEvidence {
    <#
    .SYNOPSIS
        Lists the signals the scenario detection looks at (active adapters, DNS suffixes), so the
        detection patterns in the bmc config can be written from real data.
    #>
    $adapters = @()
    $suffixes = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' } |
            ForEach-Object { '{0} ({1})' -f $_.Name, $_.InterfaceDescription })
        $suffixes = @((Get-DnsClient -ErrorAction SilentlyContinue).ConnectionSpecificSuffix |
            Where-Object { $_ } | Sort-Object -Unique)
    }
    catch {
        Out-Warn "Network evidence collection failed: $_"
    }
    return [PSCustomObject]@{ Adapters = $adapters; DnsSuffixes = $suffixes }
}

function Get-BmcRunningPxProcess {
    param([int] $TargetPort = 3128)

    $processes = Get-Process -Name 'px' -ErrorAction SilentlyContinue
    if (-not $processes) {
        return $null
    }

    $activeConnection = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction SilentlyContinue
    if ($activeConnection) {
        $listeningProcess = $processes | Where-Object { $_.Id -in $activeConnection.OwningProcess }
        if ($listeningProcess) {
            return $listeningProcess
        }
    }

    return $processes
}

# State Management & Environment Variables
function Save-BmcState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Mode,

        [hashtable] $SavedEnvironment,

        [string] $AppDataPath = $BmcAppDataPath,

        [string] $StatePath = $StateFilePath
    )

    $resolvedDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AppDataPath)
    if (-not (Test-Path -LiteralPath $resolvedDir)) {
        $null = New-Item -ItemType Directory -Path $resolvedDir -Force
    }

    $stateData = @{
        Timestamp   = (Get-Date).ToString('o')
        Mode        = $Mode
        Environment = $SavedEnvironment
    }

    $json = $stateData | ConvertTo-Json -Depth 4
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolvedPath, $json, $encoding)

    Out-Info "Environment state saved to: $StatePath"
}

function Get-BmcState {
    param(
        [string] $StatePath = $StateFilePath
    )

    if (Test-Path -LiteralPath $StatePath) {
        try {
            $rawJson = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop
            return ($rawJson | ConvertFrom-Json)
        }
        catch {
            Out-Warn "Failed to load state file ($StatePath): $_"
        }
    }
    return $null
}

function Enable-BmcDirectAccess {
    param(
        [string] $AppDataPath = $BmcAppDataPath,
        [string] $StatePath = $StateFilePath
    )

    Out-Warn "Enabling Direct Access mode (removing proxy variables from process)..."

    $proxyVars = @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NO_PROXY', 'no_proxy')
    $savedVars = @{}

    foreach ($var in $proxyVars) {
        $currentVal = [Environment]::GetEnvironmentVariable($var, 'Process')
        if ($currentVal) {
            $savedVars[$var] = $currentVal
            [Environment]::SetEnvironmentVariable($var, $null, 'Process')
        }
    }

    Save-BmcState -Mode 'DirectAccess' -SavedEnvironment $savedVars -AppDataPath $AppDataPath -StatePath $StatePath

    # Beyond clearing environment variables, clear the tools' proxy configuration too.
    Set-BmcToolProxy -ProxyUrl $null
    Out-Succ "Direct Access mode configured successfully."
}

function Restore-BmcProxyEnvironment {
    param(
        [int] $LocalPort = 3128,
        [string] $AppDataPath = $BmcAppDataPath,
        [string] $StatePath = $StateFilePath
    )

    $localProxyUrl = "http://127.0.0.1:$LocalPort"
    Out-Info "Configuring proxy environment variables for: $localProxyUrl"

    [Environment]::SetEnvironmentVariable('HTTP_PROXY', $localProxyUrl, 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $localProxyUrl, 'Process')
    [Environment]::SetEnvironmentVariable('http_proxy', $localProxyUrl, 'Process')
    [Environment]::SetEnvironmentVariable('https_proxy', $localProxyUrl, 'Process')

    Save-BmcState -Mode 'Proxy' -SavedEnvironment @{
        HTTP_PROXY  = $localProxyUrl
        HTTPS_PROXY = $localProxyUrl
    } -AppDataPath $AppDataPath -StatePath $StatePath
    Out-Succ "Proxy environment variables updated in process."

    # Reconfigure external tools so they route through the local Px proxy.
    Set-BmcToolProxy -ProxyUrl $localProxyUrl
}

# Diagnostic Check Mode
function Invoke-BmcDiagnosticCheck {
    param([int] $TargetPort = 3128)

    Out-Info "--- BusterMyConnection v$SCRIPT_VERSION [Diagnostic Check Mode] ---"

    $config   = Get-BmcConfig
    $pacUrl   = Get-BmcPacUrlFromRegistry
    $scenario = Get-BmcScenario -Config $config -PacUrl $pacUrl
    Out-Info "Detected network scenario: $scenario"

    $evidence = Get-BmcNetworkEvidence
    Out-Info "Active adapters: $($evidence.Adapters -join '; ')"
    Out-Info "DNS suffixes: $($evidence.DnsSuffixes -join ', ')"

    if ($pacUrl) {
        Out-Succ "PAC File URL located in Registry: $pacUrl"
        $pacReachable = Test-BmcPacEndpoint -PacUrl $pacUrl
        if ($pacReachable) {
            Out-Succ "PAC file endpoint is reachable."
        } else {
            Out-Warn "Unable to connect to PAC file endpoint ($pacUrl)."
        }
    } else {
        Out-Warn "No PAC File URL found in $RegSettingsKey."
    }

    $pxPath = Get-BmcPxBinaryPath
    if ($pxPath) {
        Out-Succ "Px Proxy binary found: $pxPath"
    } else {
        Out-Warn "Px Proxy binary not found on system."
    }

    $runningProcess = Get-BmcRunningPxProcess -TargetPort $TargetPort
    if ($runningProcess) {
        Out-Succ "Px Proxy process detected running (PID: $($runningProcess.Id -join ', '))."
    } else {
        Out-Warn "Px Proxy process is not currently running on port $TargetPort."
    }

    $savedState = Get-BmcState
    if ($savedState) {
        Out-Info "Last recorded state: $($savedState.Mode) at $($savedState.Timestamp)"
    }

    Out-Info "Diagnostic check completed without modifying system state."
}

# Main Execution Flow Orchestrator
function Start-BmcOrchestration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [int] $LocalPort = 3128,
        [string] $ConfigPath = $ConfigFilePath,
        [switch] $SkipToolCheck
    )

    if (-not $PSCmdlet.ShouldProcess("Local System", "Orchestrate Px Proxy and environment state")) {
        return
    }

    Out-Info "--- BusterMyConnection v$SCRIPT_VERSION ---"

    # 0. Load configuration, read the PAC URL and resolve the active network scenario.
    $config   = Get-BmcConfig -Path $ConfigPath
    $pacUrl   = Get-BmcPacUrlFromRegistry
    $scenario = Get-BmcScenario -Config $config -PacUrl $pacUrl
    Out-Info "Detected network scenario: $scenario"
    $scenarioConfig = $config.scenarios.$scenario

    # Verifies every tool once the environment is configured (read-only; see Test-BmcToolAccess).
    $checkTools = {
        param([string] $EffectiveProxy, [bool] $NexusOn)
        if (-not $SkipToolCheck) {
            $null = Test-BmcToolAccess -Config $config -ProxyUrl $EffectiveProxy -NexusEnabled $NexusOn
        }
    }

    # 1. Corporate PAC File from the Windows Registry
    if (-not $pacUrl) {
        Out-Warn "No corporate PAC file detected in Windows Registry."
        Enable-BmcDirectAccess
        Set-BmcNexusConfig -Config $config -Enabled $false
        & $checkTools '' $false
        return
    }

    Out-Info "PAC File located: $pacUrl"

    # Home-like scenarios explicitly request direct access regardless of PAC presence.
    if ($scenarioConfig -and $scenarioConfig.proxy -eq 'none') {
        Out-Info "Scenario '$scenario' requests direct access (proxy=none)."
        if ($scenario -eq 'Home') {
            Out-Warn "A corporate PAC file is configured but the corporate network was not detected. If you are on it, set detection.officeDnsSuffixPattern in $ConfigFilePath (run bmc -JustCheck to list the DNS suffixes and adapters seen)."
        }
        Enable-BmcDirectAccess
        $nexusOn = [bool]$scenarioConfig.nexus
        Set-BmcNexusConfig -Config $config -Enabled $nexusOn
        & $checkTools '' $nexusOn
        return
    }

    # 2. Test PAC Endpoint Reachability
    $isPacAlive = Test-BmcPacEndpoint -PacUrl $pacUrl
    if (-not $isPacAlive) {
        Out-Warn "PAC file endpoint is unreachable. Corporate proxy might be unavailable."
        Enable-BmcDirectAccess
        Set-BmcNexusConfig -Config $config -Enabled $false
        & $checkTools '' $false
        return
    }

    # 3. Provision Px Proxy via Scoop if necessary
    $pxBinary = Install-BmcPxProxy

    # 4. Ensure Px Proxy is Running (Passing --pac directly via CLI)
    $pxProcess = Get-BmcRunningPxProcess -TargetPort $LocalPort
    if (-not $pxProcess) {
        Out-Info "Starting Px Proxy process with direct PAC file support..."
        $startArgs = @("--pac=$pacUrl", "--listen=127.0.0.1", "--port=$LocalPort")
        Start-Process -FilePath $pxBinary -ArgumentList $startArgs -WindowStyle Hidden
        Start-Sleep -Seconds 2

        $pxProcess = Get-BmcRunningPxProcess -TargetPort $LocalPort
        if (-not $pxProcess) {
            Out-Err "Failed to start Px Proxy."
            Enable-BmcDirectAccess
            Set-BmcNexusConfig -Config $config -Enabled $false
            & $checkTools '' $false
            return
        }
    }

    Out-Succ "Px Proxy is running and operational."

    # 5. Set Environment Variables (and reconfigure tools via Restore-BmcProxyEnvironment).
    Restore-BmcProxyEnvironment -LocalPort $LocalPort

    # 6. Reconfigure Nexus mirrors according to the active scenario.
    $nexusEnabled = if ($scenarioConfig) { [bool]$scenarioConfig.nexus } else { $false }
    Set-BmcNexusConfig -Config $config -Enabled $nexusEnabled

    # 7. Verify that every tool reaches its target through the configured route.
    & $checkTools "http://127.0.0.1:$LocalPort" $nexusEnabled
}

# --- DotSource Guard ---
if ($DotSourceOnly) {
    return
}

# Core Logic Execution Entrypoint
if ($JustCheck) {
    Invoke-BmcDiagnosticCheck -TargetPort $Port
} else {
    try {
        $orchestrationArgs = @{ LocalPort = $Port; SkipToolCheck = $SkipToolCheck.IsPresent }
        if ($ConfigPath) {
            $orchestrationArgs['ConfigPath'] = $ConfigPath
        }
        Start-BmcOrchestration @orchestrationArgs
    }
    catch {
        Out-Err "A critical error occurred during orchestration: $_"
        exit 1
    }
}