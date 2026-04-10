# Contributing to Buster‑MyConnection

If you are reading this document, you have likely encountered the peculiar fragility of corporate networking. Perhaps a VPN silently rewrote your proxy settings. Perhaps CNTLM appeared to be running, yet nothing could connect. Or perhaps you have already written your own scripts and discovered how quickly they become brittle.

Buster‑MyConnection exists to absorb that brittleness on behalf of its users. Contributions that strengthen its resilience, clarity, or adaptability are welcome and encouraged.

This document exists to ensure that such contributions integrate cleanly with both the script’s architecture and its underlying philosophy.

***

## VPN Detection: The Primary Extension Point

The most common and most valuable contributions to this project involve expanding VPN awareness.

Rather than hard‑coding VPN logic directly into the execution flow, Buster‑MyConnection implements VPN detection as a **chain of responsibility composed of functions**. Each function in the chain attempts to detect a specific VPN client. If it succeeds, it returns a structured result describing the VPN and providing a reconciliation action. If it fails, execution passes to the next detector.

This approach avoids monolithic conditional logic and keeps each detector self‑contained and testable.

***

## The Detection Contract

Each VPN detector function must return either `$null` or a **VpnDetectionResult** object produced by `New‑VpnDetectionResult`.

That object contains:

*   `IsVpnActive` — `$true` if the VPN is detected
*   `VpnType` — human‑readable name for logging
*   `Description` — diagnostic context
*   `ReconcileAction` — a script block executed only during normal operation

The reconciliation action must be safe, idempotent, and side‑effect‑free when invoked repeatedly.

***

## Building and Extending the Detection Chain

The detection chain is constructed by `Invoke‑VpnDetectionChain`, which evaluates detectors in order.

To add a new VPN detector:

1.  Write a function `Test‑YourVpnName` that performs detection and returns a `VpnDetectionResult` or `$null`.
2.  Insert that function into the detector list inside `Invoke‑VpnDetectionChain`.
3.  Document your detection logic and assumptions in this file.

No existing detectors should require modification.

***

## State Persistence and Environmental Symmetry

Buster‑MyConnection treats environment mutation as a reversible operation.

When proxy variables are removed, their prior values are captured and persisted. When those variables are later restored, restoration occurs using the same identifiers and scope, ensuring symmetry across executions.

Contributions that modify environment variables must respect this model. Any change that cannot be undone automatically should be considered a design flaw and revisited.

***

## The `-JustCheck` Mode

Contributors must ensure that new detection logic behaves correctly under `-JustCheck`.

In diagnostic mode:

*   Detection is allowed
*   Reporting is encouraged
*   Reconciliation is prohibited

A detector must be able to explain *what it sees* without attempting to *fix* it.

This separation is intentional. `-JustCheck` is the script’s conscience: observant, thorough, and passive.

***

## Coding Standards

*   **PowerShell compatibility**: Windows PowerShell 5.1 is the baseline
*   **Indentation**: 4 spaces, no tabs
*   **Casing**: Functions and variables use camelCase; types use PascalCase
*   **Comments**: Explain *why*, not *what*

Avoid PowerShell features unavailable in 5.1 unless they are strictly optional and guarded by compatibility checks.

***

## Documentation Responsibility

Any contribution that changes behavior must update documentation accordingly.

*   User‑visible changes → `README.md`
*   Architectural or extension patterns → `CONTRIBUTING.md`
*   Non‑obvious logic → source comments

Documentation is not supplementary; it is part of the contract.

***

## Final Notes

Buster‑MyConnection is designed to shoulder complexity, not expose it. Every change should be evaluated through a simple lens:

> Does this make the tool more predictable when the network is unpredictable?

If the answer is yes, the contribution is likely aligned with the project’s goals.

***
