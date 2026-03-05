#!/usr/bin/env pwsh

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

    I implemented a decorator-based VPN detection system that allows seamless extension 
    for different VPN clients. I'd just implemented one for BIG-IP Edge Client VPN 
    environments (my corporate pain in neck case...). When it senses the presence of a 
    local PAC file served by the VPN client, it dynamically reconciles the upstream proxy 
    settings to maintain seamless connectivity. I encourage you to add a decorator for 
    your specific VPN client. See detais in CONTRIBUTING.md file.

    The script operates idempotently, allowing repeated execution without side effects,
    and can manage existing CNTLM processes through the KeepExisting switch. All output
    respects the -Quiet flag for automation scenarios, and comprehensive logging ensures
    operational transparency.

    The -JustCheck switch provides a comprehensive diagnostic mode that inspects the
    current CNTLM instance (if running), analyzes its configuration, and performs
    connectivity tests without making any changes to the system. This is useful for
    troubleshooting and health monitoring.
    
    The implementation remains compatible across Windows PowerShell 5.1 and PowerShell 
    Core 6/7+, gracefully degrading functionality when WinINET APIs are unavailable 
    while preserving core operational capabilities.
    
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
#>
#!/usr/bin/env pwsh

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
    the user in a guided interview to establish the essential proxy settings.

    The script implements a stateful connection management system that tracks whether
    the previous execution was in "direct access" mode (proxy variables unset). When
    transitioning back to a proxied environment (VPN active, corporate network detected),
    it automatically restores the appropriate proxy environment variables before 
    attempting CNTLM startup.

    A health-check mechanism validates the upstream proxy server declared in cntlm.ini. 
    If the parent proxy is unreachable, the script gracefully degrades by removing all 
    proxy-related environment variables, allowing direct internet access. This prevents 
    connectivity deadlocks when the corporate proxy infrastructure is unavailable.

    The decorator-based VPN detection system allows seamless extension for different 
    VPN clients. Currently implemented for BIG-IP Edge Client VPN environments. When a VPN
    is detected with an active proxy, the script ensures environment variables are 
    reconciled and validates connectivity before starting CNTLM.

    The -JustCheck switch provides a comprehensive diagnostic mode that inspects the
    current CNTLM instance (if running), analyzes its configuration, and performs
    connectivity tests without making any changes to the system. This is useful for
    troubleshooting and health monitoring.

    The script operates idempotently, allowing repeated execution without side effects,
    and can manage existing CNTLM processes through the KeepExisting switch. All output
    respects the Quiet flag for automation scenarios, and comprehensive logging ensures
    operational transparency.

.EXAMPLE
    Buster-MyConnection
    Executes with defaults, triggering auto-installation and configuration wizard if needed.
    If upstream proxy is dead, unsets proxy vars and exits with code 0 (direct access mode).
    If transitioning from direct mode back to proxy mode, restores environment variables.

.EXAMPLE
    Buster-MyConnection -JustCheck
    Performs comprehensive diagnostics only: checks for running CNTLM, analyzes 
    configuration, and tests connectivity. No changes are made to the system.

.EXAMPLE
    Buster-MyConnection -IniPath "C:\Tools\cntlm.ini" -KeepExisting
    Uses an alternate configuration while preserving any running CNTLM instances.

.NOTES
    All user-facing messages and logs are emitted in English to maintain consistency 
    across international environments and facilitate troubleshooting in heterogeneous 
    teams. Internal documentation and comments follow the same convention, ensuring the 
    codebase remains accessible to contributors regardless of their locale.
#>
[CmdletBinding()]
param(
    [string]$IniPath = (Join-Path -Path $HOME -ChildPath 'cntlm.ini'),
    [string]$CntlmPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs/CNTLM/cntlm.exe'),
    [string]$LogDirectory = $env:TEMP,
    [switch]$KeepExisting,
    [switch]$Quiet,
    [int]$ProxyTestTimeoutSeconds = 5,
    [int]$ProxyTestPort = 80,
    [int]$DirectAccessTestTimeoutSeconds = 10,
    [switch]$JustCheck,
    [int]$CheckTimeoutSeconds = 30,
    [int]$CheckRetries = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#------------------------------
# Color helpers for rich console output 
#------------------------------
$ESC = "`e"
$Cyan   = "${ESC}[36m"
$Yellow = "${ESC}[33m"
$Green  = "${ESC}[32m"
$Red    = "${ESC}[31m"
$Reset  = "${ESC}[0m"

function Out-Info { 
    param([string]$Message) 
    if (-not $Quiet) { 
        [Console]::Out.WriteLine("$Cyan[INFO]$Reset $Message") 
    } 
}

function Out-Warn { 
    param([string]$Message) 
    if (-not $Quiet) { 
        [Console]::Out.WriteLine("$Yellow[WARN]$Reset $Message") 
    } 
}

function Out-Success { 
    param([string]$Message) 
    if (-not $Quiet) { 
        [Console]::Out.WriteLine("$Green[SUCCESS]$Reset $Message") 
    } 
}

function Out-Error { 
    param([string]$Message) 
    [Console]::Error.WriteLine("$Red[ERROR]$Reset $Message") 
}

function Test-IsWindowsPowerShell { 
    return $PSVersionTable.PSEdition -eq 'Desktop' 
}

#------------------------------
# State Management: Track direct access mode across executions
#------------------------------
$StateFilePath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Buster-MyConnection\state.json'

function Get-PreviousExecutionState {
    [CmdletBinding()]
    param()
    
    if (Test-Path -LiteralPath $StateFilePath) {
        try {
            $state = Get-Content -LiteralPath $StateFilePath -Raw | ConvertFrom-Json
            return $state
        }
        catch {
            Out-Warn "Failed to read previous execution state: $($_.Exception.Message)"
            return $null
        }
    }
    return $null
}

function Set-ExecutionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('DirectAccess', 'Proxied')]
        [string]$Mode,
        
        [hashtable]$ProxyVariables = @{}
    )
    
    $stateDir = Split-Path -Parent -Path $StateFilePath
    if (-not (Test-Path $stateDir)) {
        $null = New-Item -ItemType Directory -Path $stateDir -Force
    }
    
    $state = [ordered]@{
        LastExecutionTime = (Get-Date -Format 'o')
        Mode = $Mode
        ProxyVariables = $ProxyVariables
        Version = $SCRIPT_VERSION
    }
    
    try {
        $state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StateFilePath -Force
        Out-Info "Execution state persisted: $Mode mode"
    }
    catch {
        Out-Warn "Failed to persist execution state: $($_.Exception.Message)"
    }
}

#------------------------------
# Proxy environment variable management 
#------------------------------
function Backup-ProxyEnvironmentVariables {
    [CmdletBinding()]
    param()
    
    $proxyPattern = [regex]'(?i)proxy'
    $backup = @{}
    
    Get-ChildItem Env: | Where-Object { 
        $proxyPattern.IsMatch($_.Name) 
    } | ForEach-Object {
        $backup[$_.Name] = $_.Value
    }
    
    return $backup
}

function Remove-ProxyEnvironmentVariables {
    [CmdletBinding()]
    param()
    
    $proxyPattern = [regex]'(?i)proxy'
    $removedCount = 0
    $backup = @{}
    
    $proxyVars = Get-ChildItem Env: | Where-Object { 
        $proxyPattern.IsMatch($_.Name) 
    }
    
    if (-not $proxyVars) {
        Out-Info "No proxy-related environment variables found to remove."
        return @{ Count = 0; Backup = @{} }
    }
    
    Out-Warn "Removing $($proxyVars.Count) proxy-related environment variable(s) from current session..."
    
    foreach ($var in $proxyVars) {
        try {
            $path = "Env:\$($var.Name)"
            if (Test-Path $path) {
                $backup[$var.Name] = $var.Value
                Remove-Item -Path $path -Force -ErrorAction Stop
                Out-Info "Unset: $($var.Name)"
                $removedCount++
            }
        }
        catch {
            Out-Warn "Failed to remove $($var.Name): $($_.Exception.Message)"
        }
    }
    
    return @{
        Count = $removedCount
        Backup = $backup
    }
}

function Restore-ProxyEnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Variables
    )
    
    if (-not $Variables -or $Variables.Count -eq 0) {
        Out-Warn "No proxy variables to restore from backup."
        return 0
    }
    
    Out-Info "Restoring $($Variables.Count) proxy environment variable(s) from previous session..."
    $restoredCount = 0
    
    foreach ($varName in $Variables.Keys) {
        try {
            [Environment]::SetEnvironmentVariable($varName, $Variables[$varName], 'Process')
            Out-Info "Restored: $varName"
            $restoredCount++
        }
        catch {
            Out-Warn "Failed to restore $varName`: $($_.Exception.Message)"
        }
    }
    
    return $restoredCount
}

#------------------------------
# Connectivity Testing
#------------------------------
function Test-InternetConnectivity {
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 10
    )
    
    $testTargets = @(
        @{ Url = 'http://httpbin.org/get'; Name = 'HTTPBin (HTTP)' }
        @{ Url = 'https://httpbin.org/get'; Name = 'HTTPBin (HTTPS)' }
        @{ Url = 'https://www.microsoft.com/'; Name = 'Microsoft' }
    )
    
    Out-Info "Testing direct internet connectivity..."
    
    foreach ($target in $testTargets) {
        try {
            $response = Invoke-WebRequest -Uri $target.Url -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
            Out-Success "Direct connectivity verified via $($target.Name) (Status: $($response.StatusCode))"
            return $true
        }
        catch {
            Out-Warn "Failed to reach $($target.Name): $($_.Exception.Message)"
        }
    }
    
    Out-Error "All direct connectivity tests failed. Internet may be unavailable."
    return $false
}

function Test-ProxyConnectivity {
    [CmdletBinding()]
    param(
        [int]$ProxyPort = 3128,
        [int]$TimeoutSeconds = 10
    )
    
    $proxyUrl = "http://127.0.0.1:$ProxyPort"
    $testTargets = @(
        @{ Url = 'http://httpbin.org/get'; Name = 'HTTP via CNTLM' }
        @{ Url = 'https://httpbin.org/get'; Name = 'HTTPS via CNTLM' }
    )
    
    Out-Info "Testing connectivity through CNTLM proxy at $proxyUrl..."
    
    foreach ($target in $testTargets) {
        try {
            $response = Invoke-WebRequest -Uri $target.Url -Proxy $proxyUrl -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
            Out-Success "$($target.Name) successful (Status: $($response.StatusCode))"
        }
        catch {
            Out-Error "$($target.Name) failed: $($_.Exception.Message)"
            return $false
        }
    }
    
    return $true
}

#------------------------------
# Upstream proxy health check 
#------------------------------
function Test-UpstreamProxyConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$IniPath,
        
        [int]$TimeoutSeconds = 5,
        [int]$TestPort = 80
    )
    
    if (-not (Test-Path -LiteralPath $IniPath)) {
        Out-Warn "Configuration file not found: $IniPath"
        return $false
    }
    
    $content = Get-Content -LiteralPath $IniPath -Raw
    $proxyMatches = [regex]::Matches($content, '(?im)^\s*Proxy\s+([^\s:]+):(\d+)')
    
    if ($proxyMatches.Count -eq 0) {
        Out-Warn "No Proxy entries found in $IniPath"
        return $false
    }
    
    $firstProxy = $proxyMatches[0]
    $proxyHost = $firstProxy.Groups[1].Value.Trim()
    $proxyPort = [int]$firstProxy.Groups[2].Value
    
    Out-Info "Testing connectivity to upstream proxy: ${proxyHost}:${proxyPort}"
    
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connection = $tcpClient.BeginConnect($proxyHost, $proxyPort, $null, $null)
        $success = $connection.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds), $false)
        
        if ($success -and $tcpClient.Connected) {
            $tcpClient.Close()
            Out-Success "Upstream proxy ${proxyHost}:${proxyPort} is responsive."
            return $true
        }
        else {
            $tcpClient.Close()
            Out-Warn "Upstream proxy ${proxyHost}:${proxyPort} is NOT responding (timeout after ${TimeoutSeconds}s)."
            return $false
        }
    }
    catch {
        Out-Warn "Failed to connect to upstream proxy ${proxyHost}:${proxyPort}: $($_.Exception.Message)"
        return $false
    }
}

#==============================
# CONNECTION CHECK MODE (from Check-Cntlm.ps1)
#==============================

function Get-ListeningProcessForPort {
    param([int]$TargetPort)
    
    $connections = @()
    
    try {
        $connections = Get-NetTCPConnection -State Listen -ErrorAction Stop | 
                       Where-Object { $_.LocalPort -eq $TargetPort }
    } 
    catch {
        Out-Warn "Get-NetTCPConnection unavailable. Falling back to netstat."
        $netstatLines = netstat -ano | Select-String '\sLISTENING\s+\d+$'
        
        foreach ($line in $netstatLines) {
            if ($line -match "^\s*\S+\s+\S+:$TargetPort\s+\S+\s+LISTENING\s+(\d+)$") {
                $connections += [pscustomobject]@{
                    LocalPort     = $TargetPort
                    OwningProcess = [int]$Matches[1]
                }
            }
        }
    }
    
    return $connections
}

function Get-ProcessMetadata {
    param([Parameter(Mandatory=$true)][int]$ProcessId)
    
    $metadata = [ordered]@{
        ProcessId      = $ProcessId
        ExecutablePath = $null
        CommandLine    = $null
        Provider       = $null
    }
    
    try {
        $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($cimProcess) {
            $metadata.ExecutablePath = $cimProcess.ExecutablePath
            $metadata.CommandLine    = $cimProcess.CommandLine
            $metadata.Provider       = 'CIM'
            return $metadata
        }
    } 
    catch {}
    
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            $wmiProcess = Get-WmiObject Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
            if ($wmiProcess) {
                $metadata.ExecutablePath = $wmiProcess.ExecutablePath
                $metadata.CommandLine    = $wmiProcess.CommandLine
                $metadata.Provider       = 'WMI'
                return $metadata
            }
        } 
        catch {}
    }
    
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($process) {
            $metadata.ExecutablePath = $process.Path
            $metadata.Provider       = 'Get-Process'
            return $metadata
        }
    } 
    catch {}
    
    try {
        $wmicOutput = cmd /c "wmic process where ProcessId=$ProcessId get ExecutablePath,CommandLine /format:list" 2>$null
        if ($wmicOutput) {
            $execLine = ($wmicOutput | Where-Object { $_ -like 'ExecutablePath=*' })
            $cmdLine  = ($wmicOutput | Where-Object { $_ -like 'CommandLine=*' })
            
            if ($execLine) { 
                $metadata.ExecutablePath = ($execLine -replace '^ExecutablePath=','') 
            }
            if ($cmdLine)  { 
                $metadata.CommandLine = ($cmdLine -replace '^CommandLine=','') 
            }
            $metadata.Provider = 'wmic'
            return $metadata
        }
    } 
    catch {}
    
    return $metadata
}

function Get-ConfigPathFromCommandLine {
    param([string]$CommandLine)
    
    if (-not $CommandLine) { return $null }
    
    $patterns = @(
        '-c\s+"([^"]+)"',
        '-c\s+(\S+)',
        '--config\s+"([^"]+)"',
        '--config\s+(\S+)'
    )
    
    foreach ($pattern in $patterns) {
        $match = [regex]::Match($CommandLine, $pattern)
        if ($match.Success) { 
            return $match.Groups[1].Value 
        }
    }
    
    return $null
}

function Find-CntlmConfigurationFiles {
    param([string]$ExecutablePath)
    
    $candidates = @()
    
    if ($ExecutablePath) {
        $exeDirectory = Split-Path $ExecutablePath -Parent
        if ($exeDirectory -and (Test-Path $exeDirectory)) {
            $localConfig = Get-ChildItem -Path $exeDirectory -Filter 'cntlm.ini' -Force -ErrorAction SilentlyContinue
            if ($localConfig) { 
                $candidates += $localConfig 
            }
        }
    }
    
    $systemPaths = @(
        "${env:ProgramFiles}\Cntlm",
        "${env:ProgramFiles(x86)}\Cntlm",
        "${env:ProgramData}\cntlm",
        "C:\dev-env\cntlm",
        "C:\dev-env"
    )
    
    foreach ($path in $systemPaths) {
        if (Test-Path $path) {
            $foundConfigs = Get-ChildItem -Path $path -Filter 'cntlm.ini' -Force -ErrorAction SilentlyContinue
            if ($foundConfigs) { 
                $candidates += $foundConfigs 
            }
        }
    }
    
    if (-not $candidates -or $candidates.Count -eq 0) {
        $userProfile = $env:UserProfile
        if ($userProfile -and (Test-Path $userProfile)) {
            $profileConfigs = Get-ChildItem -Path $userProfile -Filter 'cntlm.ini' -Recurse -Force -ErrorAction SilentlyContinue
            if ($profileConfigs) { 
                $candidates += $profileConfigs 
            }
        }
    }
    
    return $candidates | Select-Object FullName, Length, LastWriteTime | Sort-Object FullName -Unique
}

function Test-CntlmConfiguration {
    param([Parameter(Mandatory=$true)][string]$ConfigPath)
    
    if (-not (Test-Path $ConfigPath)) {
        Out-Error "Configuration file not found: ${ConfigPath}"
        return $null
    }
    
    Out-Info "Analyzing configuration: ${ConfigPath}"
    
    try {
        $lines = Get-Content -LiteralPath $ConfigPath -ErrorAction Stop
    }
    catch {
        Out-Error "Failed to read configuration file: $($_.Exception.Message)"
        return $null
    }
    
    $configValues = @{}
    
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        
        $match = [regex]::Match($trimmed, '^(?<key>[A-Za-z][A-Za-z0-9_]*)\s+(?<value>.+)$')
        if ($match.Success) {
            $key = $match.Groups['key'].Value
            $value = $match.Groups['value'].Value.Trim()
            $configValues[$key] = $value
        }
    }
    
    $requiredKeys = @('Username', 'Proxy', 'Listen')
    foreach ($key in $requiredKeys) {
        if ($configValues.ContainsKey($key)) {
            Out-Info "${key}: $($configValues[$key])"
        } else {
            Out-Warn "Required directive missing: ${key}"
        }
    }
    
    $hashKeys = @('PassLM', 'PassNT', 'PassNTLMv2')
    $hashFound = $false
    foreach ($hashKey in $hashKeys) {
        if ($configValues.ContainsKey($hashKey)) {
            $hashFound = $true
            Out-Info "${hashKey}: [hash present]"
        }
    }
    
    if (-not $hashFound -and $configValues.ContainsKey('Password')) {
        Out-Warn "Plaintext password detected. Consider migrating to NTLM hashes using 'cntlm -H' for improved security."
    } 
    elseif (-not $hashFound) {
        Out-Warn "No authentication hashes found. Generate using 'cntlm -H -u <user> -d <domain>' and configure PassLM/PassNT/PassNTLMv2."
    }
    
    if ($configValues.ContainsKey('NoProxy')) {
        Out-Info "NoProxy: $($configValues['NoProxy'])"
    }
    
    return [pscustomobject]@{
        ConfigPath   = $ConfigPath
        Settings     = $configValues
        HasHashes    = $hashFound
        HasPlaintext = $configValues.ContainsKey('Password')
    }
}

function Test-ProxyWithCurl {
    param(
        [int]$TargetPort,
        [int]$TimeoutSeconds = 30,
        [int]$MaxRetries = 2
    )
    
    $proxyUrl = "http://127.0.0.1:$TargetPort"
    
    Out-Info "Testing HTTP connectivity via ${proxyUrl} → http://httpbin.org/get "
    $httpSuccess = $false
    $httpStatus = $null
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($attempt -gt 1) {
            Out-Warn "HTTP test attempt $attempt of $MaxRetries..."
            Start-Sleep -Seconds 1
        }
        
        try {
            $stderrFile = [System.IO.Path]::GetTempFileName()
            $httpStatus = curl.exe -sS --max-time $TimeoutSeconds -o NUL -w "%{http_code}" `
                --proxy $proxyUrl http://httpbin.org/get  2>$stderrFile
            
            $httpError = Get-Content -Path $stderrFile -ErrorAction SilentlyContinue
            Remove-Item -Path $stderrFile -ErrorAction SilentlyContinue
            
            if ($httpStatus -match '^\d{3}$') {
                if ($httpStatus -match '^[23]\d{2}$') {
                    $httpSuccess = $true
                    break
                }
            } else {
                Out-Warn "Invalid HTTP status: '$httpStatus'"
                if ($httpError) { Out-Warn "curl: $httpError" }
            }
        }
        catch {
            Out-Warn "HTTP test failed on attempt ${attempt}: $($_.Exception.Message)"
        }
    }
    
    Out-Info "HTTP final status: ${httpStatus}"
    if ($httpSuccess) {
        Out-Success "HTTP test passed (status ${httpStatus})"
    } 
    else {
        Out-Error "HTTP test failed after $MaxRetries attempts"
    }
    
    Out-Info "Testing HTTPS connectivity via ${proxyUrl} → https://httpbin.org/get "
    $httpsSuccess = $false
    $httpsStatus = $null
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($attempt -gt 1) {
            Out-Warn "HTTPS test attempt $attempt of $MaxRetries..."
            Start-Sleep -Seconds 1
        }
        
        try {
            $stderrFile = [System.IO.Path]::GetTempFileName()
            $httpsStatus = curl.exe -sS --max-time $TimeoutSeconds -o NUL -w "%{http_code}" `
                --proxy $proxyUrl https://httpbin.org/get  2>$stderrFile
            
            $httpsError = Get-Content -Path $stderrFile -ErrorAction SilentlyContinue
            Remove-Item -Path $stderrFile -ErrorAction SilentlyContinue
            
            if ($httpsStatus -match '^\d{3}$') {
                if ($httpsStatus -match '^[23]\d{2}$') {
                    $httpsSuccess = $true
                    break
                }
            } else {
                Out-Warn "Invalid HTTPS status: '$httpsStatus'"
                if ($httpsError) { Out-Warn "curl: $httpsError" }
            }
        }
        catch {
            Out-Warn "HTTPS test failed on attempt ${attempt}: $($_.Exception.Message)"
        }
    }
    
    Out-Info "HTTPS final status: ${httpsStatus}"
    if ($httpsSuccess) {
        Out-Success "HTTPS test passed (status ${httpsStatus})"
    } 
    else {
        Out-Error "HTTPS test failed after $MaxRetries attempts"
    }
    
    return ($httpSuccess -and $httpsSuccess)
}

function Invoke-ConnectionCheck {
    <#
    .SYNOPSIS
        Performs comprehensive diagnostics of the current CNTLM connection state.
    
    .DESCRIPTION
        This function implements the -JustCheck mode, providing detailed inspection
        of any running CNTLM instance, its configuration, and connectivity status.
        It combines process discovery, configuration analysis, and smoke testing
        without making any system changes. This is the entry point for the Check-Cntlm
        functionality integrated into Buster-MyConnection.
    #>
    param(
        [int]$Port = 3128,
        [string]$ExplicitIniPath = "",
        [int]$TimeoutSeconds = 30,
        [int]$MaxRetries = 2
    )
    
    Out-Info "=== CONNECTION CHECK MODE ==="
    Out-Info "Performing comprehensive diagnostics on port ${Port}..."
    
    $discoveredProcess = $null
    $configFromCommandLine = $null
    $configCandidates = $null
    
    # Phase 1: Process Discovery
    Out-Info "[1/3] Discovering CNTLM process..."
    $portConnections = Get-ListeningProcessForPort -TargetPort $Port
    
    if (-not $portConnections -or $portConnections.Count -eq 0) {
        Out-Error "No process found listening on port ${Port}."
        Out-Info "CNTLM does not appear to be running."
        return $false
    }
    
    $targetProcessId = [int]$portConnections[0].OwningProcess
    Out-Info "Found process: PID ${targetProcessId} on port ${Port}"
    
    $discoveredProcess = Get-ProcessMetadata -ProcessId $targetProcessId
    
    if ($discoveredProcess.ExecutablePath) {
        Out-Info "Executable: $($discoveredProcess.ExecutablePath)"
    } else {
        Out-Warn "Could not determine executable path"
    }
    
    if ($discoveredProcess.CommandLine) {
        Out-Info "Command line: $($discoveredProcess.CommandLine)"
        $configFromCommandLine = Get-ConfigPathFromCommandLine -CommandLine $discoveredProcess.CommandLine
        
        if ($configFromCommandLine) {
            Out-Info "Config from command line: ${configFromCommandLine}"
            if (Test-Path $configFromCommandLine) {
                Out-Success "Configuration file is accessible"
            } else {
                Out-Warn "Configuration file from command line is not accessible"
            }
        } else {
            Out-Warn "No -c/--config in command line arguments"
        }
    } else {
        Out-Warn "Command line information not available"
    }
    
    # Phase 2: Configuration Discovery and Analysis
    Out-Info "[2/3] Analyzing configuration..."
    
    $configToAnalyze = $null
    
    if ($ExplicitIniPath -and (Test-Path $ExplicitIniPath)) {
        $configToAnalyze = $ExplicitIniPath
        Out-Info "Using explicitly specified configuration"
    } 
    elseif ($configFromCommandLine -and (Test-Path $configFromCommandLine)) {
        $configToAnalyze = $configFromCommandLine
        Out-Info "Using configuration from process command line"
    } 
    else {
        $configCandidates = Find-CntlmConfigurationFiles -ExecutablePath $discoveredProcess.ExecutablePath
        
        if ($configCandidates -and $configCandidates.Count -gt 0) {
            $configToAnalyze = $configCandidates[0].FullName
            Out-Info "Using discovered configuration: ${configToAnalyze}"
        }
    }
    
    $analysisResult = $null
    if ($configToAnalyze) {
        $analysisResult = Test-CntlmConfiguration -ConfigPath $configToAnalyze
    } else {
        Out-Warn "No configuration file found for analysis"
    }
    
    # Phase 3: Connectivity Testing
    Out-Info "[3/3] Testing connectivity..."
    $connectivityResult = Test-ProxyWithCurl -TargetPort $Port -TimeoutSeconds $TimeoutSeconds -MaxRetries $MaxRetries
    
    # Summary
    Out-Info "=== CHECK SUMMARY ==="
    Out-Info "Process Status: $(if($discoveredProcess.ExecutablePath){'FOUND'}else{'UNKNOWN'})"
    Out-Info "Configuration: $(if($configToAnalyze){$configToAnalyze}else{'NOT FOUND'})"
    Out-Info "Config Analysis: $(if($analysisResult){'COMPLETED'}else{'FAILED/UNAVAILABLE'})"
    Out-Info "Connectivity: $(if($connectivityResult){'PASSED'}else{'FAILED'})"
    
    return $connectivityResult
}

#==============================
# END CONNECTION CHECK MODE
#==============================

#==============================
# DECORATOR PATTERN: VPN Detection System
#==============================

class VpnDetectionResult {
    [bool]$IsVpnActive
    [string]$VpnType
    [string]$Description
    [scriptblock]$ReconcileAction
    
    VpnDetectionResult([bool]$isActive, [string]$type, [string]$desc, [scriptblock]$action) {
        $this.IsVpnActive = $isActive
        $this.VpnType = $type
        $this.Description = $desc
        $this.ReconcileAction = $action
    }
    
    static [VpnDetectionResult] NoVpnDetected() {
        return [VpnDetectionResult]::new($false, "None", "No VPN detected", $null)
    }
}

class IVpnDetector {
    [VpnDetectionResult] Detect() {
        throw "Must implement Detect() method"
    }
}

class BaseVpnDetector : IVpnDetector {
    [VpnDetectionResult] Detect() {
        return [VpnDetectionResult]::NoVpnDetected()
    }
}

class BigIpVpnDetector : IVpnDetector {
    [IVpnDetector]$NextDetector
    
    BigIpVpnDetector([IVpnDetector]$next) {
        $this.NextDetector = $next
    }
    
    [VpnDetectionResult] Detect() {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        try {
            $autoConfigUrl = (Get-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction Stop).AutoConfigURL
            if ($autoConfigUrl -and $autoConfigUrl -match '^http://127\.0\.0\.1:(44[7-9]\d{2}|45[0-7]\d{2})/') {
                $reconcileAction = {
                    param([string]$IniPath)
                    Set-CntlmParentProxyFromSystem -IniPath $IniPath
                }
                return [VpnDetectionResult]::new(
                    $true, 
                    "BIG-IP Edge Client", 
                    "Local PAC server detected at $autoConfigUrl",
                    $reconcileAction
                )
            }
        } catch {}
        
        return $this.NextDetector.Detect()
    }
}

class CiscoAnyConnectDetector : IVpnDetector {
    [IVpnDetector]$NextDetector
    
    CiscoAnyConnectDetector([IVpnDetector]$next) {
        $this.NextDetector = $next
    }
    
    [VpnDetectionResult] Detect() {
        $vpnAgentPath = "${env:ProgramFiles(x86)}\Cisco\Cisco AnyConnect Secure Mobility Client\vpnagent.exe"
        $vpnUiPath = "${env:ProgramFiles(x86)}\Cisco\Cisco AnyConnect Secure Mobility Client\vpnui.exe"
        
        $isRunning = Get-Process -Name "vpnagent" -ErrorAction SilentlyContinue
        $isInstalled = (Test-Path $vpnAgentPath) -or (Test-Path $vpnUiPath)
        
        if ($isRunning -or $isInstalled) {
            $reconcileAction = {
                param([string]$IniPath)
                Set-CntlmParentProxyFromSystem -IniPath $IniPath
            }
            return [VpnDetectionResult]::new(
                $true,
                "Cisco AnyConnect",
                "Cisco VPN client detected (running: $(if($isRunning){'yes'}else{'no'}))",
                $reconcileAction
            )
        }
        
        return $this.NextDetector.Detect()
    }
}

function New-VpnDetectionChain {
    [CmdletBinding()]
    param()
    
    $chain = [BaseVpnDetector]::new()
    $chain = [BigIpVpnDetector]::new($chain)
    # $chain = [CiscoAnyConnectDetector]::new($chain)
    
    return $chain
}

#==============================
# END DECORATOR PATTERN
#==============================

#------------------------------
# Self-healing installation infrastructure 
#------------------------------
function Install-CntlmPortable {
    param(
        [string]$TargetPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs/CNTLM')
    )

    $exePath = Join-Path -Path $TargetPath -ChildPath 'cntlm.exe'
    
    if (Test-Path -LiteralPath $exePath) {
        Out-Info "CNTLM already present at $exePath"
        return $exePath
    }

    Out-Warn "CNTLM not found at expected location. Initiating portable installation..."
    
    try {
        $null = New-Item -ItemType Directory -Path $TargetPath -Force
        $releaseUrl = "https://api.github.com/repos/versat/cntlm/releases/latest "
        
        Out-Info "Querying latest release information from GitHub..."
        $release = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing
        
        $asset = $release.assets | Where-Object { 
            $_.name -match 'windows.*\.zip$' -or $_.name -match 'win.*\.zip$' 
        } | Select-Object -First 1

        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
        }

        if (-not $asset) {
            throw "No suitable Windows binary found in release assets"
        }

        $downloadUrl = $asset.browser_download_url
        $zipPath = Join-Path -Path $env:TEMP -ChildPath "cntlm-$($release.tag_name).zip"
        
        Out-Info "Downloading CNTLM $($release.tag_name) from GitHub..."
        
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $downloadUrl -Destination $zipPath -DisplayName "Downloading CNTLM"
        } else {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
        }

        $extractPath = Join-Path -Path $env:TEMP -ChildPath "cntlm-extract-$([Guid]::NewGuid())"
        
        Out-Info "Extracting archive contents..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        
        $foundExe = Get-ChildItem -Path $extractPath -Filter 'cntlm.exe' -Recurse -ErrorAction SilentlyContinue | 
                    Select-Object -First 1
        
        if (-not $foundExe) {
            throw "cntlm.exe not found in downloaded archive"
        }

        $sourceDir = $foundExe.DirectoryName
        if ($sourceDir -ne $extractPath) {
            Get-ChildItem -Path $sourceDir -Recurse | ForEach-Object {
                $relativePath = $_.FullName.Substring($sourceDir.Length + 1)
                $destPath = Join-Path -Path $TargetPath -ChildPath $relativePath
                
                if ($_.PSIsContainer) {
                    $null = New-Item -ItemType Directory -Path $destPath -Force
                } else {
                    $null = New-Item -ItemType Directory -Path (Split-Path $destPath -Parent) -Force -ErrorAction SilentlyContinue
                    Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
                }
            }
        } else {
            Copy-Item -LiteralPath "$extractPath\*" -Destination $TargetPath -Recurse -Force
        }

        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $exePath) {
            Out-Success "CNTLM installed successfully at $TargetPath"
            return $exePath
        } else {
            throw "Installation verification failed"
        }
    }
    catch {
        Out-Error "Failed to install CNTLM: $($_.Exception.Message)"
        throw
    }
}

#------------------------------
# Interactive configuration wizard 
#------------------------------
function New-CntlmConfiguration {
    param([string]$OutputPath)

    Out-Info "Configuration wizard initiated. CNTLM requires specific settings to authenticate with your corporate proxy."
    
    Write-Host "`n${Cyan}=== CNTLM Configuration Wizard ===${Reset}`n" -NoNewline
    Write-Host "This wizard will help you create a basic cntlm.ini configuration."
    Write-Host "You will need your domain credentials and the address of your corporate proxy.`n"

    $username = Read-Host -Prompt "Enter your domain username (e.g., jdoe or CORP\jdoe)"
    while ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "${Red}Username cannot be empty${Reset}"
        $username = Read-Host -Prompt "Enter your domain username"
    }

    if ($username -match '^([^\\]+)\\(.+)$') {
        $domain = $Matches[1]
        $username = $Matches[2]
        Out-Info "Detected domain '$domain' from username format"
    } else {
        $domain = Read-Host -Prompt "Enter your domain (e.g., CORPORATE)"
        while ([string]::IsNullOrWhiteSpace($domain)) {
            Write-Host "${Red}Domain cannot be empty${Reset}"
            $domain = Read-Host -Prompt "Enter your domain"
        }
    }

    Write-Host "`n${Yellow}Security Note:${Reset} Storing plaintext passwords in configuration files is not recommended."
    Write-Host "CNTLM can use NTLM password hashes instead. You have two options:"
    Write-Host "  1. Enter plaintext password (will be stored as hash by CNTLM later)"
    Write-Host "  2. Generate hash now (requires running CNTLM -H with your password)"
    
    $useHash = Read-Host -Prompt "`nDo you want to generate the password hash now? (Y/N, default: Y)"
    $passwordHash = $null
    
    if ($useHash -match '^[Yy]?$') {
        Write-Host "`nTo generate the hash, you need to run: cntlm.exe -H -u $username -d $domain"
        Write-Host "You will be prompted for your password securely.`n"
        
        $generateNow = Read-Host -Prompt "Attempt to generate hash now? Requires cntlm.exe to be available (Y/N, default: Y)"
        
        if ($generateNow -match '^[Yy]?$') {
            try {
                $cntlmExe = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs/CNTLM/cntlm.exe'
                if (Test-Path -LiteralPath $cntlmExe) {
                    $hashOutput = & $cntlmExe -H -u $username -d $domain 2>&1
                    $hashLine = $hashOutput | Where-Object { $_ -match '^PassNTLMv2\s+(.+)$' } | Select-Object -First 1
                    if ($hashLine) {
                        $passwordHash = $Matches[1].Trim()
                        Out-Success "Password hash generated successfully"
                    }
                }
            }
            catch {
                Out-Warn "Could not generate hash automatically: $($_.Exception.Message)"
            }
        }
    }

    if (-not $passwordHash) {
        $securePassword = Read-Host -Prompt "Enter your password (will be masked)" -AsSecureString
        $plainPassword = [System.Net.NetworkCredential]::new("", $securePassword).Password
    }

    Write-Host "`n${Cyan}Upstream Proxy Configuration${Reset}"
    Write-Host "Enter your corporate proxy address and port (e.g., proxy.company.com:8080 or 10.0.0.1:8080)"
    
    $proxy = Read-Host -Prompt "Proxy address:port"
    while ([string]::IsNullOrWhiteSpace($proxy) -or $proxy -notmatch ':\d+$') {
        if ($proxy -notmatch ':\d+$') {
            Write-Host "${Red}Please include the port number (e.g., :8080)${Reset}"
        } else {
            Write-Host "${Red}Proxy address cannot be empty${RESET}"
        }
        $proxy = Read-Host -Prompt "Proxy address:port"
    }

    Write-Host "`n${Cyan}Local Listener Configuration${RESET}"
    $listenPort = Read-Host -Prompt "Local port for CNTLM to listen on (default: 3128)"
    if ([string]::IsNullOrWhiteSpace($listenPort)) {
        $listenPort = "3128"
    }
    while ($listenPort -notmatch '^\d+$' -or [int]$listenPort -lt 1 -or [int]$listenPort -gt 65535) {
        Write-Host "${Red}Please enter a valid port number (1-65535)${RESET}"
        $listenPort = Read-Host -Prompt "Local port"
    }

    $configLines = @(
        "# CNTLM Configuration File"
        "# Generated by Buster-MyConnection on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "#"
        "# For detailed documentation, see: https://cntlm.sourceforge.net/ "
        ""
        "# Your domain account credentials"
        "Username    $username"
        "Domain      $domain"
        "Workstation $env:COMPUTERNAME"
        ""
    )

    if ($passwordHash) {
        $configLines += @(
            "# Authentication using NTLM hash (more secure than plaintext)"
            "PassNTLMv2  $passwordHash"
            ""
        )
    } else {
        $configLines += @(
            "# Password in plaintext (consider using PassNTLMv2 hash instead for security)"
            "# To generate hash: cntlm -H -u $username -d $domain"
            "Password    $plainPassword"
            ""
        )
    }

    $configLines += @(
        "# Corporate proxy server(s) - CNTLM will try each in order"
        "Proxy       $proxy"
        ""
        "# Local listening configuration"
        "Listen      127.0.0.1:$listenPort"
        ""
        "# Addresses that should bypass the proxy (comma-separated)"
        "NoProxy     localhost, 127.0.0.*, 10.*, 192.168.*, *.local"
        ""
        "# Enable gateway mode to allow other machines to connect (optional)"
        "# Gateway yes"
        ""
        "# Additional options you might want to configure:"
        "# - Header User-Agent: custom/1.0"
        "# - NTLMToBasic yes  # Enable basic auth forwarding"
    )

    $configDir = Split-Path -Parent -Path $OutputPath
    if (-not (Test-Path -LiteralPath $configDir)) {
        $null = New-Item -ItemType Directory -Path $configDir -Force
    }

    $configContent = $configLines -join "`r`n"
    Set-Content -LiteralPath $OutputPath -Value $configContent -Encoding ASCII
    
    Out-Success "Configuration saved to $OutputPath"
    Out-Info "You can edit this file manually to add additional proxy servers or advanced options"
    
    return $OutputPath
}

#------------------------------
# WinINET effective proxy resolution (DESKTOP ONLY) 
#------------------------------
function Get-EffectiveParentProxy {
    param([string]$TestUrl = 'https://www.microsoft.com/ ')

    if (-not (Test-IsWindowsPowerShell)) {
        Out-Warn "WinINET proxy resolution unavailable in PowerShell Core. Skipping upstream detection."
        return $null
    }

    try {
        $webProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $webProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $proxyUri = $webProxy.GetProxy([Uri]$TestUrl)

        if ($proxyUri -and $proxyUri.AbsoluteUri -ne $TestUrl) {
            return $proxyUri
        }
        return $null
    }
    catch {
        Out-Warn "WinINET proxy lookup encountered an error: $($_.Exception.Message)"
        return $null
    }
}

#------------------------------
# Idempotent cntlm.ini update 
#------------------------------
function Set-CntlmParentProxyFromSystem {
    param([string]$IniPath)

    $effectiveProxy = Get-EffectiveParentProxy
    if (-not $effectiveProxy) {
        Out-Warn "Could not resolve effective upstream proxy. Configuration remains unchanged."
        return $false
    }

    $authority = $effectiveProxy.Authority
    if (-not $authority) { 
        Out-Warn "Resolved proxy authority is empty. Skipping update."
        return $false 
    }

    $originalContent = Get-Content -LiteralPath $IniPath -Raw
    $normalizedLine = "Proxy  $authority"

    if ($originalContent -match "^(?im)\s*Proxy\s+$([regex]::Escape($authority))\s*$") {
        Out-Info "cntlm.ini already reflects effective upstream proxy '$authority'."
        return $false
    }

    $lines = $originalContent -split "(`r`n|`n)"
    $firstProxyIndex = ($lines | Select-String -Pattern '^(?im)\s*Proxy\s+.+$').Matches |
                Select-Object -First 1 | ForEach-Object { $_.LineNumber - 1 }

    if ($firstProxyIndex -ne $null) {
        $lines[$firstProxyIndex] = $normalizedLine
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            if ($i -ne $firstProxyIndex -and ($lines[$i] -match '^(?im)\s*Proxy\s+.+$')) {
                $lines = $lines[0..($i-1)] + $lines[($i+1)..($lines.Length-1)]
            }
        }
    } else {
        $lines = $lines + @("# Added by Buster-MyConnection to reflect current system proxy", $normalizedLine)
    }

    $updatedContent = ($lines -join "`r`n")
    if ($updatedContent -ne $originalContent) {
        $backupPath = "$IniPath.bak"
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $IniPath -Destination $backupPath -Force
        }
        Set-Content -LiteralPath $IniPath -Value $updatedContent -Encoding ASCII
        Out-Info "Updated cntlm.ini parent proxy to '$authority'."
        return $true
    }
    return $false
}

#------------------------------
# Diagnostics for proxy bypass testing 
#------------------------------
function Test-WgetSansProxyBehavior {
    param([int]$CntlmPort = 3128)

    if (-not (Test-IsWindowsPowerShell)) {
        Out-Warn "Diagnostic test skipped (WinINET unavailable in PowerShell Core)."
        return
    }

    $testUrl = "https://www.microsoft.com/ "
    try {
        Out-Info "Testing direct connectivity without explicit proxy..."
        Invoke-WebRequest -Uri $testUrl -OutFile $null -MaximumRedirection 5
        Out-Success "Direct request succeeded—CNTLM may not be necessary for this network."
    } catch {
        Out-Warn "Direct request failed as expected behind corporate proxy: $($_.Exception.Message)"
    }
}

#------------------------------
# Main execution flow 
#------------------------------

# CRITICAL: -JustCheck mode takes precedence over all other switches
if ($JustCheck) {
    Out-Info "JustCheck mode activated. Ignoring all other parameters."
    $result = Invoke-ConnectionCheck -Port 3128 -ExplicitIniPath $IniPath -TimeoutSeconds $CheckTimeoutSeconds -MaxRetries $CheckRetries
    exit $(if ($result) { 0 } else { 1 })
}

# Ensure log directory exists
if (-not (Test-Path -LiteralPath $LogDirectory)) {
    try { 
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force 
    }
    catch { 
        Out-Error "Cannot create log directory '$LogDirectory': $($_.Exception.Message)"
        exit 1 
    }
}

$timestamp = (Get-Date -Format 'yyyyMMddHHmmss')
$LogFile = Join-Path -Path $LogDirectory -ChildPath "cntlm-$timestamp.log"

# Check previous execution state for mode transition detection
$previousState = Get-PreviousExecutionState
$wasInDirectAccessMode = $false
$proxyVarsBackup = @{}

if ($previousState -and $previousState.Mode -eq 'DirectAccess') {
    $wasInDirectAccessMode = $true
    $proxyVarsBackup = $previousState.ProxyVariables
    Out-Info "Previous execution was in DIRECT ACCESS mode. Proxy variables were unset."
}

# Resolve CNTLM executable with auto-installation capability
$resolvedExe = $null
try {
    $resolvedExe = Install-CntlmPortable -TargetPath (Split-Path -Parent -Path $CntlmPath)
} catch {
    Out-Error "CNTLM installation failed. Cannot proceed without the executable."
    exit 3
}

# Resolve configuration file with wizard fallback
$resolvedIni = $null
if (Test-Path -LiteralPath $IniPath) {
    $resolvedIni = $IniPath
} else {
    $fallbackIni = Join-Path -Path $PSScriptRoot -ChildPath 'cntlm.ini'
    if (Test-Path -LiteralPath $fallbackIni) {
        Out-Warn "Specified configuration '$IniPath' not found. Using fallback at '$fallbackIni'."
        $resolvedIni = $fallbackIni
    } else {
        Out-Warn "No configuration file found. Launching configuration wizard..."
        try {
            $resolvedIni = New-CntlmConfiguration -OutputPath $IniPath
        } catch {
            Out-Error "Configuration wizard failed: $($_.Exception.Message)"
            exit 2
        }
    }
}

#------------------------------
# VPN Detection and Mode Decision
#------------------------------
Out-Info "Checking for active VPN connections..."

$vpnDetector = New-VpnDetectionChain
$vpnResult = $vpnDetector.Detect()

# Determine if we should attempt proxy mode or direct access
$attemptProxyMode = $false
$proxyModeReason = ""

if ($vpnResult.IsVpnActive) {
    $attemptProxyMode = $true
    $proxyModeReason = "$($vpnResult.VpnType) detected: $($vpnResult.Description)"
    
    # If we were in direct access mode before, restore proxy variables
    if ($wasInDirectAccessMode -and $proxyVarsBackup.Count -gt 0) {
        Out-Info "Transitioning from DIRECT ACCESS to PROXY mode. Restoring environment variables..."
        $restoredCount = Restore-ProxyEnvironmentVariables -Variables $proxyVarsBackup
        Out-Success "Restored $restoredCount proxy environment variable(s)."
    }
} 
elseif (Test-UpstreamProxyConnectivity -IniPath $resolvedIni -TimeoutSeconds $ProxyTestTimeoutSeconds -TestPort $ProxyTestPort) {
    $attemptProxyMode = $true
    $proxyModeReason = "Upstream proxy is responsive (no VPN detected)"
}
else {
    $proxyModeReason = "No VPN detected and upstream proxy is unresponsive"
}

#------------------------------
# CRITICAL: Upstream proxy health check before starting CNTLM 
#------------------------------
if ($attemptProxyMode) {
    Out-Info "Attempting PROXY mode: $proxyModeReason"
    
    # Re-test upstream proxy to confirm it's still healthy
    $proxyIsHealthy = Test-UpstreamProxyConnectivity -IniPath $resolvedIni -TimeoutSeconds $ProxyTestTimeoutSeconds -TestPort $ProxyTestPort
    
    if (-not $proxyIsHealthy) {
        Out-Warn "Upstream proxy health check FAILED. Reconsidering strategy..."
        $attemptProxyMode = $false
    }
}

#------------------------------
# Execute Selected Strategy with Validation
#------------------------------
if (-not $attemptProxyMode) {
    # DIRECT ACCESS STRATEGY
    Out-Warn "Switching to DIRECT INTERNET ACCESS mode."
    Out-Warn "CNTLM will NOT be started to avoid connectivity deadlock."
    
    # Backup current proxy variables before removing (for future restoration)
    $currentProxyBackup = Backup-ProxyEnvironmentVariables
    $removalResult = Remove-ProxyEnvironmentVariables
    
    # Persist state for next execution
    Set-ExecutionState -Mode 'DirectAccess' -ProxyVariables $currentProxyBackup
    
    # Validate direct access works
    Out-Info "Validating direct internet connectivity..."
    $directAccessWorks = Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds
    
    if ($directAccessWorks) {
        Out-Success "DIRECT ACCESS MODE activated and validated. Internet connectivity confirmed."
        Out-Info "Applications in this session will connect directly to the internet."
        Out-Info "Run this script again when the corporate proxy is available to restore CNTLM mode."
        exit 0
    }
    else {
        Out-Error "CRITICAL: Direct access mode activated but internet connectivity validation FAILED."
        Out-Error "Your network may require a proxy, or internet may be unavailable."
        Out-Error "Previous proxy variables were backed up and will be restored on next run."
        exit 1
    }
}

# PROXY MODE STRATEGY (CNTLM via VPN/Corporate Proxy)
Out-Success "PROXY MODE activated: $proxyModeReason"

# Persist state
Set-ExecutionState -Mode 'Proxied' -ProxyVariables @{}

# Reconcile VPN settings if needed
if ($vpnResult.IsVpnActive -and $vpnResult.ReconcileAction) {
    Out-Info "Reconciling upstream proxy settings for VPN environment..."
    try { 
        & $vpnResult.ReconcileAction -IniPath $resolvedIni
    }
    catch { 
        Out-Warn "Failed to reconcile cntlm.ini with VPN proxy: $($_.Exception.Message)" 
    }
}

#------------------------------
# Process lifecycle management 
#------------------------------
if (-not $KeepExisting) {
    Out-Info "Terminating existing CNTLM processes to prevent port conflicts..."
    try {
        $existingProcesses = Get-Process -Name 'cntlm' -ErrorAction SilentlyContinue
        foreach ($process in $existingProcesses) {
            try {
                Stop-Process -Id $process.Id -ErrorAction Stop
                Out-Info "Gracefully stopped CNTLM (PID $($process.Id))."
            }
            catch {
                Out-Warn "Forcefully terminating PID $($process.Id)."
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Out-Warn "Encountered issues while stopping existing processes: $($_.Exception.Message)"
    }
} else {
    Out-Info "-KeepExisting specified; allowing concurrent CNTLM instances."
}

#------------------------------
# Service startup 
#------------------------------
try {
    $arguments = @('-v', '-c', $resolvedIni, '-T', $LogFile)
    $startInfo = @{
        FilePath = $resolvedExe
        ArgumentList = $arguments
        WindowStyle = 'Hidden'
        WorkingDirectory = Split-Path -Path $resolvedExe -Parent
    }
    
    Start-Process @startInfo
    Start-Sleep -Seconds 2  # Allow time for process initialization

    $runningProcesses = Get-Process -Name 'cntlm' -ErrorAction SilentlyContinue
    if ($runningProcesses) {
        $processIds = ($runningProcesses | Select-Object -ExpandProperty Id) -join ', '
        Out-Success "CNTLM started successfully. Process ID(s): $processIds"
        Out-Info "Monitor logs at: $LogFile"
        
        # Validate proxy connectivity through CNTLM
        Out-Info "Validating connectivity through CNTLM proxy..."
        $proxyValidation = Test-ProxyConnectivity -ProxyPort 3128 -TimeoutSeconds $DirectAccessTestTimeoutSeconds
        
        if ($proxyValidation) {
            Out-Success "PROXY MODE fully operational. CNTLM validation passed."
            # Perform post-start diagnostics
            Test-WgetSansProxyBehavior
            exit 0
        }
        else {
            Out-Error "CNTLM is running but proxy validation FAILED."
            Out-Error "Check CNTLM logs at: $LogFile"
            exit 1
        }
    } else {
        Out-Error "CNTLM process did not persist after startup. Review log file for details: $LogFile"
        exit 1
    }
}
catch {
    Out-Error "Failed to start CNTLM: $($_.Exception.Message)"
    exit 1
}