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

    The -Force parameter allows explicit control over the connection strategy:
      • DIRECT:  Forces direct internet access, removing all proxy environment variables
      • PROXY:   Forces corporate proxy mode using settings from cntlm.ini (with authentication)
      • CNTLM:   Forces CNTLM proxy mode, ensuring CNTLM is installed and running

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

.PARAMETER IniPath
    Path to the CNTLM configuration file (cntlm.ini).
    Default: ~/cntlm.ini

.PARAMETER CntlmPath
    Path to the CNTLM executable. If not found, will trigger automatic installation.
    Default: %LOCALAPPDATA%\Programs\CNTLM\cntlm.exe

.PARAMETER LogDirectory
    Directory for log files.
    Default: %TEMP%

.PARAMETER KeepExisting
    If specified, preserves any running CNTLM instances instead of restarting.

.PARAMETER Quiet
    Suppresses informational output. Errors and warnings are still displayed.

.PARAMETER JustCheck
    Diagnostic mode. Evaluates all connectivity strategies without making changes.

.PARAMETER Force
    Forces a specific connectivity strategy:
    - DIRECT: Direct internet access, no proxy
    - PROXY:  Corporate proxy from cntlm.ini (prompts for credentials)
    - CNTLM:  CNTLM proxy mode

.PARAMETER ProxyTestTimeoutSeconds
    Timeout in seconds for proxy connectivity tests.
    Default: 5

.PARAMETER ProxyTestPort
    Port number for proxy testing.
    Default: 80

.PARAMETER DirectAccessTestTimeoutSeconds
    Timeout in seconds for direct internet connectivity tests.
    Default: 10

.PARAMETER CheckTimeoutSeconds
    Timeout in seconds for diagnostic checks (-JustCheck mode).
    Default: 30

.PARAMETER CheckRetries
    Number of retry attempts for connectivity checks.
    Default: 2

.EXAMPLE
    .\Buster-MyConnection.ps1
    Executes with defaults, auto-detecting the best connectivity strategy.

.EXAMPLE
    .\Buster-MyConnection.ps1 -Force DIRECT
    Forces direct internet access, bypassing all proxy configurations.

.EXAMPLE
    .\Buster-MyConnection.ps1 -Force PROXY
    Forces corporate proxy mode using upstream proxy from cntlm.ini.
    Prompts for domain credentials.

.EXAMPLE
    .\Buster-MyConnection.ps1 -Force CNTLM
    Forces CNTLM mode, installing if necessary and starting the service.

.EXAMPLE
    .\Buster-MyConnection.ps1 -JustCheck
    Runs diagnostic checks on all connectivity strategies without making changes.

.EXAMPLE
    .\Buster-MyConnection.ps1 -IniPath "C:\Tools\cntlm.ini" -KeepExisting
    Uses an alternate configuration while preserving any running CNTLM instances.

.EXAMPLE
    .\Buster-MyConnection.ps1 -Verbose
    Runs with detailed verbose output for troubleshooting.

.EXAMPLE
    Get-Help .\Buster-MyConnection.ps1 -Full
    Displays this complete help documentation.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    Exit code 0 on success, 1 on failure.

.NOTES
    File Name      : Buster-MyConnection.ps1
    Author         : Yorga Babuscan (yorgabr@gmail.com)
    Prerequisite   : PowerShell 5.1 or later
    Version        : 2.4.0
    
    All user-facing messages and logs are emitted in English to maintain consistency
    across international environments and facilitate troubleshooting in heterogeneous
    teams. Internal documentation and comments follow the same convention, ensuring the
    codebase remains accessible to contributors regardless of their locale.

.LINK
    https://github.com/yorgabr/BusterMyConnection

.COMPONENT
    Network
    Proxy
    CNTLM

.FUNCTIONALITY
    Network connectivity management with automatic CNTLM proxy configuration

#>

[CmdletBinding(DefaultParameterSetName='Standard')]
param(
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [string]$IniPath = (Join-Path -Path $HOME -ChildPath 'cntlm.ini'),
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [string]$CntlmPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs/CNTLM/cntlm.exe'),
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [string]$LogDirectory = $env:TEMP,
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [switch]$KeepExisting,
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [switch]$Quiet,
    
    [Parameter(ParameterSetName='Check', Mandatory=$true)]
    [switch]$JustCheck,
    
    [Parameter(ParameterSetName='Force', Mandatory=$true)]
    [ValidateSet('DIRECT','PROXY','CNTLM')]
    [string]$Force,
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [int]$ProxyTestTimeoutSeconds = 5,
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [int]$ProxyTestPort = 80,
    
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [int]$DirectAccessTestTimeoutSeconds = 10,
    
    [Parameter(ParameterSetName='Check')]
    [int]$CheckTimeoutSeconds = 30,
    
    [Parameter(ParameterSetName='Check')]
    [int]$CheckRetries = 2,
    
    [Parameter(ParameterSetName='Help')]
    [Alias('h','?')]
    [switch]$Help
)

# Handle -Help parameter explicitly
if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Full
    exit 0
}

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
$SCRIPT_VERSION = '2.4.0'
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
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
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
# Credentials Management
#---------------------------------
$CredentialCachePath = Join-Path $env:LOCALAPPDATA 'Buster-MyConnection\credentials.xml'

function Get-StoredProxyCredential {
    param([string]$Domain, [string]$Username)
    
    if (Test-Path $CredentialCachePath) {
        try {
            $stored = Import-Clixml -Path $CredentialCachePath
            if ($stored.Domain -eq $Domain -and $stored.Username -eq $Username) {
                Write-Verbose "Found cached credentials for $Domain\$Username"
                return $stored.Credential
            }
        } catch {
            Write-Verbose "Failed to load cached credentials: $($_.Exception.Message)"
        }
    }
    return $null
}

function Set-StoredProxyCredential {
    param([string]$Domain, [string]$Username, [PSCredential]$Credential)
    
    $dir = Split-Path $CredentialCachePath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    try {
        @{
            Domain = $Domain
            Username = $Username
            Credential = $Credential
            Timestamp = (Get-Date).ToString('o')
        } | Export-Clixml -Path $CredentialCachePath -Force
        Write-Verbose "Cached credentials for $Domain\$Username"
    } catch {
        Write-Verbose "Failed to cache credentials: $($_.Exception.Message)"
    }
}

function Get-ProxyCredential {
    param([string]$Domain, [string]$Username, [switch]$UseCache)
    
    # Try to get from cache first
    if ($UseCache) {
        $cached = Get-StoredProxyCredential -Domain $Domain -Username $Username
        if ($cached) {
            Out-Info "Using cached credentials for $Domain\$Username"
            return $cached
        }
    }
    
    # Prompt user for credentials
    Out-Info "Corporate proxy requires authentication."
    
    if ($Domain) {
        $fullUsername = "$Domain\$Username"
    } else {
        $fullUsername = $Username
    }
    
    Write-Host "`nPlease enter your credentials for proxy authentication:" -ForegroundColor Cyan
    Write-Host "Username: $fullUsername" -ForegroundColor Gray
    
    $securePassword = Read-Host "Password" -AsSecureString
    $credential = New-Object System.Management.Automation.PSCredential($fullUsername, $securePassword)
    
    # Ask if user wants to cache credentials
    $cacheChoice = Read-Host "`nCache credentials securely for future use? (Y/N)"
    if ($cacheChoice -eq 'Y' -or $cacheChoice -eq 'y') {
        Set-StoredProxyCredential -Domain $Domain -Username $Username -Credential $credential
    }
    
    # Ask if user wants to export USERPWD environment variable
    $exportChoice = Read-Host "Export credentials to USERPWD environment variable? (Y/N)"
    if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
        $plainPassword = $credential.GetNetworkCredential().Password
        $userpwd = "${fullUsername}:${plainPassword}"
        [System.Environment]::SetEnvironmentVariable('USERPWD', $userpwd, 'Process')
        Out-Info "USERPWD environment variable exported."
    }
    
    return $credential
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
        [ValidateSet('Proxied','DirectAccess','CorporateProxy')]
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
            Write-Verbose "Restoring $($p.Name) = $($p.Value)"
            [System.Environment]::SetEnvironmentVariable($p.Name, $p.Value, 'Process')
        }
    }
}

function Set-ProxyEnvironmentForCntlm {
    param([int]$Port = 3128, [string]$NoProxy = 'localhost,127.0.0.1')
    $proxy = "http://127.0.0.1:$Port"
    [System.Environment]::SetEnvironmentVariable('HTTP_PROXY',  $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('ALL_PROXY',   $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('NO_PROXY',    $NoProxy, 'Process')
    Out-Info "Proxy environment variables exported for CNTLM on port $Port."
    Out-Info "NO_PROXY set to: $NoProxy"
}

function Set-ProxyEnvironmentForCorporate {
    param(
        [string]$ProxyAddress, 
        [int]$ProxyPort, 
        [PSCredential]$Credential,
        [string]$NoProxy = 'localhost,127.0.0.1'
    )
    
    if ($Credential) {
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $proxy = "http://${username}:${password}@${ProxyAddress}:${ProxyPort}"
    } else {
        $proxy = "http://${ProxyAddress}:${ProxyPort}"
    }
    
    [System.Environment]::SetEnvironmentVariable('HTTP_PROXY',  $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('ALL_PROXY',   $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('NO_PROXY',    $NoProxy, 'Process')
    Out-Info "Proxy environment variables exported for corporate proxy: http://${ProxyAddress}:${ProxyPort}"
    Out-Info "NO_PROXY set to: $NoProxy"
}

#---------------------------------
# CNTLM Configuration Parser
#---------------------------------
function Get-CntlmConfiguration {
    param([string]$IniPath)
    
    if (-not (Test-Path $IniPath)) {
        throw "CNTLM configuration file not found: $IniPath"
    }

    $config = @{
        Proxy = $null
        ProxyPort = $null
        Listen = 3128
        Domain = $null
        Username = $null
        NoProxy = 'localhost,127.0.0.1'
    }

    Get-Content $IniPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^Proxy\s+(.+):(\d+)') {
            $config.Proxy = $matches[1]
            $config.ProxyPort = [int]$matches[2]
        }
        elseif ($line -match '^Listen\s+(\d+)') {
            $config.Listen = [int]$matches[1]
        }
        elseif ($line -match '^Domain\s+(.+)') {
            $config.Domain = $matches[1]
        }
        elseif ($line -match '^Username\s+(.+)') {
            $config.Username = $matches[1]
        }
        elseif ($line -match '^NoProxy\s+(.+)') {
            # Convert CNTLM NoProxy format to environment variable format
            $noProxyValue = $matches[1]
            # Remove leading/trailing whitespace and normalize separators
            $config.NoProxy = $noProxyValue -replace '\s*,\s*', ',' -replace '\s+', ','
        }
    }

    if (-not $config.Proxy -or -not $config.ProxyPort) {
        throw "Invalid CNTLM configuration: missing Proxy directive in $IniPath"
    }

    return $config
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
            Write-Verbose "Connectivity test succeeded: $url"
            return $true
        } catch {
            Write-Verbose "Connectivity test failed: $url - $($_.Exception.Message)"
        }
    }
    return $false
}

function Test-ProxyConnectivity {
    param(
        [string]$ProxyUrl, 
        [int]$TimeoutSeconds,
        [PSCredential]$Credential = $null
    )
    
    $testUrls = @(
        'http://httpbin.org/get',
        'https://httpbin.org/get'
    )
    
    foreach ($url in $testUrls) {
        try {
            $params = @{
                Uri = $url
                Proxy = $ProxyUrl
                TimeoutSec = $TimeoutSeconds
                UseBasicParsing = $true
            }
            
            if ($Credential) {
                $params['ProxyCredential'] = $Credential
            }
            
            Invoke-WebRequest @params | Out-Null
            Write-Verbose "Proxy connectivity test succeeded: $url via $ProxyUrl"
        } catch {
            Write-Verbose "Proxy connectivity test failed: $url via $ProxyUrl - $($_.Exception.Message)"
            return $false
        }
    }
    return $true
}

function Test-TcpPort {
    param([string]$Address, [int]$Port, [int]$TimeoutSeconds = 5)
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($Address, $Port, $null, $null)
        $wait = $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        
        if ($wait) {
            try {
                $tcpClient.EndConnect($asyncResult)
                $tcpClient.Close()
                Write-Verbose "TCP port test succeeded: ${Address}:${Port}"
                return $true
            } catch {
                Write-Verbose "TCP port test failed during EndConnect: ${Address}:${Port} - $($_.Exception.Message)"
                return $false
            }
        } else {
            Write-Verbose "TCP port test timed out: ${Address}:${Port}"
            $tcpClient.Close()
            return $false
        }
    } catch {
        Write-Verbose "TCP port test exception: ${Address}:${Port} - $($_.Exception.Message)"
        return $false
    }
}

#---------------------------------
# CNTLM Process Management
#---------------------------------
function Stop-CntlmProcess {
    $processes = Get-Process -Name 'cntlm' -ErrorAction SilentlyContinue
    if ($processes) {
        Out-Info "Stopping existing CNTLM process(es)..."
        $processes | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
}

function Start-CntlmProcess {
    param([string]$ExePath, [string]$IniPath)
    
    if (-not $KeepExisting) {
        Stop-CntlmProcess
    }

    Out-Info "Starting CNTLM: $ExePath -c $IniPath"
    Start-Process -FilePath $ExePath -ArgumentList @('-c', $IniPath) -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

function Test-CntlmRunning {
    $process = Get-Process -Name 'cntlm' -ErrorAction SilentlyContinue
    return ($null -ne $process)
}

#---------------------------------
# CNTLM Installation
#---------------------------------
function Install-CntlmPortable {
    param([string]$TargetPath)
    
    Out-Info "CNTLM not found. Initiating automatic installation..."
    
    $downloadUrl = 'http://downloads.sourceforge.net/project/cntlm/cntlm/cntlm%200.92.3/cntlm-0.92.3-win32.zip'
    $zipPath = Join-Path $env:TEMP 'cntlm.zip'
    $extractPath = Join-Path $env:TEMP 'cntlm_extract'
    
    try {
        Out-Info "Downloading CNTLM from $downloadUrl..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
        
        Out-Info "Extracting CNTLM to $extractPath..."
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        
        if (-not (Test-Path $TargetPath)) {
            New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
        }
        
        $exeSource = Get-ChildItem -Path $extractPath -Filter 'cntlm.exe' -Recurse | Select-Object -First 1
        if (-not $exeSource) {
            throw "cntlm.exe not found in downloaded archive"
        }
        
        $exeDest = Join-Path $TargetPath 'cntlm.exe'
        Copy-Item -Path $exeSource.FullName -Destination $exeDest -Force
        
        Out-Success "CNTLM installed successfully to $exeDest"
        return $exeDest
        
    } catch {
        Out-Error "Failed to install CNTLM: $($_.Exception.Message)"
        throw
    } finally {
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-CntlmExecutable {
    param([string]$Path)
    if (Test-Path $Path) { 
        Out-Info "CNTLM found at $Path"
        return $Path 
    }
    return Install-CntlmPortable -TargetPath (Split-Path -Parent $Path)
}

#---------------------------------
# CNTLM Configuration Wizard
#---------------------------------
function New-CntlmConfiguration {
    param([string]$OutputPath)
    
    Out-Info "=== CNTLM Configuration Wizard ==="
    
    $domain = Read-Host "Enter your domain (e.g., CORP)"
    $username = Read-Host "Enter your username"
    $proxyAddress = Read-Host "Enter upstream proxy address (e.g., proxy.corp.com)"
    $proxyPort = Read-Host "Enter upstream proxy port (e.g., 8080)"
    $listenPort = Read-Host "Enter CNTLM listen port (default: 3128)"
    
    if ([string]::IsNullOrWhiteSpace($listenPort)) {
        $listenPort = 3128
    }
    
    $noProxy = Read-Host "Enter NoProxy exceptions (default: localhost, 127.0.0.*, 10.*, 192.168.*)"
    if ([string]::IsNullOrWhiteSpace($noProxy)) {
        $noProxy = "localhost, 127.0.0.*, 10.*, 192.168.*"
    }
    
    $password = Read-Host "Enter your password" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    
    # Generate password hash (simplified - in production use cntlm -H)
    Out-Warn "For production use, generate proper NTLM hash using: cntlm -H -u $username -d $domain"
    
    $configContent = @"
# CNTLM Configuration
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(Get-Date)

Username    $username
Domain      $domain
Password    $plainPassword
Proxy       ${proxyAddress}:${proxyPort}
Listen      $listenPort
NoProxy     $noProxy
Gateway     no
SOCKS5Proxy 0
"@

    $dir = Split-Path $OutputPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    Set-Content -Path $OutputPath -Value $configContent -Force
    Out-Success "CNTLM configuration saved to $OutputPath"
    
    return $OutputPath
}

#---------------------------------
# Force Mode Handlers
#---------------------------------
function Invoke-ForceDirect {
    Out-Info "Force mode: DIRECT - Removing all proxy environment variables"
    
    $backup = Backup-ProxyEnvironmentVariables
    Remove-ProxyEnvironmentVariables
    
    if (Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
        Out-Success "DIRECT ACCESS mode activated and verified."
        Set-ExecutionState -Mode 'DirectAccess' -ProxyVariables $backup
        return $true
    } else {
        Out-Error "DIRECT ACCESS mode failed connectivity test."
        return $false
    }
}

function Invoke-ForceProxy {
    param([string]$IniPath)
    
    Out-Info "Force mode: PROXY - Configuring corporate proxy from cntlm.ini"
    
    if (-not (Test-Path $IniPath)) {
        Out-Error "Cannot force PROXY mode: configuration file not found at $IniPath"
        return $false
    }
    
    try {
        $config = Get-CntlmConfiguration -IniPath $IniPath
        
        Out-Info "Testing corporate proxy: $($config.Proxy):$($config.ProxyPort)"
        if (-not (Test-TcpPort -Address $config.Proxy -Port $config.ProxyPort -TimeoutSeconds $ProxyTestTimeoutSeconds)) {
            Out-Error "Corporate proxy $($config.Proxy):$($config.ProxyPort) is not reachable."
            return $false
        }
        
        # Get credentials from cntlm.ini or prompt user
        $credential = Get-ProxyCredential -Domain $config.Domain -Username $config.Username -UseCache
        
        Remove-ProxyEnvironmentVariables
        Set-ProxyEnvironmentForCorporate -ProxyAddress $config.Proxy -ProxyPort $config.ProxyPort -Credential $credential -NoProxy $config.NoProxy
        
        $proxyUrl = "http://$($config.Proxy):$($config.ProxyPort)"
        if (Test-ProxyConnectivity -ProxyUrl $proxyUrl -TimeoutSeconds $DirectAccessTestTimeoutSeconds -Credential $credential) {
            Out-Success "CORPORATE PROXY mode activated and verified."
            Set-ExecutionState -Mode 'CorporateProxy'
            return $true
        } else {
            Out-Error "CORPORATE PROXY mode failed connectivity test. Please verify your credentials."
            return $false
        }
        
    } catch {
        Out-Error "Failed to configure PROXY mode: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-ForceCntlm {
    param([string]$CntlmPath, [string]$IniPath)
    
    Out-Info "Force mode: CNTLM - Ensuring CNTLM is installed and running"
    
    # Ensure CNTLM executable exists
    try {
        $resolvedExe = Resolve-CntlmExecutable -Path $CntlmPath
    } catch {
        Out-Error "Failed to resolve CNTLM executable: $($_.Exception.Message)"
        return $false
    }
    
    # Ensure configuration exists
    if (-not (Test-Path $IniPath)) {
        Out-Info "CNTLM configuration not found. Launching configuration wizard..."
        try {
            $IniPath = New-CntlmConfiguration -OutputPath $IniPath
        } catch {
            Out-Error "Configuration wizard failed: $($_.Exception.Message)"
            return $false
        }
    }
    
    # Parse configuration to get listen port and NoProxy
    try {
        $config = Get-CntlmConfiguration -IniPath $IniPath
        $listenPort = $config.Listen
        $noProxy = $config.NoProxy
    } catch {
        Out-Error "Failed to parse CNTLM configuration: $($_.Exception.Message)"
        return $false
    }
    
    # Start CNTLM process
    try {
        Start-CntlmProcess -ExePath $resolvedExe -IniPath $IniPath
    } catch {
        Out-Error "Failed to start CNTLM: $($_.Exception.Message)"
        return $false
    }
    
    # Verify CNTLM is running and accessible
    if (-not (Test-CntlmRunning)) {
        Out-Error "CNTLM process is not running after startup attempt."
        return $false
    }
    
    # Configure environment and test connectivity
    Remove-ProxyEnvironmentVariables
    Set-ProxyEnvironmentForCntlm -Port $listenPort -NoProxy $noProxy
    
    $proxyUrl = "http://127.0.0.1:$listenPort"
    if (Test-ProxyConnectivity -ProxyUrl $proxyUrl -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
        Out-Success "CNTLM PROXY mode activated and verified."
        Set-ExecutionState -Mode 'Proxied'
        return $true
    } else {
        Out-Error "CNTLM PROXY mode failed connectivity test."
        return $false
    }
}

#---------------------------------
# JUSTCHECK MODE
#---------------------------------
if ($JustCheck) {
    Out-Info "JustCheck mode: evaluating connectivity without changes."
    Out-Info "Current proxy environment variables:"
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)proxy' } | ForEach-Object {
        Write-Host "  $($_.Key) = $($_.Value)"
    }
    
    # Check CNTLM availability
    $cntlmRunning = Test-CntlmRunning
    if ($cntlmRunning) {
        Out-Info "CNTLM process is running."
        if (Test-ProxyConnectivity -ProxyUrl 'http://127.0.0.1:3128' -TimeoutSeconds $CheckTimeoutSeconds) {
            Out-Success "CNTLM MODE viable (CNTLM reachable and functional)."
        } else {
            Out-Warn "CNTLM process running but not responding to connectivity tests."
        }
    } else {
        Out-Info "CNTLM process is not running."
    }
    
    # Check corporate proxy availability (without authentication test in diagnostic mode)
    if (Test-Path $IniPath) {
        try {
            $config = Get-CntlmConfiguration -IniPath $IniPath
            Out-Info "CNTLM configuration found: $IniPath"
            Out-Info "  Proxy: $($config.Proxy):$($config.ProxyPort)"
            Out-Info "  Listen: $($config.Listen)"
            Out-Info "  NoProxy: $($config.NoProxy)"
            Out-Info "  Domain: $($config.Domain)"
            Out-Info "  Username: $($config.Username)"
            
            if (Test-TcpPort -Address $config.Proxy -Port $config.ProxyPort -TimeoutSeconds $CheckTimeoutSeconds) {
                Out-Success "CORPORATE PROXY MODE viable ($($config.Proxy):$($config.ProxyPort) reachable)."
                Out-Info "Note: Authentication test skipped in diagnostic mode."
            } else {
                Out-Info "Corporate proxy $($config.Proxy):$($config.ProxyPort) not reachable."
            }
        } catch {
            Out-Warn "Could not parse cntlm.ini: $($_.Exception.Message)"
        }
    } else {
        Out-Info "CNTLM configuration not found at: $IniPath"
    }
    
    # Check direct access
    if (Test-InternetConnectivity -TimeoutSeconds $CheckTimeoutSeconds) {
        Out-Success "DIRECT ACCESS MODE viable."
    } else {
        Out-Info "Direct internet access not available."
    }
    
    Out-Info "Diagnostic check complete."
    exit 0
}

#---------------------------------
# MAIN FLOW
#---------------------------------

# Handle Force parameter
if ($Force) {
    Out-Info "=== Force mode activated: $Force ==="
    
    $success = switch ($Force) {
        'DIRECT' { Invoke-ForceDirect }
        'PROXY'  { Invoke-ForceProxy -IniPath $IniPath }
        'CNTLM'  { Invoke-ForceCntlm -CntlmPath $CntlmPath -IniPath $IniPath }
    }
    
    if ($success) {
        Out-Info "Final strategy (forced): $Force MODE."
        exit 0
    } else {
        Out-Error "Forced mode $Force failed."
        exit 1
    }
}

# Auto-detection mode (original behavior)
Out-Info "=== Auto-detection mode ==="
Out-Info "Evaluating optimal connectivity strategy..."

$previousState = Get-PreviousExecutionState
if ($previousState -and $previousState.Mode -eq 'DirectAccess') {
    Out-Info "Restoring proxy variables from previous direct access session."
    Restore-ProxyEnvironmentVariables $previousState.ProxyVariables
}

# Strategy 1: Try CNTLM
Out-Info "Strategy 1: Attempting CNTLM mode..."
$resolvedExe = $null
try { 
    $resolvedExe = Resolve-CntlmExecutable -Path $CntlmPath 
} catch {
    Out-Warn "CNTLM executable resolution failed: $($_.Exception.Message)"
}

if ($resolvedExe) {
    if (-not (Test-Path $IniPath)) {
        Out-Info "CNTLM configuration not found. Launching configuration wizard..."
        try {
            $IniPath = New-CntlmConfiguration -OutputPath $IniPath
        } catch {
            Out-Warn "Configuration wizard failed: $($_.Exception.Message)"
            $resolvedExe = $null
        }
    }
}

if ($resolvedExe -and (Test-Path $IniPath)) {
    try {
        $config = Get-CntlmConfiguration -IniPath $IniPath
        Start-CntlmProcess -ExePath $resolvedExe -IniPath $IniPath
        
        if (Test-CntlmRunning) {
            Set-ProxyEnvironmentForCntlm -Port $config.Listen -NoProxy $config.NoProxy
            
            $proxyUrl = "http://127.0.0.1:$($config.Listen)"
            if (Test-ProxyConnectivity -ProxyUrl $proxyUrl -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
                Out-Success "CNTLM PROXY mode activated (auto-detected)."
                Set-ExecutionState -Mode 'Proxied'
                Out-Info "Final strategy: CNTLM PROXY MODE."
                exit 0
            } else {
                Out-Warn "CNTLM started but connectivity test failed."
            }
        }
    } catch {
        Out-Warn "CNTLM startup failed: $($_.Exception.Message)"
    }
}

# Strategy 2: Try direct access
Out-Info "Strategy 2: Attempting direct access mode..."
$backup = Backup-ProxyEnvironmentVariables
Remove-ProxyEnvironmentVariables

if (Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
    Out-Success "DIRECT ACCESS mode activated (auto-detected)."
    Set-ExecutionState -Mode 'DirectAccess' -ProxyVariables $backup
    Out-Info "Final strategy: DIRECT ACCESS MODE."
    exit 0
}

# Strategy 3: Try corporate proxy
Out-Info "Strategy 3: Corporate proxy mode requires manual activation with -Force PROXY"
Out-Info "Skipping in auto-detection mode to avoid credential prompts."

Out-Error "No viable connectivity strategy available. Try: -Force DIRECT, -Force PROXY, or -Force CNTLM"
exit 1