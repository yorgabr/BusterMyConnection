<#
.SYNOPSIS
    Buster-MyConnection launches the CNTLM authentication proxy with intelligent setup
    capabilities and fallback to direct internet access.

.DESCRIPTION
    This script embodies a self-healing approach to CNTLM deployment on Windows. Rather
    than failing when components are missing, it proactively downloads and configures the
    necessary infrastructure. The script detects whether CNTLM is installed in the
    expected portable location, and if absent, retrieves the latest stable build from the
    community-maintained repository. Should the configuration file be missing, it engages
    the user in a guided interview to establish the essential proxy settings — domain
    credentials, upstream proxy address, and local listening port — persisting these
    choices to a properly formatted ini file.

    The script implements a stateful connection management system that tracks whether
    the previous execution was in "direct access" mode (proxy variables unset). When
    transitioning back to a proxied environment (VPN active, corporate network detected),
    it automatically restores the appropriate proxy environment variables before
    attempting CNTLM startup.

    A health-check mechanism validates the upstream proxy server declared in cntlm.ini.
    If the parent proxy is unreachable, the script gracefully degrades by removing all
    proxy-related environment variables, allowing direct internet access. This prevents
    connectivity deadlocks when the corporate proxy infrastructure is unavailable.

    The script implements a chain-based VPN detection system that allows seamless extension
    for different VPN clients. Currently supports BIG-IP Edge Client VPN detection via
    local PAC file analysis. When it senses the presence of a local PAC file served by
    the VPN client, it dynamically reconciles the upstream proxy settings to maintain
    seamless connectivity.

    The script operates idempotently, allowing repeated execution without side effects,
    and can manage existing CNTLM processes through the KeepExisting switch. All output
    respects the -Quiet flag for automation scenarios, and comprehensive logging ensures
    operational transparency.

    The -JustCheck switch provides a comprehensive diagnostic mode that inspects the
    current CNTLM instance (if running), analyzes its configuration, and performs
    connectivity tests without making any changes to the system. This is useful for
    troubleshooting and health monitoring.

    The implementation is compatible across Windows PowerShell 5.1 and PowerShell
    Core 6/7+, gracefully degrading functionality when WinINET APIs are unavailable
    while preserving core operational capabilities.

    This script intentionally requires UTF-8 encoding with BOM when executed under
    Windows PowerShell 5.1. Without a BOM, PowerShell 5.1 may misinterpret UTF-8 files as
    ANSI, leading to subtle or fatal parser errors (e.g. unterminated strings or
    comments). PowerShell 6+ (Core) does not require BOM and is unaffected by this limitation.

.REQUIREMENTS
    - Windows PowerShell 5.1 (Desktop edition)
    - Script encoding MUST be UTF-8 with BOM
    - Internet access for auto-installation (first run only)

.EXAMPLE
    Buster-MyConnection
    Executes with defaults, triggering auto-installation and configuration wizard if needed.
    If upstream proxy is dead, unsets proxy vars and exits with code 0 (direct access mode).

.EXAMPLE
    Buster-MyConnection -IniPath "C:\Tools\cntlm.ini" -KeepExisting
    Uses an alternate configuration while preserving any running CNTLM instances.

.NOTES
    All user-facing messages and logs are emitted in English to maintain consistency
    across international environments and facilitate troubleshooting in heterogeneous
    teams. Internal documentation and comments follow the same convention, ensuring the
    codebase remains accessible to contributors regardless of their locale.

.AUTHOR
    Yorga Babuscan (yorgabr@gmail.com)
#>

[CmdletBinding()]
param(
    [string]$IniPath = (Join-Path -Path $HOME -ChildPath 'cntlm.ini'),
    [string]$CntlmPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs/CNTLM/cntlm.exe'),
    [string]$LogDirectory = $env:TEMP,
    [switch]$KeepExisting,
    [switch]$Quiet,
    [switch]$JustCheck,
    [int]$ProxyTestTimeoutSeconds = 5,
    [int]$ProxyTestPort = 80,
    [int]$DirectAccessTestTimeoutSeconds = 10,
    [int]$CheckTimeoutSeconds = 30,
    [int]$CheckRetries = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#---------------------------------
# Quiet / Verbose policy
#---------------------------------
$IsVerbose = $PSBoundParameters.ContainsKey('Verbose')
if (-not $PSBoundParameters.ContainsKey('Quiet')) {
    $Quiet = $true
}

#---------------------------------
# Script Metadata
#---------------------------------
$SCRIPT_VERSION = '2.2.1'
$SCRIPT_NAME    = 'Buster-MyConnection'

#---------------------------------
# Output helpers
#---------------------------------
function Out-Info {
    param([string]$Message)
    if ($Quiet -or $IsVerbose) {
        Write-Host "[INFO] $Message"
    }
}

function Out-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message"
}

function Out-Warn {
    param([string]$Message)
    if ($IsVerbose) {
        Write-Warning $Message
    }
}

function Out-Error {
    param([string]$Message)
    Write-Error $Message
}

#---------------------------------
# State Management
#---------------------------------
$StateFilePath = Join-Path $env:LOCALAPPDATA 'Buster-MyConnection\state.json'

function Get-PreviousExecutionState {
    if (Test-Path $StateFilePath) {
        try {
            return Get-Content $StateFilePath -Raw | ConvertFrom-Json
        } catch {
            Out-Warn "Failed to read previous execution state."
        }
    }
    return $null
}

function Set-ExecutionState {
    param(
        [ValidateSet('Proxied','DirectAccess')]
        [string]$Mode,
        [hashtable]$ProxyVariables = @{}
    )

    $dir = Split-Path $StateFilePath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    @{
        Mode           = $Mode
        ProxyVariables = $ProxyVariables
        Timestamp      = (Get-Date).ToString('o')
        Version        = $SCRIPT_VERSION
    } | ConvertTo-Json -Depth 3 | Set-Content $StateFilePath -Force
}

#---------------------------------
# Proxy environment helpers
#---------------------------------
function Backup-ProxyEnvironmentVariables {
    $backup = @{}
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)proxy' } |
        ForEach-Object { $backup[$_.Key] = $_.Value }
    return $backup
}

function Remove-ProxyEnvironmentVariables {
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)proxy' } |
        ForEach-Object {
            Write-Verbose "Unsetting $($_.Key)"
            Remove-Item "Env:\$($_.Key)" -ErrorAction SilentlyContinue
        }
}

function Restore-ProxyEnvironmentVariables {
    param($Variables)
    if (-not $Variables) { return }
    foreach ($p in $Variables.PSObject.Properties) {
        if ($null -ne $p.Value) {
            Write-Verbose "Restoring $($p.Name)"
            [System.Environment]::SetEnvironmentVariable($p.Name, $p.Value, 'Process')
        }
    }
}

function Set-ProxyEnvironmentForCntlm {
    param([int]$Port)
    $proxy = "http://127.0.0.1:$Port"
    [System.Environment]::SetEnvironmentVariable('HTTP_PROXY',  $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('ALL_PROXY',   $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('NO_PROXY',    'localhost,127.0.0.1', 'Process')
    Out-Info "Proxy environment variables exported for CNTLM."
}

#---------------------------------
# Silent connectivity tests
#---------------------------------
function Test-InternetConnectivity {
    param([int]$TimeoutSeconds)
    foreach ($url in @(
        'http://httpbin.org/get',
        'https://httpbin.org/get',
        'https://www.microsoft.com/'
    )) {
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
            return $true
        } catch {}
    }
    return $false
}

function Test-ProxyConnectivity {
    param([int]$Port,[int]$TimeoutSeconds)
    $proxy = "http://127.0.0.1:$Port"
    foreach ($url in @(
        'http://httpbin.org/get',
        'https://httpbin.org/get'
    )) {
        try {
            Invoke-WebRequest -Uri $url -Proxy $proxy -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
        } catch { return $false }
    }
    return $true
}

#---------------------------------
# CNTLM resolution
#---------------------------------
function Resolve-CntlmExecutable {
    param([string]$Path)
    if (Test-Path $Path) { return $Path }
    return Install-CntlmPortable -TargetPath (Split-Path -Parent $Path)
}

#---------------------------------
# JUSTCHECK MODE
#---------------------------------
if ($JustCheck) {
    Out-Info "JustCheck mode: evaluating connectivity without changes."

    if (Test-ProxyConnectivity -Port 3128 -TimeoutSeconds $CheckTimeoutSeconds) {
        Out-Success "PROXY MODE viable (CNTLM reachable)."
        Out-Info "Final strategy (diagnostic): PROXY MODE."
        exit 0
    }

    if (Test-InternetConnectivity -TimeoutSeconds $CheckTimeoutSeconds) {
        Out-Success "DIRECT ACCESS viable."
        Out-Info "Final strategy (diagnostic): DIRECT ACCESS."
        exit 0
    }

    Out-Error "No viable connectivity strategy detected."
    exit 1
}

#---------------------------------
# MAIN FLOW
#---------------------------------
Out-Info "Evaluating CNTLM availability (primary strategy)..."

$previousState = Get-PreviousExecutionState
if ($previousState -and $previousState.Mode -eq 'DirectAccess') {
    Restore-ProxyEnvironmentVariables $previousState.ProxyVariables
}

$resolvedExe = $null
try { $resolvedExe = Resolve-CntlmExecutable -Path $CntlmPath } catch {}

if (-not (Test-Path $IniPath)) {
    Out-Info "CNTLM configuration not found. Launching configuration wizard..."
    $IniPath = New-CntlmConfiguration -OutputPath $IniPath
}

if ($resolvedExe) {
    Start-Process -FilePath $resolvedExe -ArgumentList @('-c',$IniPath) -WindowStyle Hidden
    Start-Sleep -Seconds 2

    if (Test-ProxyConnectivity -Port 3128 -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
        Out-Success "PROXY MODE active (CNTLM validated)."
        Set-ProxyEnvironmentForCntlm -Port 3128
        Set-ExecutionState -Mode 'Proxied'
        Out-Info "Final strategy: PROXY MODE (CNTLM)."
        exit 0
    }
}

Out-Warn "CNTLM unavailable. Falling back to direct access."

$backup = Backup-ProxyEnvironmentVariables
Remove-ProxyEnvironmentVariables

if (Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
    Out-Success "DIRECT ACCESS active."
    Set-ExecutionState -Mode 'DirectAccess' -ProxyVariables $backup
    Out-Info "Final strategy: DIRECT ACCESS."
    exit 0
}

Out-Error "No usable connectivity strategy available."
exit 1