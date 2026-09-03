# Final handoff

Taskronome is delivered as an existing Windows WPF implementation completed on the final handoff branch. The state machine and UI were preserved; the final work adds the missing Windows build/release gates, deterministic edge-case coverage, real short-duration scenario, persistence hardening, and delivery documentation.

## Local gate

From a Windows PowerShell 7 shell at the repository root:

```powershell
pwsh -NoProfile -File .\scripts\bootstrap-and-verify.ps1 -Package
```

This invokes the Python source audit, locked NuGet restore, format check, Release build, deterministic tests and coverage, the real 2-second/3-second scenario, self-contained publish, WPF/single-instance smoke, portable ZIP, and Inno Setup installer. The final facts belong in [TEST_REPORT.md](TEST_REPORT.md).

## Review priorities

1. Confirm the final `docs/TEST_REPORT.md` values against `artifacts/verification-summary.json`, TRX/Cobertura output, scenario evidence, and package checksums.
2. Execute [MANUAL_TEST_CHECKLIST.md](MANUAL_TEST_CHECKLIST.md) on the target Windows session, especially notification permission/activation, tray, lock/sleep/session changes, DPI, multi-monitor behavior, and installer/uninstaller UX.
3. Review the pull request's Windows CI run and downloaded artifacts before release.

## Safety invariants

Only `Running` adds actual work time. Each turn requires an in-app confirmation. Notification activation only restores/focuses the app. Monotonic time is the duration source; wall time is metadata. Confirmation timeout, manual/system pause, lock, sleep, session disconnect, restart, and an untrusted heartbeat gap never add time.

## Package contract

`artifacts/dist/` contains a self-contained `Taskronome-<version>-win-x64-portable.zip`, a per-user `Taskronome-<version>-win-x64-setup.exe`, `SHA256SUMS.txt`, and `package-manifest.json`. The installer uses `PrivilegesRequired=lowest` and preserves `%LOCALAPPDATA%\Taskronome` on uninstall.
