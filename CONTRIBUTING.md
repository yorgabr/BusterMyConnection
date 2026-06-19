# Contributing to Buster‑MyConnection

If you are reading this document, you have likely encountered the peculiar fragility of corporate networking. Perhaps a VPN silently rewrote your proxy settings. Perhaps CNTLM appeared to be running, yet nothing could connect. Or perhaps you have already written your own scripts and discovered how quickly they become brittle.

Buster‑MyConnection exists to absorb that brittleness on behalf of its users. Contributions that strengthen its resilience, clarity, or adaptability are welcome and encouraged.

This document exists to ensure that such contributions integrate cleanly with both the script’s architecture and its underlying philosophy.

***

## Getting Started in Fifteen Minutes

If this is your first contribution, the path from cloning the repository to opening a merge request is deliberately short.

Begin by cloning the project and ensuring you are on Windows PowerShell 5.1, which is the supported baseline. From the repository root, install the three modules the build depends upon — `InvokeBuild`, `Pester` (5.0 or newer), and `PSScriptAnalyzer` — into your user scope. With those present, a single invocation of `Invoke-Build` runs the full quality gate: it lints the source, executes every test, and measures code coverage against the project's 60% floor.

Day-to-day, you will rarely run the whole gate. While iterating, run only the tests with `Invoke-Build Test`, or target a single file with `Invoke-Pester ./tests/Config.Tests.ps1`. Tests load the script through its `-DotSourceOnly` switch, which defines all functions and returns before the main flow executes. This is what makes the functions individually testable without downloading CNTLM, spawning processes, or mutating your real environment. When you write a new test, follow the same pattern: dot-source with `-DotSourceOnly`, then `Mock` any function that touches the network, the filesystem outside `$TestDrive`, or running processes.

A healthy contribution loop looks like this: pick an issue, write a failing test that expresses the desired behavior, implement the change in the script, run `Invoke-Build Test` until green, then run the full `Invoke-Build` once before pushing. Bump the version in both the comment-based help (`.NOTES`) and the `$SCRIPT_VERSION` constant following SemVer — patch for fixes, minor for backward-compatible features, major for breaking changes. Finish with a Conventional Commit message describing the change, push your branch, and open a merge request that references the issue.

***

## A Note on Testability and the `-DotSourceOnly` Guard

The script is simultaneously an executable and a library of functions. To reconcile these roles, execution past the function definitions is gated behind a `-DotSourceOnly` switch. When present, the script returns immediately after defining its functions, exposing them to the caller's session without side effects. Production invocations never pass this switch and therefore proceed into the main flow as usual. Any new function you add becomes testable automatically, provided it is declared above this guard.

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

## Expected Warnings Are Assertions, Not Noise

When a function emits a warning along a particular path, that warning is part of its observable contract. A test that exercises such a path must capture the warning and assert on it, rather than letting it surface in the build log.

A warning that leaks into the test output is a wasted assertion: the test clearly drove the code down a branch that was supposed to warn, yet it verified nothing about that outcome. Worse, leaked warnings accumulate as background noise that trains reviewers to ignore the very signal warnings exist to provide. The discipline is therefore symmetrical to the one we apply to errors — a failure path that returns `$false` is asserted with `Should -BeFalse`, and a path that warns is asserted against the warning it produces.

In practice, redirect the warning stream into a variable and confirm both the function's result and the message it raised. The merged stream carries the function's return value alongside `WarningRecord` objects, so filter for the record type before asserting on its content. The goal is twofold: the assertion proves the warning fired with the right message, and the build log stays clean because the warning was consumed instead of escaping.

This applies equally to warnings raised directly and to those emitted indirectly through the script's own output helpers, such as `Out-Warn`. If you add a code path that warns, add a test that captures it. If you encounter a leaked warning in the build output, treat it as a missing assertion and close the gap.

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
