# src/bustermyconnection/Buster-MyConnection.ps1
<#
.SYNOPSIS
    Buster-MyConnection launches the CNTLM authentication proxy with intelligent setup
    capabilities and fallback to direct internet access.

.DESCRIPTION
    This script embodies a self-healing approach to CNTLM deployment on Windows. Rather
    than failing when components are missing, it proactively installs and configures the
    necessary infrastructure. The script detects whether CNTLM is installed at the given
    path, and if absent, installs it via Scoop (https://scoop.sh), which resolves the
    package over HTTPS and verifies it against its manifest hash. Scoop itself must
    already be installed; the script will not bootstrap it. Should the configuration file
    be missing, it engages the user in a guided interview to establish the essential proxy
    settings, and where possible derives the NTLM password hash automatically (via
    `cntlm -H`) instead of storing the plaintext password.

    The script implements a stateful connection management system that tracks whether
    the previous execution was in "direct access" mode (proxy variables unset). When
    transitioning back to a proxied environment, it automatically restores the
    appropriate proxy environment variables before attempting CNTLM startup.

    A health-check mechanism validates the upstream proxy server declared in cntlm.ini.
    If the parent proxy is unreachable, the script gracefully degrades by removing all
    proxy-related environment variables, allowing direct internet access.

    The script implements a chain-based VPN detection system that allows seamless
    extension for different VPN clients.

    The -JustCheck switch provides a comprehensive diagnostic mode that inspects the
    current CNTLM instance, analyzes its configuration, and performs connectivity tests
    without making any changes to the system.

    The -Force parameter allows explicit control over the connection strategy:
      DIRECT  Forces direct internet access, removing all proxy environment variables.
      PROXY   Forces corporate proxy mode using settings from cntlm.ini (with auth).
      CNTLM   Forces CNTLM proxy mode, ensuring CNTLM is installed and running.

    The implementation targets Windows PowerShell 5.1 (Desktop). The file MUST be saved
    as UTF-8 with BOM; without a BOM, PowerShell 5.1 may misinterpret it as ANSI and
    raise fatal parser errors.

.PARAMETER IniPath
    Path to the CNTLM configuration file (cntlm.ini). Default: ~/cntlm.ini

.PARAMETER CntlmPath
    Path to the CNTLM executable. If absent, triggers automatic installation.
    Default: %LOCALAPPDATA%\Programs\CNTLM\cntlm.exe

.PARAMETER LogDirectory
    Directory for log files. Default: %TEMP%

.PARAMETER KeepExisting
    Preserves any running CNTLM instances instead of restarting.

.PARAMETER Quiet
    Suppresses informational output. Errors and warnings are still displayed.

.PARAMETER JustCheck
    Diagnostic mode. Evaluates connectivity strategies without making changes.

.PARAMETER Force
    Forces a specific connectivity strategy: DIRECT, PROXY, or CNTLM.

.PARAMETER ProxyTestTimeoutSeconds
    Timeout in seconds for proxy connectivity (TCP) tests. Default: 5

.PARAMETER ProxyTestPort
    Port number for proxy testing. Default: 80

.PARAMETER DirectAccessTestTimeoutSeconds
    Timeout in seconds for direct internet connectivity tests. Default: 10

.PARAMETER CheckTimeoutSeconds
    Timeout in seconds for diagnostic checks (-JustCheck mode). Default: 30

.PARAMETER CheckRetries
    Number of retry attempts for connectivity checks. Default: 2

.PARAMETER DotSourceOnly
    Internal/testing switch. When present, the script defines its functions and returns
    immediately without executing the main flow. Intended for Pester dot-sourcing.

.PARAMETER Help
    Displays full help (manpage-style) and exits.

.EXAMPLE
    .\Buster-MyConnection.ps1
    Executes with defaults, auto-detecting the best connectivity strategy.

.EXAMPLE
    .\Buster-MyConnection.ps1 -Force PROXY
    Forces corporate proxy mode using upstream proxy from cntlm.ini.

.EXAMPLE
    .\Buster-MyConnection.ps1 -JustCheck
    Runs diagnostics on all strategies without making changes.

.NOTES
    File Name : Buster-MyConnection.ps1
    Author    : Yorga Babuscan (yorgabr@gmail.com)
    Version   : 2.8.1

.LINK
    https://github.com/yorgabr/BusterMyConnection
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

    # Internal: define functions only, skip main flow (used by Pester).
    [Parameter(ParameterSetName='Standard')]
    [Parameter(ParameterSetName='Force')]
    [Parameter(ParameterSetName='Check')]
    [switch]$DotSourceOnly,

    [Parameter(ParameterSetName='Help')]
    [Alias('h','?')]
    [switch]$Help
)

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Full
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#---------------------------------
# Quiet / Verbose policy
#---------------------------------
$IsVerbose = $PSBoundParameters.ContainsKey('Verbose')
# Informational output is shown unless explicitly silenced. Errors/warnings always show.
$script:QuietMode = [bool]$Quiet

#---------------------------------
# Script Metadata
#---------------------------------
$SCRIPT_VERSION = '2.8.1'
$SCRIPT_NAME    = 'Buster-MyConnection'

#---------------------------------
# Output helpers
#---------------------------------
function Out-Info {
    param([string]$Message)
    if (-not $script:QuietMode -or $IsVerbose) {
        Write-Host "[INFO] $Message"
    }
}

function Out-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Out-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Out-Error {
    param([string]$Message)
    # Business-level failures are control flow (callers return $false / exit 1),
    # not terminating exceptions. Emit to the error stream without honoring the
    # script-wide 'Stop' preference, so functions can complete their return path.
    Write-Error $Message -ErrorAction Continue
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
            Domain     = $Domain
            Username   = $Username
            Credential = $Credential
            Timestamp  = (Get-Date).ToString('o')
        } | Export-Clixml -Path $CredentialCachePath -Force
        Write-Verbose "Cached credentials for $Domain\$Username"
    } catch {
        Write-Verbose "Failed to cache credentials: $($_.Exception.Message)"
    }
}

function Get-ProxyCredential {
    param([string]$Domain, [string]$Username, [switch]$UseCache)

    if ($UseCache) {
        $cached = Get-StoredProxyCredential -Domain $Domain -Username $Username
        if ($cached) {
            Out-Info "Using cached credentials for $Domain\$Username"
            return $cached
        }
    }

    Out-Info "Corporate proxy requires authentication."

    # NTLM identity needs the domain; this is NOT what goes into a URL userinfo.
    if ($Domain) {
        $fullUsername = "$Domain\$Username"
    } else {
        $fullUsername = $Username
    }

    Write-Host "`nPlease enter your credentials for proxy authentication:" -ForegroundColor Cyan
    Write-Host "Username: $fullUsername" -ForegroundColor Gray

    $securePassword = Read-Host "Password" -AsSecureString
    $credential = New-Object System.Management.Automation.PSCredential($fullUsername, $securePassword)

    $cacheChoice = Read-Host "`nCache credentials securely for future use? (Y/N)"
    if ($cacheChoice -eq 'Y' -or $cacheChoice -eq 'y') {
        Set-StoredProxyCredential -Domain $Domain -Username $Username -Credential $credential
    }

    return $credential
}

#---------------------------------
# Proxy URL construction (the core fix)
#---------------------------------
function ConvertTo-ProxyUserInfo {
    <#
        Builds the userinfo segment (user:pass@) of an HTTP proxy URL.
        Critically, it strips any NTLM domain prefix (DOMAIN\user or user@DOMAIN)
        because a backslash or slash in userinfo makes Git/libcurl treat the URL as
        having a path, which only SOCKS proxies support. The username and password are
        URL-encoded so reserved characters survive.
    #>
    param(
        [string]$Username,
        [string]$Password
    )

    if ([string]::IsNullOrEmpty($Username)) {
        return ''
    }

    # Strip DOMAIN\user
    $bare = $Username
    if ($bare -match '\\') {
        $bare = ($bare -split '\\', 2)[1]
    }
    # Strip user@DOMAIN (UPN form), keep the left side
    elseif ($bare -match '@') {
        $bare = ($bare -split '@', 2)[0]
    }

    $encUser = [System.Uri]::EscapeDataString($bare)

    if ([string]::IsNullOrEmpty($Password)) {
        return "${encUser}@"
    }

    $encPass = [System.Uri]::EscapeDataString($Password)
    return "${encUser}:${encPass}@"
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
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)(proxy|pip_.*index|uv_.*index)' } |
        ForEach-Object { $backup[$_.Key] = $_.Value }
    return $backup
}

function Remove-ProxyEnvironmentVariables {
    # Captures a backup before removal and returns it so callers can persist state.
    $backup = Backup-ProxyEnvironmentVariables
    $count  = 0
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)(proxy|pip_.*index|uv_.*index)' } |
        ForEach-Object {
            Write-Verbose "Unsetting $($_.Key)"
            Remove-Item "Env:\$($_.Key)" -ErrorAction SilentlyContinue
            $count++
        }
    return [pscustomobject]@{
        Backup = $backup
        Count  = $count
    }
}

function Restore-ProxyEnvironmentVariables {
    param($Variables)
    if (-not $Variables) { return }

    # Accept both hashtables and PSCustomObjects (from JSON).
    if ($Variables -is [hashtable]) {
        foreach ($key in $Variables.Keys) {
            $val = $Variables[$key]
            if ($null -ne $val) {
                [System.Environment]::SetEnvironmentVariable($key, $val, 'Process')
            }
        }
        return
    }

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

    Out-Info "Proxy environment variables exported for CNTLM on port $Port"
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
        $password  = $Credential.GetNetworkCredential().Password
        $userInfo  = ConvertTo-ProxyUserInfo -Username $Credential.UserName -Password $password
        $proxy     = "http://${userInfo}${ProxyAddress}:${ProxyPort}"
    } else {
        $proxy = "http://${ProxyAddress}:${ProxyPort}"
    }

    [System.Environment]::SetEnvironmentVariable('HTTP_PROXY',  $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('ALL_PROXY',   $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('NO_PROXY',    $NoProxy, 'Process')

    # Log without leaking credentials.
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
        Proxy     = $null
        ProxyPort = $null
        Listen    = 3128
        Domain    = $null
        Username  = $null
        NoProxy   = 'localhost,127.0.0.1'
    }

    Get-Content $IniPath | ForEach-Object {
        $line = $_.Trim()

        if ($line -match '^Proxy\s+(.+):(\d+)') {
            $config.Proxy = $matches[1]
            $config.ProxyPort = [int]$matches[2]
        }
        elseif ($line -match '^Listen\s+(?:[\d\.]+:)?(\d+)') {
            $config.Listen = [int]$matches[1]
        }
        elseif ($line -match '^Domain\s+(.+)') {
            $config.Domain = $matches[1].Trim()
        }
        elseif ($line -match '^Username\s+(.+)') {
            $config.Username = $matches[1].Trim()
        }
        elseif ($line -match '^NoProxy\s+(.+)') {
            $noProxyValue = $matches[1]
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
                Uri             = $url
                Proxy           = $ProxyUrl
                TimeoutSec      = $TimeoutSeconds
                UseBasicParsing = $true
            }
            if ($Credential) {
                $params['ProxyCredential'] = $Credential
            }

            Invoke-WebRequest @params | Out-Null
            Write-Verbose "Proxy connectivity test succeeded: $url via $ProxyUrl"
        } catch {
            $errorMsg = $_.Exception.Message
            Write-Verbose "Proxy connectivity test failed: $url via $ProxyUrl - $errorMsg"
            Out-Warn "Proxy connectivity test failed for $url via ${ProxyUrl}: $errorMsg"
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
# CNTLM Installation (via Scoop)
#---------------------------------
function Install-CntlmViaScoop {
    <#
        Installs CNTLM through Scoop (https://scoop.sh) instead of downloading a
        hand-picked binary over plain HTTP. Scoop resolves the package over HTTPS,
        verifies its hash against the manifest, and manages upgrades/uninstalls,
        which removes the integrity risk of an unauthenticated zip download.
    #>
    Out-Info "CNTLM not found. Installing via Scoop..."

    $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $scoopCmd) {
        throw "Scoop is not installed. Install it first (as your own user, not elevated): " +
              "irm get.scoop.sh | iex -- then re-run this script. See https://scoop.sh"
    }

    try {
        & scoop install cntlm 2>&1 | ForEach-Object { Write-Verbose $_ }
    } catch {
        throw "Failed to install CNTLM via Scoop: $($_.Exception.Message)"
    }

    $exePath = (& scoop which cntlm 2>$null)
    if (-not $exePath) {
        $fallbackCmd = Get-Command cntlm.exe -ErrorAction SilentlyContinue
        if ($fallbackCmd) {
            $exePath = $fallbackCmd.Source
        }
    }

    if (-not $exePath -or -not (Test-Path $exePath)) {
        throw "Scoop reported CNTLM as installed, but cntlm.exe could not be located afterwards."
    }

    Out-Success "CNTLM installed successfully via Scoop: $exePath"
    return $exePath
}

function Resolve-CntlmExecutable {
    param([string]$Path)
    if (Test-Path $Path) {
        Out-Info "CNTLM found at $Path"
        return $Path
    }
    return Install-CntlmViaScoop
}

#---------------------------------
# CNTLM Configuration Wizard
#---------------------------------
function Get-CntlmNtlmHash {
    <#
        Runs `cntlm.exe -H` to derive the NTLM/NTLMv2 password hashes for the given
        account, feeding the password over stdin (never as a command-line argument,
        which would leak it into the process list). Returns the PassLM/PassNT/
        PassNTLMv2 lines exactly as cntlm prints them, ready to drop into cntlm.ini.
    #>
    param(
        [string]$CntlmExePath,
        [string]$Username,
        [string]$Domain,
        [string]$Password
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CntlmExePath
    $psi.Arguments = "-H -u $Username -d $Domain"
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.Close()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw "cntlm -H exited with code $($proc.ExitCode): $stderr"
    }

    $hashLines = $stdout -split "`r?`n" | Where-Object { $_ -match '^Pass(LM|NT|NTLMv2)\s' }
    if (-not $hashLines) {
        throw "cntlm -H produced no recognizable hash lines."
    }

    return $hashLines
}

function New-CntlmConfiguration {
    param(
        [string]$OutputPath,
        # Path to a working cntlm.exe, used to derive password hashes so the
        # plaintext password never touches disk. Optional: if omitted or the
        # binary can't run '-H' yet, the wizard falls back to storing the
        # plaintext password and warns the user to hash it manually later.
        [string]$CntlmExePath
    )

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

    $credentialLines = $null
    if ($CntlmExePath -and (Test-Path $CntlmExePath)) {
        try {
            $hashLines = Get-CntlmNtlmHash -CntlmExePath $CntlmExePath -Username $username -Domain $domain -Password $plainPassword
            $credentialLines = $hashLines -join "`r`n"
            Out-Success "Generated NTLM password hash automatically; the plaintext password will not be stored."
        } catch {
            Out-Warn "Could not generate NTLM hash automatically ($($_.Exception.Message)); storing the plaintext password instead."
        }
    }

    if (-not $credentialLines) {
        $credentialLines = "Password    $plainPassword"
        Out-Warn "For production use, generate a proper NTLM hash using: cntlm -H -u $username -d $domain"
    }

    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plainPassword = $null

    $configContent = @"
# CNTLM Configuration
# Generated by $SCRIPT_NAME v$SCRIPT_VERSION on $(Get-Date)

Username    $username
Domain      $domain
$credentialLines
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

    $removal = Remove-ProxyEnvironmentVariables

    if (Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
        Out-Success "DIRECT ACCESS mode activated and verified."
        Set-ExecutionState -Mode 'DirectAccess' -ProxyVariables $removal.Backup
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

        $credential = Get-ProxyCredential -Domain $config.Domain -Username $config.Username -UseCache

        Remove-ProxyEnvironmentVariables | Out-Null
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

    try {
        $resolvedExe = Resolve-CntlmExecutable -Path $CntlmPath
    } catch {
        Out-Error "Failed to resolve CNTLM executable: $($_.Exception.Message)"
        return $false
    }

    if (-not (Test-Path $IniPath)) {
        Out-Info "CNTLM configuration not found. Launching configuration wizard..."
        try {
            $IniPath = New-CntlmConfiguration -OutputPath $IniPath -CntlmExePath $resolvedExe
        } catch {
            Out-Error "Configuration wizard failed: $($_.Exception.Message)"
            return $false
        }
    }

    try {
        $config = Get-CntlmConfiguration -IniPath $IniPath
        $listenPort = $config.Listen
        $noProxy = $config.NoProxy

        Out-Info "CNTLM Configuration:"
        Out-Info "  Listen Port: $listenPort"
        Out-Info "  NoProxy: $noProxy"
        Out-Info "  Upstream Proxy: $($config.Proxy):$($config.ProxyPort)"
    } catch {
        Out-Error "Failed to parse CNTLM configuration: $($_.Exception.Message)"
        return $false
    }

    try {
        Start-CntlmProcess -ExePath $resolvedExe -IniPath $IniPath
    } catch {
        Out-Error "Failed to start CNTLM: $($_.Exception.Message)"
        return $false
    }

    if (-not (Test-CntlmRunning)) {
        Out-Error "CNTLM process is not running after startup attempt."
        Out-Info "Troubleshooting tips:"
        Out-Info "  1. Check if the CNTLM configuration file is valid"
        Out-Info "  2. Verify upstream proxy is accessible: $($config.Proxy):$($config.ProxyPort)"
        Out-Info "  3. Check CNTLM logs (if available)"
        Out-Info "  4. Ensure no other process is using port $listenPort"
        return $false
    }

    Out-Success "CNTLM process is running."

    Remove-ProxyEnvironmentVariables | Out-Null
    Set-ProxyEnvironmentForCntlm -Port $listenPort -NoProxy $noProxy

    Start-Sleep -Seconds 1

    if (-not (Test-TcpPort -Address '127.0.0.1' -Port $listenPort -TimeoutSeconds 3)) {
        Out-Error "CNTLM is running but not listening on port $listenPort"
        Out-Info "Please check CNTLM configuration and logs."
        Stop-CntlmProcess
        return $false
    }

    Out-Info "Testing CNTLM proxy connectivity..."
    $proxyUrl = "http://127.0.0.1:$listenPort"
    if (Test-ProxyConnectivity -ProxyUrl $proxyUrl -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
        Out-Success "CNTLM PROXY mode activated and verified."
        Set-ExecutionState -Mode 'Proxied'
        return $true
    } else {
        Out-Error "CNTLM PROXY mode failed connectivity test."
        Out-Info "Possible causes:"
        Out-Info "  1. Upstream proxy $($config.Proxy):$($config.ProxyPort) is not accessible"
        Out-Info "  2. Invalid credentials in cntlm.ini"
        Out-Info "  3. CNTLM configuration error"
        Out-Info "  4. Network/firewall blocking external connectivity"
        Stop-CntlmProcess
        return $false
    }
}

#---------------------------------
# Testability guard: stop here when only function definitions are needed.
#---------------------------------
if ($DotSourceOnly) {
    return
}

#---------------------------------
# JUSTCHECK MODE
#---------------------------------
if ($JustCheck) {
    Out-Info "JustCheck mode: evaluating connectivity without changes."
    Out-Info "Current proxy environment variables:"
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)(proxy|pip_.*index|uv_.*index)' } | ForEach-Object {
        Write-Host "  $($_.Key) = $($_.Value)"
    }

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

Out-Info "=== Auto-detection mode ==="
Out-Info "Evaluating optimal connectivity strategy..."

$previousState = Get-PreviousExecutionState
if ($previousState -and $previousState.Mode -eq 'DirectAccess') {
    Out-Info "Restoring proxy variables from previous direct access session."
    Restore-ProxyEnvironmentVariables $previousState.ProxyVariables
}

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
            $IniPath = New-CntlmConfiguration -OutputPath $IniPath -CntlmExePath $resolvedExe
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
                Stop-CntlmProcess
            }
        }
    } catch {
        Out-Warn "CNTLM startup failed: $($_.Exception.Message)"
    }
}

Out-Info "Strategy 2: Corporate proxy mode requires manual activation with -Force PROXY"
Out-Info "Skipping in auto-detection mode to avoid credential prompts."

Out-Info "Strategy 3: Attempting direct access mode..."
$removal = Remove-ProxyEnvironmentVariables

if (Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
    Out-Success "DIRECT ACCESS mode activated (auto-detected)."
    Set-ExecutionState -Mode 'DirectAccess' -ProxyVariables $removal.Backup
    Out-Info "Final strategy: DIRECT ACCESS MODE."
    exit 0
}

Out-Error "No viable connectivity strategy available. Try: -Force DIRECT, -Force PROXY, or -Force CNTLM"
exit 1