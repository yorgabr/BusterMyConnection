# BusterMyConnection

docs/images/banner.webp  
CI
<https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg>
Platform
<https://img.shields.io/badge/License-GPL--3.0-green.svg>

## The Self‑Healing CNTLM Launcher for Windows

There comes a moment in every Windows developer’s life when corporate proxy servers cease to be a background nuisance and become an active impediment to productivity. CNTLM may be correctly configured, authentication may be valid, and yet a single environmental change — a VPN reconnect, a PAC file injected by a local agent, or an upstream proxy outage — is enough to bring every tool to a grinding halt.

**Buster‑MyConnection** exists to confront this fragility head‑on.

This script is not merely a CNTLM launcher. It is an orchestration layer that understands that real corporate networks are unstable systems. Proxies fail. VPNs override configuration. Environment variables linger longer than they should. And developers are often left debugging symptoms instead of causes.

Buster‑MyConnection adopts a different philosophy: *graceful degradation* backed by memory. When the proxy is healthy, it enables CNTLM and ensures the environment is correctly configured. When the proxy is dead, it decisively steps aside — removing proxy environment variables, enabling direct internet access, and preserving enough state to recover later without user intervention.

The result is not cleverness for its own sake, but continuity. Tools continue to work. Transitions feel intentional rather than accidental. And the script can be run repeatedly, safely, without fear of accumulating side effects.

***

## The Architecture of Resilience

At its core, Buster‑MyConnection follows a structured decision process.

**First**, it verifies infrastructure. If CNTLM is not present at the configured path, the script installs it via [Scoop](https://scoop.sh) (`scoop install cntlm`), which requires no administrative privileges, resolves the package over HTTPS, and verifies it against Scoop's manifest hash. Scoop itself must already be installed and on `PATH`; the script does not bootstrap Scoop for you.

**Second**, it resolves configuration. An existing `cntlm.ini` is located via explicit path or discovery. If none exists, the script launches an interactive wizard that validates input, explains security trade‑offs, and produces a usable, well‑commented configuration file with sensible defaults.

**Third**, it evaluates viability. Before starting CNTLM, the script performs a TCP health check against the upstream proxy declared in the configuration. This check is deliberate: the goal is not to confirm general network availability, but to validate that the specific proxy endpoint CNTLM depends upon is actually responsive.

If the upstream proxy is unreachable, Buster‑MyConnection chooses restraint. CNTLM is *not* started. Instead, all proxy‑related environment variables are removed from the current process scope, enabling direct internet access and preventing application‑level deadlocks. The removal is not destructive: the original values are captured and persisted for later restoration.

When connectivity returns — whether through VPN reconnection or proxy recovery — a subsequent execution detects the prior Direct Access state and restores the saved variables automatically.

***

## VPN Detection as a Chain of Responsibility

Corporate VPNs frequently alter proxy behavior in subtle, vendor‑specific ways. Buster‑MyConnection addresses this variability through a **chain‑based detection system** implemented using plain PowerShell functions.

Each detector in the chain attempts to recognize a specific VPN client (such as BIG‑IP Edge Client or Cisco AnyConnect) using reliable environmental indicators — registry values, local PAC servers, or running processes. When a detector succeeds, it returns a structured result that includes both identification and a reconciliation action.

That action is a script block, executed only when standard operation is intended, which updates `cntlm.ini` to reflect the effective system proxy configuration introduced by the VPN. If a detector fails, responsibility passes transparently to the next detector in the chain.

This design is intentionally extensible: adding support for a new VPN does not require modifying existing detectors. You simply insert a new function into the chain.

***

## Credentials and Proxy URLs

NTLM authentication is domain-aware: CNTLM and the corporate proxy expect an identity of the form `DOMAIN\user`. An HTTP proxy URL, however, is not. When Buster-MyConnection exports `HTTP_PROXY` for corporate mode, it deliberately strips the domain component and URL-encodes the remaining `user:password`, producing `http://user:password@proxy:port`. This matters because a backslash in the userinfo segment leads Git and libcurl to interpret the URL as containing a path — a construct only SOCKS proxies accept — which previously caused `fatal: ... only SOCKS proxies support paths`. The domain still participates in authentication through the credential object passed to the underlying request; it simply never appears in the URL.

***

## State Persistence and Recovery

One of the script’s most consequential behaviors occurs during failure.

When Buster‑MyConnection determines that proxy mode is unsafe, it transitions explicitly into **Direct Access mode**. Before removing any proxy environment variables, it captures a snapshot of all proxy‑related entries present in the current process. That snapshot is serialized and stored under:

    %LOCALAPPDATA%\Buster-MyConnection\state.json

On subsequent runs, the script consults this state file. If the previous execution was in Direct Access mode and proxy operation is again viable, the original environment variables are restored before CNTLM is started.

This mechanism ensures symmetry: every automatic removal has a corresponding, automatic restoration. The script remembers not only *what* it did, but *how to undo it*.

***

## Diagnostic‑Only Operation: `-JustCheck`

There are moments when insight is required but change is not desired. For these cases, Buster‑MyConnection provides a comprehensive diagnostic mode via the `-JustCheck` switch.

In this mode, the script performs:

*   Process discovery for CNTLM on the target listening port
*   Configuration discovery and parsing of the active `cntlm.ini`
*   Validation of required directives and authentication posture
*   HTTP and HTTPS connectivity checks via `curl`, with timeouts and retries

No remediation actions are taken. No configuration is altered. The script reports what it finds, then exits.

This makes `-JustCheck` suitable for automation pipelines, pre‑deployment health checks, and troubleshooting scenarios where understanding must precede intervention.

***

## Exit Codes

The script communicates its outcome through process exit codes, suitable for use in automation and CI pipelines.

| Code | Meaning                                                               |
| ---: | --------------------------------------------------------------------- |
|    0 | Success — CNTLM started, or Direct Access mode intentionally activated |
|    1 | Failure — no viable strategy, failed validation, or a forced mode could not be satisfied |

Earlier releases reserved codes 2 and 3 for wizard and installation failures; these now surface as code 1 with a descriptive error message, keeping the contract simple for callers.

***

## Philosophy

Buster‑MyConnection rejects the idea that network tooling must be brittle. Failure is inevitable; deadlocks are not.

When the proxy fails, the script does not linger in a half‑functional state. When a VPN overrides configuration, it reconciles rather than resists. When the environment stabilizes, it restores what it removed without requiring the user to remember what changed.

It is infrastructure that understands its purpose is to *disappear when working correctly* — and to explain itself clearly when it does not.

***

🖖 _May your connections remain stable, your proxies responsive, and your VPN transitions seamless!_