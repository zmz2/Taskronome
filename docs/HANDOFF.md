# Implementation handoff

## Current implementation

The repository contains a complete first-pass implementation of Taskronome v1.0 on branch `chatgpt/implementation-v1`:

- cross-platform Core state machine using monotonic time;
- strict confirmation and interruption accounting;
- local atomic persistence, backup and corrupt-file isolation;
- WPF task planning, run, statistics and settings UI;
- Windows App SDK notifications with activation-only semantics;
- system tray, topmost, single instance and named-pipe activation;
- WTS/power interruption hooks;
- deterministic tests, real-time scenario and WPF smoke mode;
- Windows CI, portable packaging and per-user Inno Setup installer;
- user/developer/privacy/security documentation.

## Required final local pass

A Windows machine must run:

```powershell
git checkout chatgpt/implementation-v1
pwsh ./scripts/verify.ps1
pwsh ./scripts/package.ps1 -Version 1.0.0
```

Then execute every item in `docs/MANUAL-TEST-CHECKLIST.md`. Record the exact results rather than converting unperformed items into claims.

## Review priorities

1. Resolve any remaining compiler/API mismatch reported by the current Windows SDK/.NET SDK, preserving the state-machine invariants.
2. Verify unpackaged Windows App SDK notification registration and activation from the installed and portable builds.
3. Exercise lock/suspend/resume on real hardware and inspect persisted work segments.
4. Validate Inno Setup install/uninstall under a standard account.
5. Review the WPF layout at common DPI settings and improve accessibility without weakening the confirmation flow.
6. Generate and commit NuGet lock files after the dependency graph is stable, then switch CI restore to locked mode.
7. Update this file and the Pull Request with real test counts, coverage, artifact names and SHA-256 values.

Do not replace deterministic tests with sleeps, allow notification clicks to confirm tasks, or count any interval outside `Running`.
