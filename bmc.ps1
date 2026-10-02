#Requires -Version 5.1

<#
.SYNOPSIS
    BusterMyConnection (bmc) - Self-healing Px Proxy orchestrator for Windows.

.DESCRIPTION
    BusterMyConnection (bmc) is an orchestration layer designed to absorb corporate network instability on Windows environments.
    Instead of relying on rigid NTLM credentials or legacy proxy helpers like CNTLM, bmc integrates with Px Proxy—a modern HTTP proxy with automatic Windows Single Sign-On (SSO), Kerberos, NTLM, and PAC file evaluation support.

    Core Capabilities & Architecture:
    1. Registry-based PAC Discovery:
       Reads the corporate Proxy Auto-Configuration (PAC) URL directly from the Windows Registry
       (HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings -> AutoConfigURL).

    2. Upstream Health Checks & Endpoint Validation:
       Performs pre-flight TCP/HTTP reachability checks against the PAC endpoint prior to launching
       Px Proxy, preventing broken proxy state during network changes.

    3. Automated Scoop Provisioning:
       Locates px.exe in system execution paths or local Scoop directories. If Px Proxy is absent,
       bmc automatically provisions it without requiring administrative privileges (via 'scoop install px').

    4. Zero-Config Command Line Execution:
       Launches Px Proxy directly using CLI flags (--pac, --listen, --port), bypassing the need to generate
       or manage disk-based px.ini configuration files.

    5. Graceful Fallback (Direct Access Mode):
       When corporate proxies or PAC servers are completely unreachable (e.g., VPN disconnected, off-site),
       bmc steps aside by purging process proxy environment variables (HTTP_PROXY, HTTPS_PROXY, etc.)
       to allow unhindered direct internet communication and eliminate application deadlocks.

    6. State Persistence & Environmental Symmetry:
       Captures snapshots of pre-existing environment variables and serializes execution state to
       %LOCALAPPDATA%\bmc\state.json. When corporate connectivity is restored on subsequent runs,
       bmc recovers saved environment states automatically.

.PARAMETER JustCheck
    Executes in read-only diagnostic mode. Evaluates registry PAC settings, tests PAC endpoint reachability,
    inspects Px Proxy processes, and exits without modifying environment variables or running processes.

.PARAMETER DotSourceOnly
    Exits execution immediately after loading function definitions into session scope.
    Used for unit testing with Pester.

.PARAMETER Port
    Specifies the local listening port for Px Proxy. Default is 3128.

.EXAMPLE
    bmc
    Standard execution: discovers corporate PAC file from Registry, installs Px Proxy via Scoop if needed, launches process with --pac, and exports process proxy variables.

.EXAMPLE
    bmc -JustCheck
    Runs diagnostic inspection and prints system health status without making changes.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch] $JustCheck,
    [switch] $DotSourceOnly,
    [int] $Port = 3128
)

# Global Constants & Paths
$SCRIPT_VERSION = '2.0.0'
$BmcAppDataPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'bmc'
$StateFilePath   = Join-Path -Path $BmcAppDataPath -ChildPath 'state.json'
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
        pipeline to emit bmc.config.sample.json. Mirrors the per-scenario topology (Office/Vpn/Home)
        the tool reconciles across corporate LAN, Big-IP VPN, and off-site home network contexts.
    .DESCRIPTION
        Uses [ordered] to guarantee deterministic key ordering in the serialized JSON artifact,
        keeping the emitted sample stable and diff-friendly across builds.
    #>
    return [ordered]@{
        detection = [ordered]@{
            vpnAdapterPattern      = 'F5|BIG-IP'
            officeDnsSuffixPattern = '(^|\.)corp\.example\.com$'
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
        tools = @('Git', 'Scoop', 'Uv', 'Npm', 'Environment')
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
function Test-BmcPacEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PacUrl,

        [int] $TimeoutSeconds = 5
    )

    try {
        $request = [System.Net.WebRequest]::Create($PacUrl)
        $request.Timeout = $TimeoutSeconds * 1000
        $request.Method = 'HEAD'
        $response = $request.GetResponse()
        $response.Close()
        return $true
    }
    catch {
        return $false
    }
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

        # Injectable paths for testability: they default to the script's global variables but may be
        # overridden (e.g., the physical Pester TestDrive path) without relying on PSDrive scope tricks.
        [string] $AppDataPath = $BmcAppDataPath,

        [string] $StatePath = $StateFilePath
    )

    # Resolve the path to the OS physical filesystem, supporting both native paths and PSDrives.
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
    # Injectable paths forwarded to Save-BmcState, keeping the testability chain intact end-to-end.
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
}

# Diagnostic Check Mode
function Invoke-BmcDiagnosticCheck {
    param([int] $TargetPort = 3128)

    Out-Info "--- BusterMyConnection v$SCRIPT_VERSION [Diagnostic Check Mode] ---"

    $pacUrl = Get-BmcPacUrlFromRegistry
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
        [int] $LocalPort = 3128
    )

    if (-not $PSCmdlet.ShouldProcess("Local System", "Orchestrate Px Proxy and environment state")) {
        return
    }

    Out-Info "--- BusterMyConnection v$SCRIPT_VERSION ---"

    # 1. Retrieve Corporate PAC File from Windows Registry
    $pacUrl = Get-BmcPacUrlFromRegistry
    if (-not $pacUrl) {
        Out-Warn "No corporate PAC file detected in Windows Registry."
        Enable-BmcDirectAccess
        return
    }

    Out-Info "PAC File located: $pacUrl"

    # 2. Test PAC Endpoint Reachability
    $isPacAlive = Test-BmcPacEndpoint -PacUrl $pacUrl
    if (-not $isPacAlive) {
        Out-Warn "PAC file endpoint is unreachable. Corporate proxy might be unavailable."
        Enable-BmcDirectAccess
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
            return
        }
    }

    Out-Succ "Px Proxy is running and operational."

    # 5. Set Environment Variables
    Restore-BmcProxyEnvironment -LocalPort $LocalPort
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
        Start-BmcOrchestration -LocalPort $Port
    }
    catch {
        Out-Err "A critical error occurred during orchestration: $_"
        exit 1
    }
}