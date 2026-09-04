# Test plan

## Scope

The acceptance target is the existing Taskronome Windows desktop implementation. Tests protect the accounting invariants first, then exercise persistence, the real timer, and Windows presentation/integration.

## Automated deterministic tests

`Taskronome.Core.Tests` uses `FakeClock`; no unit test waits on wall time. The suite must report at least 50 test cases and zero failures or skips. Coverage is collected for `Taskronome.Core` with Coverlet and the verification gate requires at least 85% line coverage and 75% branch coverage.

The deterministic matrix includes:

| Area | Required assertions |
|---|---|
| Presence gate | first turn, before-deadline confirmation, exact/after-deadline rejection, timeout to absence, fresh confirmation after absence |
| Accounting | only `Running` accrues; awaiting, manual pause, absence, system pause, idle, completed, and heartbeat gaps do not |
| Rotation | natural expiry, one-task wrap, disabled/completed exclusion, skip, early completion, all-complete state, ordering |
| Idempotence | repeated confirm, pause/resume, skip, complete, stop, and system notifications do not double count or jump turns |
| Recovery | empty/invalid/overlong checkpoints, inactive current task, restart interruption, wall-clock forward/backward changes |
| Persistence | atomic replace, backup, corrupt main/backup isolation, I/O-versus-corruption handling, concurrent saves, schema and duplicate-ID validation |
| Output | CSV commas, quotes, newlines and Chinese; local-date statistics boundaries |

## Real short-duration scenario

`Taskronome.ScenarioRunner` uses the real `SystemMonotonicClock`, creates task A at 2 seconds and task B at 3 seconds, and asserts the complete sequence: confirmation before work, A natural expiry, B confirmation, manual pause/resume, B natural expiry, A reconfirmation, skip, early completion, persistence/reload, and bounded recorded duration. It also runs a separate confirmation-timeout/absence path.

The scenario writes `scenario-result.json` and `scenario-log.txt` when paths are supplied. Its duration measurement is evidence; it is not substituted for deterministic boundary tests.

## Windows smoke and manual acceptance

After a self-contained `win-x64` publish, `scripts/ui-smoke.ps1` launches the actual `Taskronome.exe` with an isolated data directory, loads WPF/XAML, exercises start → in-app confirm → pause → stop, and verifies a second launch exits through the single-instance path. The process writes a machine-readable result.

The smoke test does not certify that a person saw the window, notification center, tray icon, DPI layout, or power/session behavior. Those checks are recorded in [MANUAL_TEST_CHECKLIST.md](MANUAL_TEST_CHECKLIST.md) with evidence paths.

For the final release candidate, run `scripts/windows-interactive-acceptance.ps1` against the executable extracted from the same successful CI package artifact. It launches production mode with an isolated data directory, uses `System.Windows.Automation`/Win32 evidence, keeps the PowerShell process as an interruption watchdog, and writes the JSON/Markdown/screenshot/log/data-snapshot/SHA-256/ZIP evidence set. No `--test-mode` or `--notification-dry-run` argument is permitted.

## Packaging checks

`scripts/package.ps1` restores locked dependencies, publishes self-contained `win-x64`, excludes PDB files, creates the portable ZIP, invokes Inno Setup for the per-user installer, rejects development/user-data/PDB paths in the ZIP, and writes `SHA256SUMS.txt` plus `package-manifest.json`. For an official download, verify the file against the `SHA256SUMS.txt` uploaded by the same CI or Release workflow that produced it; local build hashes are not official release checksums.

## Reproduction

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-and-verify.ps1 -Package
```

The command is the release gate. If a check is unavailable on the current machine, the run must fail or the manual report must explicitly say `N/A` with concrete hardware, permission, or session evidence; a CI result cannot stand in for a manual Windows observation. Release-blocking checks must never be left as `Not run`.
