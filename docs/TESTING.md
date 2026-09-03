# Testing strategy

## Automated layers

### Deterministic Core tests

`Taskronome.Core.Tests` injects `FakeClock`, whose monotonic timestamp and wall time can move independently. Tests cover:

- first-turn confirmation and exact 10-second boundary;
- no work during confirmation or absence;
- monotonic accrual and wall-clock rollback;
- natural expiry and round-robin selection;
- one-task repeated confirmation;
- manual pause/resume and explicit system pause;
- heartbeat-gap discard;
- restart recovery without offline time;
- skip, early completion, stop and idempotent commands;
- command/expiry race boundaries;
- event audit trail;
- task validation, order normalization and duplicate IDs;
- atomic JSON round trip, backup, invalid schema/task and corrupt-file preservation.

### Real short-duration scenario

`Taskronome.ScenarioRunner` uses the real `SystemMonotonicClock` with two one-second tasks. It walks through confirmation, natural expiry, manual pause, a wait while paused, resume and the next natural expiry. It asserts the selected tasks, work-segment count and total recorded time.

### Windows UI startup smoke

The published `Taskronome.exe --smoke-test` creates a temporary isolated data directory, loads WPF/XAML, creates a one-second task and executes start → confirm → pause → stop through the view model. It exits nonzero on startup, binding/state or transition failures and has a 30-second outer timeout.

The smoke test does not claim that a human saw the notification or assessed visual quality.

## One-command gate

```powershell
pwsh ./scripts/verify.ps1
```

The gate requires:

- restore and formatting check;
- warning-free Release build;
- no failed or skipped tests;
- at least 85% line coverage for `Taskronome.Core`;
- passing real short-duration scenario;
- no unfinished markers in production/test/build files;
- successful self-contained win-x64 publish;
- passing WPF startup smoke test.

## Packaging gate

```powershell
pwsh ./scripts/package.ps1 -Version 1.0.0
```

This creates a portable ZIP, a per-user Inno Setup installer, `SHA256SUMS.txt` and `package-manifest.json`.

## What still requires a human Windows session

The following cannot be truthfully certified by a headless unit test alone and must be executed using `MANUAL-TEST-CHECKLIST.md` before a public release:

- visual layout at multiple DPI values and monitors;
- Windows notification-center appearance and click activation;
- real lock, sleep, wake and remote-session behavior;
- tray interactions and foreground restrictions under the user’s Windows settings;
- installer/uninstaller UX and SmartScreen presentation.
