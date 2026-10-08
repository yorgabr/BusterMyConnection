# BusterMyConnection (bmc)

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows-informational.svg)
![License](https://img.shields.io/badge/License-GPL--3.0-green.svg)

## The Self-Healing Px Proxy Orchestrator for Windows

There comes a moment in every Windows developer's life when the corporate proxy stops being a
background nuisance and becomes an active impediment to productivity. Authentication may be valid,
the proxy may be correctly declared, and yet a single environmental change — a VPN reconnect, a PAC
file injected by a local agent, or an upstream outage — is enough to bring every tool to a halt.

**BusterMyConnection** confronts this fragility head-on. It is not a credential helper and it does
not depend on legacy tools such as CNTLM. Instead, it orchestrates [**Px Proxy**](https://github.com/genotrance/px),
a modern HTTP proxy with automatic Windows Single Sign-On (SSO), Kerberos, NTLM and PAC-file
evaluation. `bmc` detects your network context, provisions and starts Px when appropriate, and
reconciles the proxy configuration of every tool you use — then steps aside cleanly when the proxy
is unavailable.

The result is continuity: tools keep working, transitions feel intentional, and the command can be
run repeatedly and safely without accumulating side effects.

***

## The Architecture of Resilience

At its core, `bmc` follows a structured decision process on every run.

**First**, it reads the corporate PAC URL from the Windows Internet Settings registry key. The PAC
URL is the primary signal that you are inside a corporate environment.

**Second**, it classifies the active **scenario** — `Vpn`, `Office` or `Home` — using the patterns
in your configuration:

- `Vpn` when an active network adapter matches `detection.vpnAdapterPattern` (e.g. `F5|BIG-IP`).
- `Office` when a connection-specific DNS suffix matches `detection.officeDnsSuffixPattern`.
- `Office` when no pattern matched but the corporate PAC endpoint is reachable without a proxy
  (that server is only reachable from inside the network, so reaching it is strong evidence). This
  probe can be disabled with `detection.pacProbe = false`.
- `Home` otherwise.

**Third**, it evaluates viability. If a PAC exists and the scenario calls for proxying, `bmc`
performs an HTTP reachability check against the PAC endpoint before committing to proxy mode. If the
endpoint is unreachable, or no PAC is present, or the scenario requests `proxy = none`, `bmc`
chooses restraint and switches to **Direct Access**.

When proxy mode is viable, `bmc` provisions Px via Scoop if needed, starts it against the discovered
PAC (`px --pac=<url> --listen=127.0.0.1 --port=<port>`), exports the process-scoped proxy
variables, and reconfigures each tool to route through `http://127.0.0.1:<port>`.

***

## Scenario-Aware Tool Reconfiguration

POSIX environment variables alone are insufficient: every tool has its own proxy and index
mechanism. For the active scenario, `bmc` reconciles:

- **Scoop** — `scoop config proxy host:port` (scheme stripped), cleared in Direct Access.
- **Git** — `git config --global http.proxy <url>`; the non-existent `https.proxy` key is always
  removed so stale entries from older versions are cleaned up. Credentials are left to the current
  Windows user (Px handles SSO upstream).
- **npm** — `proxy` and `https-proxy`, cleared in Direct Access.
- **uv / pip** — the `HTTP(S)_PROXY` / `UV_INDEX_URL` / `PIP_INDEX_URL` process variables.

***

## Nexus Mirror Selection and First-Run Auto-Discovery

Each scenario carries a `nexus` boolean. When enabled, `bmc` points pip/uv and npm at your corporate
[Sonatype Nexus](https://www.sonatype.com/products/sonatype-nexus-repository) mirrors; when disabled
(or whenever Direct Access is in effect) it restores the public indexes. Direct Access always
implies public indexes, because the whitelisted corporate Nexus is unreachable off-network.

On the **first run**, when no configuration file exists yet and a corporate PAC is present, `bmc`
attempts to discover your Nexus automatically, in order:

1. **Inheritance** — reads your existing npm/pip/uv configuration and accepts only URLs carrying the
   Sonatype signature (`/repository/` or `/nexus/`); public registries and loopback are rejected.
2. **REST introspection** — when a base host is known but a format is missing, `bmc` queries
   `{base}/service/rest/v1/status` and `{base}/service/rest/v1/repositories` (direct / NO_PROXY) and
   selects per format by priority `group > proxy > hosted`.
3. **Interactive fallback** — only on an interactive host, it asks for the Nexus base URL and, if
   introspection fails, for the full PyPI and npm URLs.

The resulting `bmc.config.json` is materialised under `%LOCALAPPDATA%\bmc`. An existing config is
never overwritten.

***

## State Persistence and Recovery

`bmc` treats environment mutation as a reversible operation. When it enters Direct Access it captures
the proxy-related process variables before clearing them, and when it enters proxy mode it records
the active proxy. The snapshot is serialized (UTF-8, no BOM) to:

    %LOCALAPPDATA%\bmc\state.json

This gives symmetry: every automatic change is recorded so the tool knows what it did and how to
reason about the next run.

***

## Installation

`bmc` installs per-user, with **no administrator rights**, following Windows PowerShell 5.1
conventions. From the repository root:

```powershell
Invoke-Build Install
```

This stages `dist/`, verifies the SHA-256 of the deployed script, copies `bmc.ps1` and a `bmc.cmd`
launcher into your `CurrentUser` scripts folder (`<Documents>\WindowsPowerShell\Scripts`), refreshes
`bmc.config.sample.json` next to your real config, and adds the scripts folder to the user `PATH`.

If your execution policy is `Restricted` or `AllSigned`, run `bmc` through the `bmc.cmd` launcher, or
set `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (Group Policy may forbid it).

To remove it:

```powershell
Invoke-Build Uninstall
```

Uninstall intentionally leaves your PATH entry, config and state in place; delete them manually if
unwanted.

***

## Configuration

Copy `bmc.config.sample.json` to `%LOCALAPPDATA%\bmc\bmc.config.json` and set at least
`detection.officeDnsSuffixPattern` to your real corporate DNS suffix (the shipped template uses the
reserved `example.com`, which cannot match a real network). Run `bmc -JustCheck` to list the DNS
suffixes and adapters `bmc` currently sees, so you can write the detection patterns from real data.

***

## Usage

```powershell
bmc                      # Detect scenario, reconcile proxy/tools, start Px if viable
bmc -JustCheck           # Read-only diagnostics; never mutates state   (alias: -Check)
bmc -Port 3129           # Use a different local Px port                (alias: -p)
bmc -ConfigPath C:\x.json# Use an explicit config file                 (alias: -c)
bmc -SkipToolCheck       # Skip the post-configuration tool access check
bmc -Version             # Print the version and exit                  (alias: -v)
bmc -Help                # Print the full help and exit           (aliases: -h, -?)
```

### Diagnostic-Only Operation: `-JustCheck`

There are moments when insight is required but change is not. In diagnostic mode `bmc` reports the
detected scenario, active adapters and DNS suffixes, the PAC URL and its reachability, whether the Px
binary is present and running, and the last recorded state — then exits without modifying anything.
This makes `-JustCheck` suitable for automation pipelines and troubleshooting where understanding
must precede intervention.

***

## Exit Codes

| Code | Meaning                                                                            |
| ---: | ---------------------------------------------------------------------------------- |
|    0 | Success — proxy mode configured, or Direct Access intentionally activated          |
|    1 | Failure — a critical, unhandled error occurred during orchestration                |

***

## Philosophy

BusterMyConnection rejects the idea that network tooling must be brittle. Failure is inevitable;
deadlocks are not. When the proxy fails, the tool steps aside rather than lingering in a
half-functional state. When the network stabilizes, a subsequent run reconfigures everything again.
It is infrastructure that understands its purpose is to *disappear when working correctly* — and to
explain itself clearly when it does not.

***

🖖 _May your connections remain stable, your proxies responsive, and your VPN transitions seamless!_
