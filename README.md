# BusterMyConnection

![Banner](docs/images/banner.webp)

![CI](https://github.com/yorgabr/bustermyconnection/workflows/CI/badge.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey.svg)
![License](https://img.shields.io/badge/License-GPL--3.0-green.svg)

## The Self-Healing CNTLM Launcher for Windows

There comes a moment in every Windows developer's life when corporate proxy servers transform from mere inconveniences into full-blown productivity killers. You have meticulously configured CNTLM to bridge the gap between your tools and the outside world, only to find yourself tethered to a VPN client that speaks its own peculiar dialect of proxy configuration. Or worse, you arrive at the office to discover the upstream proxy has vanished into the digital ether, leaving your carefully crafted setup hanging in the void, timing out every request until even the simplest `pip|npm|apt|yum|winget install` becomes an exercise in patience. If this is not enough, think about CI lifecycle automation...

**Buster-MyConnection** was born from these exact frustrations. It is not merely a wrapper around the venerable CNTLM authentication proxy, it is an intelligent orchestration layer that understands the messy reality of modern corporate networking. The script embodies a philosophy of graceful degradation and self-healing automation. When components are missing, it does not surrender with obscure error messages. Instead, it downloads, installs, and configures them. When the network environment shifts beneath your feet, as it inevitably does when VPN clients engage, it detects these changes and reconciles your configuration accordingly. And when the fundamental infrastructure fails — the corporate proxy itself refusing connections — it makes the bold but necessary choice to step aside entirely, clearing the path for direct internet access rather than perpetuating a deadlock.

This is a tool designed for developers who refuse to let network architecture dictate their workflow. It respects your time by operating idempotently, allowing repeated execution without side effects. It honors your preferences through comprehensive quiet-mode support for automation scenarios. And it maintains transparency through detailed logging, ensuring that when things do go awry, you possess the diagnostic information necessary to understand why.

---

## The Architecture of Resilience

At its heart, Buster-MyConnection implements a sophisticated decision tree that evaluates the health of your networking stack before committing to action. The process begins with infrastructure verification: is CNTLM itself present? If not, the script reaches out to the community-maintained repository, retrieves the latest stable build, and establishes a portable installation that requires no administrative privileges and leaves no registry footprint. This self-healing capability means you can drop the script onto any Windows machine and expect it to bootstrap its own dependencies.

Next comes configuration resolution. The script searches for your `cntlm.ini` file in standard locations, falling back to an interactive wizard when none exists. This wizard does not merely collect parameters, it educates! It explains the security implications of password storage, offers to generate NTLM hashes rather than accepting plaintext, and validates your inputs to prevent the subtle errors that plague proxy configurations. The resulting configuration includes sensible defaults for local listening ports, bypass patterns for internal addresses, and comments guiding future manual edits.

The critical juncture arrives with the upstream proxy health check. Before starting CNTLM and potentially subjecting your applications to connection timeouts, the script attempts a TCP connection to the proxy server declared in your configuration. This is not a mere ping, it validates that the specific port and protocol your applications will use is actually responsive. If this check fails (if the proxy is down, if you are working remotely without VPN access or if the network infrastructure has failed) the script makes the counterintuitive but correct choice: it *does not* start CNTLM! Instead, it removes all proxy-related environment variables from your current session, enabling direct internet access. It then exits cleanly, having transformed a potential hour of debugging into a momentary inconvenience. Run the script again when connectivity returns, and CNTLM resumes its role without fuss.

For those navigating the labyrinthine world of corporate VPNs, Buster-MyConnection offers a particularly elegant solution. Through the **Decorator Pattern**, the script implements a chain of responsibility for VPN detection. Each decorator in the chain attempts to identify a specific VPN client: BIG-IP Edge Client, Cisco AnyConnect, FortiClient, or your own custom implementation. When a VPN is detected, the decorator provides not just identification but a reconciliation strategy: a script block that updates your CNTLM configuration to match the VPN's proxy requirements. This architecture means extending support for new VPN clients requires no modification to existing code, you simply add a new decorator to the chain.

---

## Installation and Usage

### Prerequisites

Buster-MyConnection requires PowerShell 5.1 or later, including PowerShell Core 6/7+. It functions on Windows 10, Windows 11, and Windows Server 2016+. No administrative privileges are required for standard operation, as the script maintains a user-local portable installation of CNTLM.

### Quick Start

The simplest invocation requires no arguments:

```powershell
.\Buster-MyConnection.ps1
```

This command triggers the full intelligence of the script. If CNTLM is absent, it installs. If configuration is missing, it interviews you. If the upstream proxy is dead, it falls back to direct access. If BIG-IP Edge Client is active, it reconciles the proxy settings. The script exits with code `0` on success (including intentional fallback to direct access) and non-zero codes only for genuine errors.

You can also do:

```powershell
# Diagnostic mode only—check status without making changes
.\Buster-MyConnection.ps1 -JustCheck

# Health check with custom timeout
.\Buster-MyConnection.ps1 -JustCheck -CheckTimeoutSeconds 60
```

### Command-Line Options

For scenarios requiring more control:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-IniPath` | `$HOME\cntlm.ini` | Path to CNTLM configuration file |
| `-CntlmPath` | `$env:LOCALAPPDATA\Programs\CNTLM\cntlm.exe` | Path to CNTLM executable |
| `-LogDirectory` | `$env:TEMP` | Directory for CNTLM log files |
| `-KeepExisting` | `$false` | Allow concurrent CNTLM instances |
| `-Quiet` | `$false` | Suppress non-error console output |
| `-ProxyTestTimeoutSeconds` | `5` | Timeout for upstream proxy health check |
| `-ProxyTestPort` | `80` | Port for TCP connectivity test |
| `-DirectAccessTestTimeoutSeconds` | `10` | Timeout for direct internet validation |
| `-JustCheck` | `$false` | Diagnostic mode: inspect only, no changes |
| `-CheckTimeoutSeconds` | `30` | Timeout for curl connectivity tests (check mode) |
| `-CheckRetries` | `2` | Retry attempts for connectivity tests (check mode) |

### Examples

**Using an alternate configuration:**

```powershell
.\Buster-MyConnection.ps1 -IniPath "C:\Tools\cntlm-work.ini"
```

**Preserving existing CNTLM processes:**

```powershell
.\Buster-MyConnection.ps1 -KeepExisting
```

**Silent execution for automation:**

```powershell
.\Buster-MyConnection.ps1 -Quiet
if ($LASTEXITCODE -ne 0) { 
    Write-Error "CNTLM startup failed" 
}
```

**Comprehensive diagnostics (read-only):**

```powershell
.\Buster-MyConnection.ps1 -JustCheck -Verbose
```
---

## Understanding the VPN Decorator Architecture

The decorator pattern implementation represents the script's most sophisticated architectural feature. In object-oriented design, the decorator pattern allows behavior to be added to individual objects dynamically without affecting the behavior of other objects from the same class. Buster-MyConnection adapts this concept to PowerShell's class-based syntax to create an extensible VPN detection system.

The foundation is the `IVpnDetector` interface, which defines a single method: `Detect()`. This method returns a `VpnDetectionResult` object containing four critical properties: whether a VPN is active, the type of VPN detected, a human-readable description, and a script block containing the reconciliation logic.

The `BaseVpnDetector` class implements this interface as a sentinel. It always returns `IsVpnActive = $false`, serving as the terminus of the decorator chain. When no VPN is detected by any decorator, this sentinel value propagates back through the chain.

Concrete decorators wrap this base. The `BigIpVpnDetector`, for instance, examines the Windows registry for AutoConfigURL settings pointing to `127.0.0.1` on ports in the 4470-4579 range — the distinctive fingerprints of the BIG-IP Edge Client. If found, it returns an active result with a reconciliation script block that invokes `Set-CntlmParentProxyFromSystem`. If not found, it delegates to its wrapped detector, allowing the chain to continue.

This design achieves **open/closed principle** perfection: the system is open for extension (new VPN types can be added) but closed for modification (existing code need not change). Adding support for a new VPN client requires only creating a class that implements `IVpnDetector` and inserting it into the chain built by `New-VpnDetectionChain`.

---

## Exit Codes and Diagnostics

Buster-MyConnection communicates its outcome through exit codes:

| Code | Meaning |
|------|---------|
| `0` | Success: CNTLM started normally, or direct access mode activated (proxy dead) |
| `1` | General failure: CNTLM process did not persist, or unexpected error |
| `2` | Configuration wizard failed |
| `3` | CNTLM installation failed |

When troubleshooting, examine the log file specified in the script output. The script generates timestamped logs in your TEMP directory by default, capturing CNTLM's verbose output for post-mortem analysis.

---

## The Philosophy of Graceful Degradation

Network tooling often suffers from binary thinking: either everything works perfectly, or everything fails catastrophically. Buster-MyConnection rejects this dichotomy. It recognizes that corporate networks are messy, that VPN clients are idiosyncratic, that proxy servers occasionally fail, and that developers need tools which adapt to these realities rather than crumbling before them.

When the upstream proxy dies, the script does not spam you with connection timeout errors. It does not leave CNTLM running as a zombie process consuming resources while serving no purpose. It cleanly exits the middleman and lets your applications speak directly to the internet. This is not failure; it is intelligent adaptation.

When BIG-IP Edge Client spins up its local PAC server on an ephemeral port, the script does not force you to manually reconfigure CNTLM every time your VPN connects. It detects the change, reconciles the configuration, and maintains seamless connectivity.

When you move from office to home to coffee shop, the script travels with you, making the necessary adjustments without demanding your attention. It is infrastructure that understands its role is to enable your work, not to become a subject of it.

---

## License and Attribution

Buster-MyConnection is released under the GPL-3 License. It relies upon the community-maintained [versat/cntlm](https://github.com/versat/cntlm) fork of the original CNTLM project, which continues the legacy of this essential tool after the original SourceForge repository entered maintenance-only mode.

The script was crafted with attention to cross-version PowerShell compatibility, ensuring functionality across the fragmented landscape of Windows PowerShell and PowerShell Core installations. It respects your environment by operating solely within process-scope environment variables, never touching system-wide configuration without explicit direction.

---

## Acknowledgments

The decorator pattern implementation was inspired by the recognition that corporate VPN landscapes are too diverse for hardcoded solutions. The health-check mechanism emerged from one too many mornings spent wondering why every `git fetch` had suddenly slowed to a crawl, only to discover the corporate proxy had failed overnight. And the self-installation capability acknowledges that developers should spend their time developing, not performing manual software distribution.

---

<p align="center">
  <em>May your connections remain stable, your proxies responsive, and your VPN transitions seamless!</em>
</p>
