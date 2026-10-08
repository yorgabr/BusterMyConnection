# Contributing to BusterMyConnection

If you are reading this, you have likely met the peculiar fragility of corporate networking. A VPN
silently rewrote your proxy settings; a PAC file appeared from nowhere; or your own scripts worked
until the day they didn't. BusterMyConnection exists to absorb that brittleness on behalf of its
users. Contributions that strengthen its resilience, clarity, or adaptability are welcome.

This document ensures such contributions integrate cleanly with both the project's architecture and
its underlying philosophy.

***

## Getting Started in Fifteen Minutes

Begin by cloning the repository and confirming you are on **Windows PowerShell 5.1**, the supported
baseline. From the repository root, install the three modules the build depends upon into your user
scope — `InvokeBuild`, `Pester` (6.0 or newer; the project moved off the 5.x line, now in
maintenance mode), and `PSScriptAnalyzer`:

```powershell
Install-Module InvokeBuild, Pester, PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck
```

With those present, a single invocation of `Invoke-Build` runs the full quality gate: it validates
syntax via the AST parser, lints the source with PSScriptAnalyzer under 5.1 compatibility rules,
runs the Pester suite, and measures coverage against the project's **60%** floor.

Day to day you will rarely run the whole gate. While iterating, run only the tests with
`Invoke-Build Test`. Tests load the script through its `-DotSourceOnly` switch, which defines every
function and returns before the main flow executes. This is what makes functions individually
testable without downloading Px, spawning processes, or mutating your real environment.

A healthy loop: pick an issue, write a failing test expressing the desired behavior, implement the
change, run `Invoke-Build Test` until green, then run the full `Invoke-Build` once before pushing.
Bump the version in **both** the `.VERSION` field of the `PSScriptInfo` block and the
`$SCRIPT_VERSION` constant, following SemVer. Finish with a Conventional Commit message, push your
branch, and open a merge request referencing the issue.

***

## The `-DotSourceOnly` Guard

The script is simultaneously an executable and a library of functions. To reconcile these roles,
execution past the function definitions is gated behind the `-DotSourceOnly` switch: when present,
the script returns immediately after defining its functions, exposing them to the caller's session
without side effects. Production invocations never pass it. Any new function becomes testable
automatically, provided it is declared above this guard.

***

## Mockable Seams: Never Run Real Tools in the Suite

Native executables (`npm`, `pip`, `git`, `scoop`, `px`) **cannot be mocked reliably by Pester**, so
the architecture routes every external interaction through two PowerShell functions that *can* be
mocked:

- **`Invoke-BmcCli`** — the single seam for every external CLI call that cares only about the exit
  code (proxy/registry reconfiguration, connectivity probes). It merges and discards all native
  streams and returns `$LASTEXITCODE`.
- **`Get-BmcToolConfigValue`** — the seam for reads that need the captured **stdout** (e.g.
  `npm config get registry`, `pip config list`).

When you add a test, **mock these seams**, never the executables. The suite deliberately does not
stub `npm`/`pip`/`git`/`scoop`: stubbing them would mask a test that forgot to mock a seam and let
the real tool run against the developer's machine. `Get-NetAdapter` and `Get-DnsClient` *are*
stubbed in `BeforeAll` only so the suite runs on hosts (or CI agents) lacking those modules.

***

## Network HTTP Access

All direct HTTP work goes through `Test-BmcHttpAccess` (reachability HEAD probe) and
`Invoke-BmcNexusApi` (direct/NO_PROXY GET against the Nexus REST API). Both pin TLS 1.2 on the .NET
Framework stack behind PS 5.1. Mock them in tests rather than issuing real requests.

***

## Scenario Detection: The Primary Extension Point

The most valuable contributions expand network awareness. Detection lives in `Get-BmcScenario`,
driven entirely by configuration patterns (`detection.vpnAdapterPattern`,
`detection.officeDnsSuffixPattern`, `detection.pacProbe`) rather than hard-coded client logic. To
support a new environment, prefer extending these patterns or the detection ordering in
`Get-BmcScenario` over embedding monolithic conditionals, and add a focused test that mocks
`Get-NetAdapter`, `Get-DnsClient` and `Test-BmcPacEndpoint` as needed.

***

## State Persistence and Environmental Symmetry

`bmc` treats environment mutation as reversible. When proxy variables are removed
(`Enable-BmcDirectAccess`), their prior values are captured and persisted; when proxy mode is
restored (`Restore-BmcProxyEnvironment`), the same identifiers and scope are used. Contributions that
modify environment variables must respect this model. Any change that cannot be undone automatically
should be considered a design flaw and revisited.

***

## The `-JustCheck` Mode

Contributors must ensure new logic behaves correctly under `-JustCheck`
(`Invoke-BmcDiagnosticCheck`). In diagnostic mode, detection and reporting are allowed; mutation is
prohibited. A detector must be able to explain *what it sees* without attempting to *fix* it. This
separation is intentional: `-JustCheck` is the script's conscience — observant, thorough, passive.

***

## Expected Warnings and `ShouldProcess` Noise Are Assertions, Not Noise

When a function emits a warning along a particular path, that warning is part of its observable
contract. A test that exercises such a path must capture and assert on it rather than letting it leak
into the build log. In practice, redirect the warning stream into a variable and confirm both the
return value and the message; or, when the function uses the project's output helpers, mock `Out-Warn`
and assert with `Should -Invoke Out-Warn`.

The same discipline applies to the host-level `What if:` lines that `ShouldProcess` emits under
Windows PowerShell 5.1. These are **not** Information-stream records there, so a plain `6>$null` will
not catch them. When a `-WhatIf` test asserts only on invocation counts, fold every stream and
discard it: `Set-BmcToolProxy -ProxyUrl ... -WhatIf *>&1 | Out-Null`. The assertion stays meaningful
and the build log stays clean.

***

## Coding Standards

- **Compatibility**: Windows PowerShell 5.1 is the baseline. Avoid 7+ features unless strictly
  optional and guarded.
- **Encoding**: `.ps1` files are UTF-8 **with BOM** (`.editorconfig` enforces `utf-8-bom`); generated
  JSON/config artifacts are written UTF-8 **without** BOM.
- **Indentation**: 4 spaces, no tabs.
- **Naming**: functions use the `Verb-BmcNoun` convention with approved verbs; comment-based help on
  every public function.
- **Comments**: explain *why*, not *what*. Enrich non-obvious blocks with intent.

***

## Documentation Responsibility

Any contribution that changes behavior must update documentation accordingly:

- User-visible changes → `README.md`
- Architectural or extension patterns → `CONTRIBUTING.md`
- Non-obvious logic → source comments

Documentation is part of the contract, not a supplement.

***

## Final Notes

BusterMyConnection is designed to shoulder complexity, not expose it. Evaluate every change through a
simple lens:

> Does this make the tool more predictable when the network is unpredictable?

If the answer is yes, the contribution is likely aligned with the project's goals.

***
