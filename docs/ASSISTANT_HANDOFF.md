# Assistant handoff

This document describes the final implementation surface for the Windows handoff. The source remains the existing Taskronome implementation from the assistant branch, with the final branch adding validation, deterministic tests, Windows packaging, and delivery automation around it.

## Delivery surface

- `src/Taskronome.Core` is a WPF-free `net10.0` assembly containing the rotation state machine, monotonic-clock accounting, validation, CSV formatting, statistics, and atomic JSON persistence.
- `src/Taskronome.App` is a `net10.0-windows10.0.19041.0` WPF application with Windows App SDK notifications, taskbar/sound/tray fallback, single-instance activation, window placement, and power/session interruption handling.
- `tests/Taskronome.Core.Tests` contains deterministic fake-clock tests for the state machine and persistence boundaries.
- `tests/Taskronome.ScenarioRunner` is a real-time two-task acceptance scenario using 2-second and 3-second slices.
- `scripts/bootstrap-and-verify.ps1` is the single local gate. With `-Package` it also creates the portable ZIP, Inno Setup installer, manifest, and checksums.
- `.github/workflows/ci.yml` runs the same gate on Windows pull requests and development branches. `.github/workflows/release.yml` packages versioned tags.

## Non-negotiable invariants

Only `Running` can add to a work segment. Confirmation, manual pause, absence, system pause, idle, completed, lock, sleep, session disconnect, restart, and untrusted heartbeat gaps add no time. Every turn requires an in-app confirmation; a notification activation only brings the window forward. The Core engine uses a monotonic clock for elapsed time and treats wall-clock timestamps as metadata.

The app checkpoints the active state periodically and on exit. Restarting from `Running` or `AwaitingConfirmation` conservatively records an interruption and enters `PausedSystem`; time between the checkpoint and restart is never reconstructed.

## Required local commands

Run these from a Windows PowerShell 7 shell at the repository root:

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-and-verify.ps1 -Package
dotnet --info
dotnet restore --locked-mode
dotnet build -c Release --no-restore
dotnet test -c Release --no-build --logger "trx;LogFileName=final-tests.trx"
git diff --check
python .\scripts\assistant-source-audit.py
```

The command output and machine-specific results belong in `docs/TEST_REPORT.md`; never turn a not-run manual item into a claim.

## Packaging contract

The package directory is `artifacts/dist/` and contains:

- `Taskronome-<version>-win-x64-portable.zip`;
- `Taskronome-<version>-win-x64-setup.exe`;
- `SHA256SUMS.txt`;
- `package-manifest.json`.

The installer is per-user (`PrivilegesRequired=lowest`) and installs under `%LOCALAPPDATA%\Programs\Taskronome`. It does not remove `%LOCALAPPDATA%\Taskronome` during uninstall.

## Known environment-dependent checks

Real notification-center delivery, notification permission changes, lock/sleep/session disconnect, multi-monitor removal, installer UX, and SmartScreen presentation require an interactive Windows session. The canonical checklist records the exact Windows build, date, tester, evidence path, and Pass/Fail/Not run status for those checks.
