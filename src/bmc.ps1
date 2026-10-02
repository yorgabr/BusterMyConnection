#Requires -Version 5.1
<#
.SYNOPSIS
    Buster-MyConnection (bmc): aligns developer tooling with the current network scenario.

.DESCRIPTION
    Detects where the workstation is connected (corporate LAN, corporate VPN, or home network) and converges the
    per-user configuration of Git, Scoop, uv, npm and the user environment variables to the desired state for that
    scenario. Every step is idempotent: the current state is read first and only drifting settings are written.
    No administrator rights are required; everything lives in the user profile (HKCU, %APPDATA%, %USERPROFILE%).

    Design (patterns):
      * Chain of Responsibility - ordered scenario probes (VPN first, then office, home as the fallback).
      * Strategy / Registry     - one provider function per tool, looked up by name in Get-BmcPlan.
      * Command                 - providers emit action objects (Test handler + Apply handler + arguments);
                                  the engine (Invoke-BmcAction) is a Template Method: check, ask, apply, verify.
      * Adapter                 - every side effect (native tools, .NET network/proxy APIs, environment, registry)
                                  sits behind a thin function so tests can replace it.

    Scenarios (all thresholds live in the JSON configuration, never in code):
      Vpn    - an operational network adapter whose name/description matches detection.vpnAdapterPattern.
      Office - an operational adapter whose connection-specific DNS suffix matches detection.officeDnsSuffixPattern.
      Home   - anything else.

    Proxy modes per scenario (scenarios.<name>.proxy):
      auto     - ask Windows for the proxy of proxy.probeUrl. The .NET system proxy honours the PAC file announced in
                 HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings\AutoConfigURL.
      override - use proxy.overrideUrl (for example a local NTLM forwarder such as Px, see NOTES).
      none     - direct connection.

.PARAMETER Scenario
    Auto (default) detects the scenario; Office, Vpn or Home force it.

.PARAMETER ConfigPath
    JSON configuration file. Defaults to %APPDATA%\bmc\config.json.

.PARAMETER Tool
    Restricts the run to the given tools (Git, Scoop, Uv, Npm, Environment). Defaults to configuration.tools, or all.

.PARAMETER DetectOnly
    Prints the detected scenario and why, then exits without touching anything.

.PARAMETER InitConfig
    Writes a template configuration file (never overwrites an existing one) and exits.

.EXAMPLE
    .\bmc.ps1 -InitConfig
    Creates %APPDATA%\bmc\config.json to be edited with the corporate values.

.EXAMPLE
    .\bmc.ps1 -DetectOnly -Verbose
    Shows the detected scenario and every network adapter considered.

.EXAMPLE
    .\bmc.ps1 -WhatIf
    Shows what would change for the detected scenario without changing anything.

.EXAMPLE
    .\bmc.ps1 -Scenario Home -Tool Git,Npm
    Forces the Home profile for Git and npm only.

.NOTES
    Exit code 1 when at least one step failed. Steps are fault-isolated: one failing tool does not stop the others.

    NTLM: Git for Windows and Scoop can authenticate to an NTLM proxy with the current Windows identity
    (Scoop: 'currentuser@default'; Git: 'http://:@host:port'). uv and npm do not implement NTLM/SSPI; if the proxy
    demands it, point scenarios.<name>.proxy at 'override' with a local forwarder such as Px
    (https://github.com/genotrance/px), which authenticates through SSPI.

    References:
      Scoop proxy syntax        https://github.com/ScoopInstaller/Scoop/wiki/Using-Scoop-behind-a-proxy
      Git http.proxy            https://git-scm.com/docs/git-config
      uv config files / env     https://docs.astral.sh/uv/configuration/files/
                                https://docs.astral.sh/uv/reference/environment/
      npm config and .npmrc     https://docs.npmjs.com/cli/v10/using-npm/config
                                https://docs.npmjs.com/cli/v10/configuring-npm/npmrc
      WebRequest.GetSystemWebProxy / IWebProxy.GetProxy
                                https://learn.microsoft.com/dotnet/api/system.net.webrequest.getsystemwebproxy
      Reserved example domains  RFC 2606
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Auto', 'Office', 'Vpn', 'Home')]
    [string] $Scenario = 'Auto',

    [string] $ConfigPath,

    [ValidateSet('Git', 'Scoop', 'Uv', 'Npm', 'Environment')]
    [string[]] $Tool,

    [switch] $DetectOnly,

    [switch] $InitConfig
)

# ---------------------------------------------------------------------------------------------------------------
# Adapters: thin wrappers around side effects. Tests replace these; keep them free of decision logic.
# ---------------------------------------------------------------------------------------------------------------

function Get-BmcPath {
    <# Well-known per-user file locations, centralised so that tests can redirect them to a sandbox. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $appData = $env:APPDATA
    $profileDir = $env:USERPROFILE

    # Scoop keeps its settings under $XDG_CONFIG_HOME, falling back to %USERPROFILE%\.config.
    $configHome = $env:XDG_CONFIG_HOME
    if ([string]::IsNullOrEmpty($configHome)) { $configHome = Join-Path $profileDir '.config' }

    @{
        Config      = Join-Path $appData 'bmc\config.json'
        UvConfig    = Join-Path $appData 'uv\uv.toml'
        NpmRc       = Join-Path $profileDir '.npmrc'
        ScoopConfig = Join-Path $configHome 'scoop\config.json'
    }
}

function Test-BmcCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Name)

    [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-BmcNative {
    <#
    Runs an external program and returns its exit code and combined output.

    Windows PowerShell 5.1 wraps native stderr lines in ErrorRecords; with $ErrorActionPreference = 'Stop' a harmless
    warning written by git or scoop would become a terminating error. The preference is therefore relaxed locally and
    success is decided solely by the exit code. $LASTEXITCODE is reset first because script shims (scoop.ps1) may
    finish without setting it, which would otherwise leak the exit code of a previous native call.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output   = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-BmcNetworkInterface {
    <# Flattens .NET NetworkInterface objects into plain data that is trivial to fake in tests. #>
    [CmdletBinding()]
    param()

    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }

        $suffix = ''
        try { $suffix = [string]$nic.GetIPProperties().DnsSuffix }
        catch { Write-Verbose "Could not read IP properties of '$($nic.Name)': $($_.Exception.Message)" }

        [pscustomobject]@{
            Name        = $nic.Name
            Description = $nic.Description
            IsUp        = ($nic.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up)
            DnsSuffix   = $suffix
        }
    }
}

function Get-BmcPacUrl {
    <# Reads the PAC address the way Windows stores it; used for diagnostics only. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $value = Get-ItemProperty -Path $key -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
    if ($null -eq $value) { return $null }
    [string]$value.AutoConfigURL
}

function Get-BmcSystemProxy {
    <#
    Returns the proxy Windows would use for the given URL, or $null when the connection would be direct.

    WebRequest.GetSystemWebProxy() returns the proxy built from the user's Internet Options, including PAC scripts
    (AutoConfigURL) and WPAD. IWebProxy.GetProxy() hands back the destination URI itself when no proxy applies, which
    is how a direct connection is told apart from a real proxy. When the PAC yields several proxies only the first
    one is exposed by the API.
    #>
    [CmdletBinding()]
    [OutputType([uri])]
    param([Parameter(Mandatory)][string] $Uri)

    $target = [uri]$Uri
    $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    if ($proxy.IsBypassed($target)) { return $null }

    $resolved = $proxy.GetProxy($target)
    if ($null -eq $resolved -or $resolved.AbsoluteUri -eq $target.AbsoluteUri) { return $null }
    $resolved
}

function Get-BmcUserEnv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)

    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Write-BmcUserEnv {
    <#
    Persists (or removes, when Desired is empty) a user-scope variable and mirrors it into the current process so the
    running session benefits immediately. User scope maps to HKCU\Environment and needs no elevation; the .NET call
    also broadcasts WM_SETTINGCHANGE, but already-running programs keep their old environment block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][AllowEmptyString()][string] $Desired
    )

    $value = $Desired
    if ([string]::IsNullOrEmpty($value)) { $value = $null }
    [Environment]::SetEnvironmentVariable($Name, $value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
}

function Read-BmcTextFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($null -eq $text) { return '' }
    $text
}

function Write-BmcTextFile {
    <# Writes UTF-8 without BOM: Set-Content -Encoding UTF8 emits a BOM on 5.1, which TOML and .npmrc parsers dislike. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------------------

function Get-BmcTemplateConfig {
    <# Template written by -InitConfig. example.com/.net/.org are reserved by RFC 2606, so a forgotten placeholder can
       never point at a real host, and Read-BmcConfig refuses to run until they are replaced. #>
    [CmdletBinding()]
    param()

    [ordered]@{
        detection = [ordered]@{
            vpnAdapterPattern      = 'F5|BIG-IP'
            officeDnsSuffixPattern = '(^|\.)corp\.example\.com$'
        }
        scenarios = [ordered]@{
            Office = [ordered]@{ proxy = 'auto'; nexus = $true }
            Vpn    = [ordered]@{ proxy = 'auto'; nexus = $true }
            Home   = [ordered]@{ proxy = 'none'; nexus = $false }
        }
        proxy     = [ordered]@{
            overrideUrl = 'http://127.0.0.1:3128'
            noProxy     = 'localhost,127.0.0.1,.corp.example.com'
            probeUrl    = 'https://pypi.org'
        }
        nexus     = [ordered]@{
            pypiIndexUrl   = 'https://nexus.corp.example.com/repository/pypi-group/simple'
            npmRegistryUrl = 'https://nexus.corp.example.com/repository/npm-group/'
        }
        git       = [ordered]@{ useCurrentUserCredentials = $true }
        tools     = @('Git', 'Scoop', 'Uv', 'Npm', 'Environment')
    }
}

function Write-BmcConfigTemplate {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)

    if (Test-Path -LiteralPath $Path) {
        Write-Warning "Configuration already exists and was left untouched: $Path"
        return $false
    }
    $json = Get-BmcTemplateConfig | ConvertTo-Json -Depth 6
    Write-BmcTextFile -Path $Path -Text ($json + "`r`n")
    $true
}

function Get-BmcConfigValue {
    <# Null-safe dotted-path lookup (a.b.c) over a ConvertFrom-Json object; PowerShell 5.1 has no '?.' operator. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()] $Config,
        [Parameter(Mandatory)][string] $Path
    )

    $node = $Config
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        $property = $node.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $node = $property.Value
    }
    $node
}

function Test-BmcHttpUrl {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains('"')) { return $false }
    $parsed = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed)) { return $false }
    $parsed.Scheme -in @('http', 'https')
}

function Assert-BmcConfig {
    <# Fails fast with every problem listed at once, instead of a cryptic null-reference halfway through a run. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($path in 'detection.vpnAdapterPattern', 'detection.officeDnsSuffixPattern', 'proxy.noProxy') {
        if ([string]::IsNullOrWhiteSpace([string](Get-BmcConfigValue -Config $Config -Path $path))) {
            $problems.Add("'$path' is missing or empty")
        }
    }

    foreach ($path in 'detection.vpnAdapterPattern', 'detection.officeDnsSuffixPattern') {
        $pattern = [string](Get-BmcConfigValue -Config $Config -Path $path)
        if ($pattern) {
            try { [void][regex]::new($pattern) }
            catch { $problems.Add("'$path' is not a valid regular expression") }
        }
    }

    foreach ($path in 'proxy.probeUrl', 'nexus.pypiIndexUrl', 'nexus.npmRegistryUrl') {
        if (-not (Test-BmcHttpUrl -Value ([string](Get-BmcConfigValue -Config $Config -Path $path)))) {
            $problems.Add("'$path' must be an absolute http(s) URL without double quotes")
        }
    }

    foreach ($name in 'Office', 'Vpn', 'Home') {
        $policy = Get-BmcConfigValue -Config $Config -Path "scenarios.$name"
        if ($null -eq $policy) { $problems.Add("'scenarios.$name' is missing"); continue }

        $mode = [string](Get-BmcConfigValue -Config $policy -Path 'proxy')
        if ($mode -notin @('auto', 'none', 'override')) {
            $problems.Add("'scenarios.$name.proxy' must be auto, none or override")
        }
        if ($mode -eq 'override' -and -not (Test-BmcHttpUrl -Value ([string](Get-BmcConfigValue -Config $Config -Path 'proxy.overrideUrl')))) {
            $problems.Add("'proxy.overrideUrl' must be an absolute http(s) URL when scenarios.$name.proxy is 'override'")
        }
        if ((Get-BmcConfigValue -Config $policy -Path 'nexus') -isnot [bool]) {
            $problems.Add("'scenarios.$name.nexus' must be true or false")
        }
    }

    $tools = Get-BmcConfigValue -Config $Config -Path 'tools'
    foreach ($entry in @($tools)) {
        if ($null -ne $entry -and $entry -notin @('Git', 'Scoop', 'Uv', 'Npm', 'Environment')) {
            $problems.Add("'tools' contains unknown entry '$entry'")
        }
    }

    if ($problems.Count -gt 0) {
        throw ("Invalid configuration:`n - " + ($problems -join "`n - "))
    }
}

function Read-BmcConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path. Run '.\bmc.ps1 -InitConfig' to create a template."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($raw -match 'example\.(com|net|org)') {
        throw "Configuration still contains template placeholders (example.com/net/org): $Path"
    }

    try { $config = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Configuration is not valid JSON ($Path): $($_.Exception.Message)" }

    Assert-BmcConfig -Config $config
    $config
}

# ---------------------------------------------------------------------------------------------------------------
# Scenario detection (Chain of Responsibility)
# ---------------------------------------------------------------------------------------------------------------

function Test-BmcVpnProbe {
    <# Returns the reason string when a VPN adapter is operational, otherwise $null. #>
    [CmdletBinding()]
    param($Interface, $Config)

    $pattern = [string]$Config.detection.vpnAdapterPattern
    $hit = @($Interface | Where-Object { $_.IsUp -and (([string]$_.Name -match $pattern) -or ([string]$_.Description -match $pattern)) }) |
        Select-Object -First 1
    if ($hit) { return "adapter '$($hit.Name)' is up and matches '$pattern'" }
    $null
}

function Test-BmcOfficeProbe {
    <# Returns the reason string when an operational adapter carries the corporate DNS suffix, otherwise $null. #>
    [CmdletBinding()]
    param($Interface, $Config)

    $pattern = [string]$Config.detection.officeDnsSuffixPattern
    $hit = @($Interface | Where-Object { $_.IsUp -and $_.DnsSuffix -and ([string]$_.DnsSuffix -match $pattern) }) |
        Select-Object -First 1
    if ($hit) { return "adapter '$($hit.Name)' has DNS suffix '$($hit.DnsSuffix)'" }
    $null
}

function Resolve-BmcScenario {
    <#
    Walks the ordered probe chain; the first probe that claims the network wins. Order matters: a VPN adapter usually
    also receives the corporate DNS suffix, so the VPN probe must run before the office probe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] $Interface,
        [Parameter(Mandatory)] $Config
    )

    $chain = @(
        @{ Scenario = 'Vpn'; Probe = 'Test-BmcVpnProbe' }
        @{ Scenario = 'Office'; Probe = 'Test-BmcOfficeProbe' }
    )

    foreach ($link in $chain) {
        $probe = $link.Probe
        $reason = & $probe -Interface $Interface -Config $Config
        if ($reason) { return [pscustomobject]@{ Scenario = $link.Scenario; Reason = [string]$reason } }
    }
    [pscustomobject]@{ Scenario = 'Home'; Reason = 'no VPN adapter and no corporate DNS suffix found' }
}

# ---------------------------------------------------------------------------------------------------------------
# Desired state
# ---------------------------------------------------------------------------------------------------------------

function Resolve-BmcDesiredState {
    <# Turns configuration + scenario into one flat, tool-agnostic description of the target state. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][ValidateSet('Office', 'Vpn', 'Home')][string] $Scenario
    )

    $policy = $Config.scenarios.$Scenario
    $mode = [string]$policy.proxy
    $proxyUrl = $null

    switch ($mode) {
        'auto' {
            $resolved = Get-BmcSystemProxy -Uri ([string]$Config.proxy.probeUrl)
            if ($resolved) {
                $proxyUrl = $resolved.AbsoluteUri.TrimEnd('/')
            }
            else {
                Write-Warning ("Scenario '$Scenario' expects a proxy but Windows resolved a direct connection for " +
                    "$($Config.proxy.probeUrl) (PAC: '$(Get-BmcPacUrl)'). Proceeding without proxy.")
            }
        }
        'override' { $proxyUrl = ([uri][string]$Config.proxy.overrideUrl).AbsoluteUri.TrimEnd('/') }
        default { }
    }

    $proxyHostPort = $null
    $noProxy = $null
    if ($proxyUrl) {
        $parsed = [uri]$proxyUrl
        $proxyHostPort = '{0}:{1}' -f $parsed.Host, $parsed.Port
        $noProxy = [string]$Config.proxy.noProxy
    }

    $useNexus = [bool]$policy.nexus

    [pscustomobject]@{
        Scenario       = $Scenario
        ProxyMode      = $mode
        ProxyUrl       = $proxyUrl
        ProxyHostPort  = $proxyHostPort
        NoProxy        = $noProxy
        UseNexus       = $useNexus
        PypiIndexUrl   = if ($useNexus) { [string]$Config.nexus.pypiIndexUrl } else { $null }
        NpmRegistryUrl = if ($useNexus) { [string]$Config.nexus.npmRegistryUrl } else { $null }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Managed text blocks (uv.toml, .npmrc)
# ---------------------------------------------------------------------------------------------------------------

function Merge-BmcManagedBlock {
    <#
    Returns Text with bmc's managed block replaced by Line (or removed when Line is empty).

    The block is delimited by marker comments, so everything the user wrote around it survives untouched. The block is
    always placed first: TOML requires top-level keys before any [table], and .npmrc does not care. The function is
    pure and normalises its own output (remove, then insert), so applying it twice yields the same text; that
    property is what makes the file providers idempotent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string] $Text,
        [AllowNull()][string[]] $Line
    )

    if ($null -eq $Text) { $Text = '' }
    $begin = '# >>> bmc managed block (do not edit) >>>'
    $end = '# <<< bmc managed block <<<'

    $pattern = '(?ms)^' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '[ \t]*(\r?\n)?'
    $clean = [regex]::Replace($Text, $pattern, '')

    $body = @($Line | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($body.Count -eq 0) { return $clean }

    $block = (@($begin) + $body + @($end)) -join "`r`n"
    if ([string]::IsNullOrWhiteSpace($clean)) { return $block + "`r`n" }
    $block + "`r`n" + $clean
}

function Test-BmcManagedFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][string[]] $Line
    )

    $current = Read-BmcTextFile -Path $Path
    $next = Merge-BmcManagedBlock -Text $current -Line $Line
    $next -ceq $current
}

function Write-BmcManagedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][string[]] $Line
    )

    $current = Read-BmcTextFile -Path $Path
    Write-BmcTextFile -Path $Path -Text (Merge-BmcManagedBlock -Text $current -Line $Line)
}

# ---------------------------------------------------------------------------------------------------------------
# Handlers: Git
# ---------------------------------------------------------------------------------------------------------------

function Get-BmcGitValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Key)

    $result = Invoke-BmcNative -FilePath 'git' -ArgumentList @('config', '--global', '--get', $Key)
    if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) { return ([string]$result.Output[0]).Trim() }
    $null
}

function Test-BmcGitKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Key,
        [AllowNull()][AllowEmptyString()][string] $Desired
    )

    [string](Get-BmcGitValue -Key $Key) -ceq [string]$Desired
}

function Write-BmcGitKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,
        [AllowNull()][AllowEmptyString()][string] $Desired
    )

    if ([string]::IsNullOrEmpty($Desired)) {
        # 'git config --unset' exits with 5 when the key is already absent: that is the state we want.
        $result = Invoke-BmcNative -FilePath 'git' -ArgumentList @('config', '--global', '--unset', $Key)
        if ($result.ExitCode -notin @(0, 5)) { throw "git config --unset $Key failed ($($result.ExitCode)): $($result.Output -join ' ')" }
    }
    else {
        $result = Invoke-BmcNative -FilePath 'git' -ArgumentList @('config', '--global', $Key, $Desired)
        if ($result.ExitCode -ne 0) { throw "git config $Key failed ($($result.ExitCode)): $($result.Output -join ' ')" }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Handlers: Scoop
# ---------------------------------------------------------------------------------------------------------------

function Test-BmcScoopProxy {
    <# Reads Scoop's own JSON store directly: faster than spawning scoop and independent of its output format. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $ConfigPath,
        [AllowNull()][AllowEmptyString()][string] $Desired
    )

    $current = $null
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($json -and $json.PSObject.Properties['proxy']) { $current = [string]$json.proxy }
        }
        catch { Write-Verbose "Unreadable Scoop config '$ConfigPath': $($_.Exception.Message)" }
    }
    [string]$current -ceq [string]$Desired
}

function Write-BmcScoopProxy {
    # An action hands the same argument table to its Test and Apply handlers, so both must bind every key;
    # ConfigPath is only needed by the reader.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ConfigPath')]
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [AllowNull()][AllowEmptyString()][string] $Desired
    )

    # Writes go through 'scoop config' (the supported interface); only reads bypass it.
    if ([string]::IsNullOrEmpty($Desired)) {
        $result = Invoke-BmcNative -FilePath 'scoop' -ArgumentList @('config', 'rm', 'proxy')
    }
    else {
        $result = Invoke-BmcNative -FilePath 'scoop' -ArgumentList @('config', 'proxy', $Desired)
    }
    if ($result.ExitCode -ne 0) { throw "scoop config failed ($($result.ExitCode)): $($result.Output -join ' ')" }
}

# ---------------------------------------------------------------------------------------------------------------
# Handlers: user environment
# ---------------------------------------------------------------------------------------------------------------

function Test-BmcUserEnv {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][AllowEmptyString()][string] $Desired
    )

    [string](Get-BmcUserEnv -Name $Name) -ceq [string]$Desired
}

# ---------------------------------------------------------------------------------------------------------------
# Actions (Command pattern) and providers (Strategy)
# ---------------------------------------------------------------------------------------------------------------

function New-BmcAction {
    <# Handlers are referenced by command name (not scriptblock) so they resolve at call time in the right scope. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Tool,
        [Parameter(Mandatory)][string] $Description,
        [string] $Requires,
        [Parameter(Mandatory)][string] $Test,
        [Parameter(Mandatory)][string] $Apply,
        [hashtable] $Arguments = @{}
    )

    [pscustomobject]@{
        PSTypeName  = 'Bmc.Action'
        Tool        = $Tool
        Description = $Description
        Requires    = $Requires
        Test        = $Test
        Apply       = $Apply
        Arguments   = $Arguments
    }
}

function Format-BmcValue {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Value)

    if ([string]::IsNullOrEmpty($Value)) { return '(unset)' }
    $Value
}

function Get-BmcGitAction {
    # Every provider shares one signature (State, Config, Paths) so Get-BmcPlan can call them uniformly.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param($State, $Config, $Paths)

    # 'http://:@host:port' (empty user and password) makes libcurl authenticate with the current Windows identity
    # through SSPI; this is the proxy format Git understands, as documented in the Scoop proxy wiki.
    $desired = $State.ProxyUrl
    $useCurrentUser = Get-BmcConfigValue -Config $Config -Path 'git.useCurrentUserCredentials'
    if ($desired -and $State.ProxyMode -eq 'auto' -and ($null -eq $useCurrentUser -or [bool]$useCurrentUser)) {
        $uri = [uri]$desired
        $desired = '{0}://:@{1}:{2}' -f $uri.Scheme, $uri.Host, $uri.Port
    }

    New-BmcAction -Tool 'Git' -Requires 'git' -Test 'Test-BmcGitKey' -Apply 'Write-BmcGitKey' `
        -Description ("git config --global http.proxy = {0}" -f (Format-BmcValue $desired)) `
        -Arguments @{ Key = 'http.proxy'; Desired = $desired }
}

function Get-BmcScoopAction {
    # Every provider shares one signature (State, Config, Paths) so Get-BmcPlan can call them uniformly.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param($State, $Config, $Paths)

    # 'currentuser@default' = proxy taken from Internet Options (so PAC-aware) with the current Windows credentials.
    $desired = $null
    if ($State.ProxyUrl) {
        if ($State.ProxyMode -eq 'auto') { $desired = 'currentuser@default' }
        else { $desired = $State.ProxyHostPort }
    }

    New-BmcAction -Tool 'Scoop' -Requires 'scoop' -Test 'Test-BmcScoopProxy' -Apply 'Write-BmcScoopProxy' `
        -Description ("scoop config proxy = {0}" -f (Format-BmcValue $desired)) `
        -Arguments @{ ConfigPath = $Paths.ScoopConfig; Desired = $desired }
}

function Get-BmcUvAction {
    # Every provider shares one signature (State, Config, Paths) so Get-BmcPlan can call them uniformly.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param($State, $Config, $Paths)

    # uv has no proxy key; it honours HTTP(S)_PROXY / NO_PROXY, which the Environment provider manages.
    $lines = @()
    if ($State.UseNexus) { $lines = @('index-url = "{0}"' -f $State.PypiIndexUrl) }

    New-BmcAction -Tool 'Uv' -Requires 'uv' -Test 'Test-BmcManagedFile' -Apply 'Write-BmcManagedFile' `
        -Description ("uv.toml index-url = {0}" -f (Format-BmcValue $State.PypiIndexUrl)) `
        -Arguments @{ Path = $Paths.UvConfig; Line = $lines }
}

function Get-BmcNpmAction {
    # Every provider shares one signature (State, Config, Paths) so Get-BmcPlan can call them uniformly.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param($State, $Config, $Paths)

    $lines = New-Object System.Collections.Generic.List[string]
    if ($State.UseNexus) { $lines.Add("registry=$($State.NpmRegistryUrl)") }
    if ($State.ProxyUrl) {
        $lines.Add("proxy=$($State.ProxyUrl)")
        $lines.Add("https-proxy=$($State.ProxyUrl)")
        $lines.Add("noproxy=$($State.NoProxy)")
    }

    New-BmcAction -Tool 'Npm' -Requires 'npm' -Test 'Test-BmcManagedFile' -Apply 'Write-BmcManagedFile' `
        -Description ('.npmrc registry = {0}, proxy = {1}' -f (Format-BmcValue $State.NpmRegistryUrl), (Format-BmcValue $State.ProxyUrl)) `
        -Arguments @{ Path = $Paths.NpmRc; Line = $lines.ToArray() }
}

function Get-BmcEnvironmentAction {
    # Every provider shares one signature (State, Config, Paths) so Get-BmcPlan can call them uniformly.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    [CmdletBinding()]
    param($State, $Config, $Paths)

    $wanted = [ordered]@{
        HTTP_PROXY  = $State.ProxyUrl
        HTTPS_PROXY = $State.ProxyUrl
        NO_PROXY    = $State.NoProxy
    }
    foreach ($name in $wanted.Keys) {
        New-BmcAction -Tool 'Environment' -Test 'Test-BmcUserEnv' -Apply 'Write-BmcUserEnv' `
            -Description ('user variable {0} = {1}' -f $name, (Format-BmcValue $wanted[$name])) `
            -Arguments @{ Name = $name; Desired = $wanted[$name] }
    }
}

function Get-BmcPlan {
    <# Registry of providers; adding a tool means adding one function and one entry here. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Paths,
        [string[]] $Tool
    )

    $providers = [ordered]@{
        Git         = 'Get-BmcGitAction'
        Scoop       = 'Get-BmcScoopAction'
        Uv          = 'Get-BmcUvAction'
        Npm         = 'Get-BmcNpmAction'
        Environment = 'Get-BmcEnvironmentAction'
    }

    $enabled = @($providers.Keys)
    $configured = @(Get-BmcConfigValue -Config $Config -Path 'tools' | Where-Object { $_ })
    if ($configured.Count -gt 0) { $enabled = $configured }
    if ($Tool) { $enabled = @($Tool) }

    foreach ($name in $providers.Keys) {
        if ($enabled -contains $name) {
            $provider = $providers[$name]
            & $provider -State $State -Config $Config -Paths $Paths
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------------------------------------------

function Invoke-BmcAction {
    <#
    Template method shared by every action: check -> (ask) -> apply -> verify.
    The post-apply verification re-runs the Test handler, so a write that silently did not stick (policy-managed
    setting, tool ignoring the value) is reported as Failed instead of a false "Changed".
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)] $Action)

    $result = { param($status, $detail) [pscustomobject]@{ PSTypeName = 'Bmc.Result'; Tool = $Action.Tool; Status = $status; Detail = $detail } }

    if ($Action.Requires -and -not (Test-BmcCommand -Name $Action.Requires)) {
        return & $result 'Skipped' "'$($Action.Requires)' not found on PATH"
    }

    $arguments = $Action.Arguments
    $testHandler = $Action.Test
    $applyHandler = $Action.Apply

    try {
        if (& $testHandler @arguments) { return & $result 'Unchanged' $Action.Description }

        if (-not $PSCmdlet.ShouldProcess($Action.Tool, $Action.Description)) {
            $status = 'Declined'
            if ($WhatIfPreference) { $status = 'WouldChange' }
            return & $result $status $Action.Description
        }

        & $applyHandler @arguments
        if (-not (& $testHandler @arguments)) { throw 'state did not converge after applying the change' }
        & $result 'Changed' $Action.Description
    }
    catch {
        & $result 'Failed' ("{0}: {1}" -f $Action.Description, $_.Exception.Message)
    }
}

function Invoke-BmcMain {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [ValidateSet('Auto', 'Office', 'Vpn', 'Home')][string] $Scenario = 'Auto',
        [string] $ConfigPath,
        [string[]] $Tool,
        [switch] $DetectOnly,
        [switch] $InitConfig
    )

    $paths = Get-BmcPath
    if (-not $ConfigPath) { $ConfigPath = $paths.Config }

    if ($InitConfig) {
        $created = Write-BmcConfigTemplate -Path $ConfigPath
        $status = 'Exists'
        if ($created) { $status = 'Created' }
        return [pscustomobject]@{ PSTypeName = 'Bmc.Result'; Tool = 'Config'; Status = $status; Detail = $ConfigPath }
    }

    $config = Read-BmcConfig -Path $ConfigPath

    if ($Scenario -eq 'Auto') {
        $interfaces = @(Get-BmcNetworkInterface)
        foreach ($nic in $interfaces) {
            Write-Verbose ("NIC '{0}' up={1} suffix='{2}' ({3})" -f $nic.Name, $nic.IsUp, $nic.DnsSuffix, $nic.Description)
        }
        $detected = Resolve-BmcScenario -Interface $interfaces -Config $config
    }
    else {
        $detected = [pscustomobject]@{ Scenario = $Scenario; Reason = 'forced with -Scenario' }
    }

    if ($DetectOnly) { return $detected }

    $state = Resolve-BmcDesiredState -Config $config -Scenario $detected.Scenario
    Write-Information ("bmc: scenario {0} ({1}); proxy {2}; nexus {3}" -f
        $detected.Scenario, $detected.Reason, (Format-BmcValue $state.ProxyUrl), $state.UseNexus) -InformationAction Continue

    $plan = @(Get-BmcPlan -State $state -Config $config -Paths $paths -Tool $Tool)
    foreach ($action in $plan) { Invoke-BmcAction -Action $action }
}

# Dot-sourcing (Pester, interactive exploration) only loads the functions above.
if ($MyInvocation.InvocationName -eq '.') { return }

$mainArguments = @{ Scenario = $Scenario; DetectOnly = $DetectOnly; InitConfig = $InitConfig }
if ($ConfigPath) { $mainArguments['ConfigPath'] = $ConfigPath }
if ($Tool) { $mainArguments['Tool'] = $Tool }

$bmcResults = @(Invoke-BmcMain @mainArguments)
$bmcResults

if (@($bmcResults | Where-Object { $_.PSObject.Properties['Status'] -and $_.Status -eq 'Failed' }).Count -gt 0) { exit 1 }
