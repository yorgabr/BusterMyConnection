# Contributing to Buster-MyConnection

## Welcome, Fellow Traveler

If you are reading this, you have likely experienced the particular flavor of frustration that comes from corporate network infrastructure. Perhaps you have spent hours debugging why your carefully configured CNTLM setup suddenly stopped working after a VPN connection. Maybe you have written your own wrapper scripts, only to find them brittle and specific to your exact environment. Or you might simply recognize that tools should adapt to humans, not the reverse.

Buster-MyConnection exists to make Windows proxy management invisible and reliable. Your contributions — whether fixing bugs, improving documentation, adding support for new VPN clients, or enhancing the diagnostic capabilities — help move this vision forward. This guide exists to make your contribution process as smooth as the script aims to make your network connectivity.

---

## The Decorator Pattern: Your Primary Extension Point

The most valuable contributions to Buster-MyConnection typically involve expanding its VPN detection capabilities. The script implements the **Decorator Pattern** for this purpose, and understanding this architecture is essential before adding new detectors.

### Why Decorators?

Corporate VPN clients are legion: BIG-IP Edge Client, Cisco AnyConnect, FortiClient, Palo Alto GlobalProtect, SonicWall NetExtender, Check Point Endpoint Security, and dozens more. Each detects its presence differently—registry keys, running processes, network interface configurations, file system artifacts, Windows services. Each requires slightly different reconciliation logic when detected.

A naive implementation might use a series of `if-elseif` statements, growing longer and more unwieldy with each contribution. The decorator pattern offers a superior alternative: a **chain of responsibility** where each link attempts detection, passing control to the next link upon failure. This creates loosely coupled, highly cohesive components that can be tested independently and combined flexibly.

### The Interface Contract

Every VPN detector must implement the `IVpnDetector` interface:

```powershell
class IVpnDetector {
    [VpnDetectionResult] Detect() {
        throw "Must implement Detect() method"
    }
}
```

The `Detect()` method returns a `VpnDetectionResult` object with four properties:

```powershell
class VpnDetectionResult {
    [bool]$IsVpnActive          # $true if this detector found its VPN
    [string]$VpnType            # Human-readable identifier (e.g., "Cisco AnyConnect")
    [string]$Description        # Diagnostic details for logging
    [scriptblock]$ReconcileAction  # Code to execute if VPN detected
}
```

### The Chain Structure

Detectors wrap each other like Russian dolls:

```
[YourNewDetector] → [BigIpVpnDetector] → [BaseVpnDetector]
     ↓                      ↓                      ↓
   Tries first          Tries second         Always returns NoVpnDetected
```

Each concrete decorator follows this template:

```powershell
class YourVpnDetector : IVpnDetector {
    [IVpnDetector]$NextDetector
    
    YourVpnDetector([IVpnDetector]$next) {
        $this.NextDetector = $next
    }
    
    [VpnDetectionResult] Detect() {
        # 1. Attempt detection using your specific logic
        if ($yourDetectionCondition) {
            return [VpnDetectionResult]::new(
                $true,
                "Your VPN Name",
                "Descriptive message for logging",
                { 
                    param([string]$IniPath) 
                    # Reconciliation logic here
                }
            )
        }
        
        # 2. If not detected, delegate to next in chain
        return $this.NextDetector.Detect()
    }
}
```

### Building the Chain

The `New-VpnDetectionChain` function constructs the chain. When adding your detector, insert it at the appropriate position—typically early in the chain if your VPN is common, or later if it is specialized:

```powershell
function New-VpnDetectionChain {
    $chain = [BaseVpnDetector]::new()
    $chain = [BigIpVpnDetector]::new($chain)
    $chain = [YourVpnDetector]::new($chain)  # Add your decorator here
    return $chain
}
```

---

## Understanding State Persistence and Recovery

Beyond VPN detection, Buster-MyConnection implements a sophisticated state management system that persists execution context between runs. This enables seamless transitions between network environments without manual intervention.

When the script detects that the corporate proxy is unreachable, it does not merely exit—it transitions to Direct Access mode. In this transition, it captures a snapshot of all proxy-related environment variables, stores them in a state file located at `%LOCALAPPDATA%\Buster-MyConnection\state.json`, and then removes those variables from the current session. This allows applications to access the internet directly without proxy interference.

The true elegance emerges upon the next execution. When you return to the office and reconnect to the corporate network, the script detects the previous Direct Access state and automatically restores those saved environment variables before attempting to start CNTLM. This recovery happens transparently, ensuring that your tools transition smoothly from direct internet access back to proxied operation without requiring you to remember which variables need resetting or what values they held.

When implementing new features, consider how they interact with this state machine. Features that modify proxy variables should respect the backup and restore mechanisms. Features that alter network configuration should persist their state to enable future recovery. The goal is always graceful continuity: the script should remember what it did and how to undo it, ensuring that network transitions feel effortless rather than jarring.

---

## The JustCheck Diagnostic Mode

Buster-MyConnection now includes a comprehensive diagnostic capability through the `-JustCheck` switch. This mode exists for those moments when you need visibility without modification—when you want to understand the current state of affairs before deciding whether to act.

When invoked with `-JustCheck`, the script transforms into a read-only inspector. It examines whether CNTLM is running and identifies the process holding the listening port. It extracts the process metadata—executable path, command line arguments, configuration file location—through the same resilient multi-provider approach used in standard operation. It locates and parses the active `cntlm.ini`, evaluating the configuration for completeness and security posture, checking for required directives like Username, Proxy, and Listen, while warning about plaintext passwords or missing authentication hashes.

Most importantly, it validates connectivity. Using curl with configurable timeouts and retry logic, it tests both HTTP and HTTPS connectivity through the CNTLM proxy, capturing detailed error information when tests fail. This validation provides the confidence that, should you choose to proceed with standard operation, the infrastructure will support your applications.

The diagnostic mode reports its findings through a structured three-phase output: process discovery, configuration analysis, and connectivity testing. It concludes with a summary indicating which components passed inspection and which require attention. This makes `-JustCheck` invaluable for health monitoring in automation pipelines, pre-flight checks before critical operations, and troubleshooting scenarios where you suspect the proxy infrastructure may be misbehaving but wish to confirm before making changes.

Contributors adding new detection or validation logic should ensure it integrates cleanly with the diagnostic mode. New VPN detectors should expose their detection status when `-JustCheck` is active. New health checks should report their results without attempting remediation. The diagnostic mode is the script's conscience: it sees, it understands, it reports, but it does not judge or intervene unless explicitly directed.

---

## Step-by-Step: Adding a New VPN Detector

### Step 1: Research Your VPN Client

Before writing code, understand how your VPN client announces its presence:

1. **Registry artifacts**: Check `HKLM:\\SOFTWARE` and `HKCU:\\Software` for vendor-specific keys
2. **Process indicators**: Identify the main executable and background services
3. **Network signatures**: Look for virtual network adapters, specific IP ranges, or DNS suffixes
4. **File system clues**: Check Program Files for installation directories
5. **Windows services**: Identify services that start with the VPN client

Use PowerShell to explore:

```powershell
# Search for registry keys
Get-ChildItem "HKLM:\\SOFTWARE\\" -Recurse -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match "YourVendor" }

# Check for processes
Get-Process | Where-Object { $_.ProcessName -match "yourvpn" }

# Look for network adapters
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "YourVPN" }
```

### Step 2: Design Your Detection Logic

Create a detection strategy that is **specific enough to avoid false positives** but **robust enough to handle version variations**. Consider these patterns:

**Registry-based detection** (preferred for reliability):

```powershell
$regPath = 'HKLM:\\SOFTWARE\\YourVendor\\YourVPN'
try {
    $installPath = (Get-ItemProperty -Path $regPath -Name InstallPath -ErrorAction Stop).InstallPath
    if (Test-Path $installPath) {
        # VPN likely installed
    }
} catch {}
```

**Process-based detection** (for runtime status):

```powershell
$process = Get-Process -Name "YourVpnClient" -ErrorAction SilentlyContinue
if ($process -and $process.MainModule.FileVersionInfo.ProductVersion) {
    # VPN is running
}
```

**Service-based detection** (for persistent daemons):

```powershell
$service = Get-Service -Name "YourVpnService" -ErrorAction SilentlyContinue
if ($service -and $service.Status -eq 'Running') {
    # VPN service active
}
```

### Step 3: Determine Reconciliation Logic

When your VPN is detected, what must change in `cntlm.ini`? Common patterns:

- **System proxy reconciliation**: Use `Set-CntlmParentProxyFromSystem` (most common)
- **Static proxy override**: Write a specific proxy address known to your VPN
- **Port adjustment**: Change CNTLM's listening port to avoid conflicts
- **Authentication changes**: Update credentials or hash methods

### Step 4: Implement Your Decorator

Create your class following the template. Here is a complete example for **Palo Alto GlobalProtect**:

```powershell
class GlobalProtectDetector : IVpnDetector {
    [IVpnDetector]$NextDetector
    
    GlobalProtectDetector([IVpnDetector]$next) {
        $this.NextDetector = $next
    }
    
    [VpnDetectionResult] Detect() {
        # Detection: Check for PanGPS.exe process or installation directory
        $gpProcess = Get-Process -Name "PanGPS" -ErrorAction SilentlyContinue
        $gpPath = "${env:ProgramFiles}\\Palo Alto Networks\\GlobalProtect"
        $isInstalled = Test-Path $gpPath
        
        if ($gpProcess -or $isInstalled) {
            $status = if ($gpProcess) { "running" } else { "installed but not running" }
            
            return [VpnDetectionResult]::new(
                [bool]($gpProcess -or $isInstalled),
                "Palo Alto GlobalProtect",
                "GlobalProtect client detected ($status)",
                {
                    param([string]$IniPath)
                    # GlobalProtect typically uses system proxy settings
                    Set-CntlmParentProxyFromSystem -IniPath $IniPath
                    
                    # Optional: GlobalProtect-specific adjustments
                    Out-Info "GlobalProtect reconciliation complete"
                }
            )
        }
        
        return $this.NextDetector.Detect()
    }
}
```

### Step 5: Add to the Chain and Document

Update `New-VpnDetectionChain`:

```powershell
function New-VpnDetectionChain {
    $chain = [BaseVpnDetector]::new()
    $chain = [BigIpVpnDetector]::new($chain)
    $chain = [GlobalProtectDetector]::new($chain)  # Your addition
    return $chain
}
```

Update this `CONTRIBUTING.md` to document your VPN client, helping future contributors understand the landscape.

### Step 6: Test Thoroughly

Test your detector in these scenarios:

1. **VPN not installed**: Should pass through to next detector
2. **VPN installed but not running**: Behavior depends on your logic
3. **VPN installed and running**: Should detect and reconcile
4. **Multiple VPNs**: Ensure your detector plays well with others
5. **VPN uninstallation**: Ensure detection fails cleanly after removal

Additionally, verify that your detector integrates properly with the `-JustCheck` diagnostic mode. When running with `-JustCheck`, your detector should report its findings without executing reconciliation actions. The detection status should appear in the diagnostic output, helping users understand whether their VPN is recognized even when no changes are being made.

---

## Coding Standards

### PowerShell Style

- **Indentation**: 4 spaces (no tabs).
- **Line length**: Keep under 120 characters for readability.
- **Casing**: PascalCase for classes, camelCase for functions and variables.
- **Comments**: Document why, not what. The code should explain itself.

### Class Structure

Place class definitions at the top of the script, after the parameter block but before functions. Order matters for PowerShell's parser:

1. Parameter block
2. Class definitions (interfaces first, then implementations)
3. Helper functions
4. Main execution flow

### Error Handling

Use `try-catch` blocks in detection logic to prevent one failing detector from breaking the entire chain:

```powershell
try {
    # Detection logic that might fail
} catch {
    # Log warning but do not throw; allow chain to continue
    Out-Warn "Detection failed for ${VpnType}: $($_.Exception.Message)"
    return $this.NextDetector.Detect()
}
```

### Logging

Use the established output functions:
- `Out-Info`: General operational messages
- `Out-Warn`: Non-fatal issues and degradation notices
- `Out-Success`: Successful completions
- `Out-Error`: Fatal errors (rare in detection logic)

---

## Testing Your Contribution

### Manual Testing

Create a test matrix:

| Scenario | Expected Behavior |
|----------|-------------------|
| Fresh Windows install, no CNTLM | Auto-installs CNTLM, launches wizard |
| CNTLM present, no config | Launches configuration wizard |
| Config present, proxy dead | Direct access mode, unsets proxy vars, persists state |
| Config present, proxy healthy, no VPN | Starts CNTLM normally, persists Proxied state |
| Config present, proxy healthy, your VPN active | Detects VPN, reconciles, starts CNTLM |
| VPN active then disconnected | Next run detects no VPN, uses static config |
| Previous DirectAccess, now VPN available | Restores proxy vars, reconciles, starts CNTLM |
| `-JustCheck` with healthy setup | Reports all checks passed, exit 0, no changes |
| `-JustCheck` with dead proxy | Reports connectivity failure, exit 1, no changes |

### Automated Testing (Future)

The project aspires to Pester-based unit tests for the decorator chain and state management. When implemented, your contributions should include tests for:

- Detection returns correct result when VPN present or absent
- Detection delegates correctly through the chain
- ReconcileAction executes without error
- State persistence saves and restores correctly
- Error handling does not break chain or corrupt state
- `-JustCheck` mode reports without side effects

---

## Documentation Requirements

Every contribution must update relevant documentation:

- **README.md**: If adding features visible to end users, including `-JustCheck` capabilities and state management behaviors
- **CONTRIBUTING.md**: If adding patterns future contributors should follow, or documenting your VPN client's quirks
- **Code comments**: Classes and public methods require `.SYNOPSIS` and `.DESCRIPTION`

For VPN detectors, document in `CONTRIBUTING.md`:
- What registry keys or processes you checked
- Why you chose your specific detection logic
- Any vendor-specific quirks encountered
- How your detector behaves in `-JustCheck` mode

---

## Submitting Your Contribution

### Pull Request Process

1. **Fork** the repository
2. **Create a feature branch**: `git checkout -b add-globalprotect-detector`
3. **Commit** with clear messages: "Add Palo Alto GlobalProtect VPN detector"
4. **Push** to your fork
5. **Open a Pull Request** against the main repository

### PR Description Template

```markdown
## Summary
Brief description of what this PR does.

## VPN Client (if applicable)
- **Vendor**: Palo Alto Networks
- **Product**: GlobalProtect
- **Detection Method**: Checks for PanGPS.exe process and installation directory
- **Reconciliation**: Uses system proxy settings via Set-CntlmParentProxyFromSystem
- **JustCheck Behavior**: Reports detection status without reconciliation

## Testing
- [ ] Tested on Windows 10
- [ ] Tested on Windows 11
- [ ] Tested with VPN running
- [ ] Tested with VPN not installed
- [ ] Verified chain delegation works
- [ ] Verified -JustCheck integration

## Documentation
- [ ] Updated CONTRIBUTING.md with detector details
- [ ] Added code comments explaining vendor-specific logic
- [ ] Documented -JustCheck behavior
```

---

## The Spirit of Contribution

Buster-MyConnection is fundamentally a tool of **developer ergonomics**. Every contribution should ask: does this make the tool more reliable, more adaptable, or more transparent for the person using it?

The decorator architecture exists not to show off object-oriented patterns, but to ensure that no developer's specific VPN client is left behind. The health check exists not to be clever, but to prevent the subtle misery of a half-functional proxy. The wizard exists not to be fancy, but to turn a configuration file format that predates Stack Overflow into a five-minute setup. The state persistence exists not to be complicated, but to ensure that transitioning between direct and proxied access feels like a continuous experience rather than a series of manual repairs. The diagnostic mode exists not to add switches, but to provide confidence through visibility.

Contribute with empathy for the next developer who inherits your corporate network. They will thank you, silently, every morning when their tools simply work, and every evening when they can verify connectivity health with a single command before heading home.

---

## Questions and Support

Open an issue for:
- Bugs in existing VPN detection
- Clarifications on decorator implementation
- Questions about state persistence and recovery
- Proposals for architectural changes

Discussions are welcome for:
- New VPN clients to support
- Alternative detection strategies
- Improvements to the health check logic
- Enhancements to the diagnostic capabilities

---

## Recognition

Contributors who add VPN detectors will be acknowledged in the README, linking their GitHub profile to the specific client they helped support. Contributors who enhance the diagnostic infrastructure or state management systems will be recognized for improving the tool's reliability and transparency. This is not merely credit, it is a map for future users wondering if their particular corporate infrastructure is covered, and a testament to the collaborative spirit that makes open source sustainable.

Thank you for making corporate networking slightly less painful for all of us!
