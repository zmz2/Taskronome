# Taskronome final test report

本报告只记录本次 Windows 工作区中实际执行的结果。自动化结果来自 artifacts/ 产物；不能由当前环境执行的原生 Windows 手工项明确标记为 Not run，没有用 CI 或源码审阅替代人工观察。

## Environment

- Test date: 2026-09-03 (Asia/Shanghai, UTC+08:00)
- OS: Windows 11 专业版, build 10.0.26200
- Architecture/RID: x64 / win-x64
- .NET SDK: 10.0.400
- .NET runtime: 10.0.11 (Microsoft.WindowsDesktop.App)
- PowerShell: 7.6.4
- Repository: https://github.com/zmz2/Taskronome.git
- Validated implementation commit SHA: 668248a63f00f06cbca3000c22cae3f9a6b90d62

## Commands executed

The following commands were run from D:\VibeCodingTools\Taskronome with the local .NET 10.0.400 SDK selected through DOTNET_ROOT:

    pwsh -NoProfile -File .\scripts\bootstrap-and-verify.ps1 -Package -Version 1.0.0
    dotnet --info
    dotnet restore --locked-mode
    dotnet build -c Release --no-restore
    dotnet test -c Release --no-build --logger "trx;LogFileName=final-tests.trx"
    git diff --check
    python .\scripts\assistant-source-audit.py

The standalone command output is retained in [root-final-commands.log](../artifacts/root-final-commands.log). The complete unified gate output is retained by the verification artifacts and the terminal run that produced [verification-summary.json](../artifacts/verification-summary.json).

## Automated results

| Gate | Result | Actual evidence |
|---|---|---|
| Source audit | Passed | requiredFileCount=24, projectCount=4, four lock files, testAttributeCount=85, no source markers, no developer absolute paths; [source-audit.json](../artifacts/source-audit.json) |
| Locked restore | Passed | dotnet restore --locked-mode and the bootstrap gate both completed successfully |
| Format | Passed | dotnet format Taskronome.sln --verify-no-changes --no-restore --severity warn |
| Release build | Passed | dotnet build Taskronome.sln --configuration Release --no-restore; 0 warnings, 0 errors |
| Deterministic tests | Passed | 86 total, 86 executed, 86 passed, 0 failed, 0 skipped; [final-tests.trx](../artifacts/test-results/final-tests.trx) and the project-level root command TRX |
| Core line coverage | Passed | 95.51%, threshold 85%; coverage.cobertura.xml below artifacts/test-results/ |
| Core branch coverage | Passed | 78.78%, threshold 75%; coverage.cobertura.xml below artifacts/test-results/ |
| Real 2s/3s scenario | Passed | 9,862.6 ms wall elapsed, 5,681.6 ms recorded work, 6 segments, 20 events; [scenario-result.json](../artifacts/scenario/scenario-result.json) |
| Published UI smoke | Passed | Actual WPF self-contained EXE started and exited with code 0; smoke result passed; [summary.json](../artifacts/ui-smoke/summary.json) |
| Single-instance smoke | Passed | First process exit 0, second process exit 0, second launch signalled the first instance; [summary.json](../artifacts/ui-smoke/summary.json) |
| Portable ZIP E2E | Passed | ZIP was extracted to a fresh directory and the extracted self-contained EXE returned 0 with a passing smoke result; [portable-e2e-result.json](../artifacts/portable-e2e-3bf9e8c7b1d44dbd9e35ff6c4a3cf4b4/portable-e2e-result.json) |
| GitHub Actions Windows gate | Passed | PR run [33743333633](https://github.com/zmz2/Taskronome/actions/runs/33743333633) completed successfully and uploaded test evidence plus distributable packages |

The test attribute audit found 85 [Fact]/[Theory] attributes; xUnit executed 86 cases because one theory expands to multiple data cases. There were no skipped tests, so no release exception is required.

### Scenario observations

The real scenario used task A with a 2-second slice and task B with a 3-second slice. The recorded timeline shows:

- start entered AwaitingConfirmation for A with 0 ms recorded;
- waiting for confirmation left the recorded total unchanged at 0 ms;
- confirming A produced a 2,000 ms running segment;
- B entered confirmation after A expired;
- manual pause froze B at 2,143.6 ms remaining, and the following wait did not increase the recorded total;
- early completion removed B from future rotation without marking the time slice as naturally completed;
- confirmation timeout entered PausedAbsent, and the absence wait left the recorded total unchanged;
- resuming required a fresh confirmation for A;
- final completion persisted and reloaded with the same completed state, six segments and 20 events.

The deterministic suite covers the deadline boundary, monotonic timing, confirmation gates, manual/system/absence pauses, heartbeat gaps, restart recovery, idempotence, task validation, statistics/date boundaries, CSV escaping, atomic persistence, backup recovery, corruption isolation, I/O failures, and concurrent saves.

## Windows manual checklist

The required manual checklist is [MANUAL_TEST_CHECKLIST.md](MANUAL_TEST_CHECKLIST.md). The requested native UI session could not be executed in this Codex environment: the installed computer-use skill initialized, but both attempts to enumerate the Windows target returned the concrete service error Trusted RPC service is not configured: sky. No UI action was issued after that error, so the following items are honestly recorded as Not run rather than inferred from the automated smoke test.

| # | Manual check | Result | Evidence/reason |
|---:|---|---|---|
| 1 | Windows system notification appears | Not run | Native UI service unavailable; automated smoke used notification dry-run |
| 2 | Notification title is 轮到：任务名 | Not run | Native notification surface not observable |
| 3 | Notification body is correct | Not run | Native notification surface not observable |
| 4 | Clicking notification restores/focuses confirmation | Not run | Native UI service unavailable |
| 5 | Clicking notification does not auto-start | Not run | Native UI service unavailable; activation semantics are unit-tested |
| 6 | Notification permission disabled does not crash | Not run | OS permission UI was not automated |
| 7 | Notification failure fallback works | Not run | Native notification surface not observable |
| 8 | Default always-on-top | Not run | Visual/manual interaction unavailable |
| 9 | Toggle always-on-top | Not run | Visual/manual interaction unavailable |
| 10 | Always-on-top persists after restart | Not run | Visual/manual interaction unavailable |
| 11 | Closing window enters tray without stopping | Not run | Tray interaction unavailable |
| 12 | Tray double-click restores window | Not run | Tray interaction unavailable |
| 13 | Tray menu actions work | Not run | Tray interaction unavailable |
| 14 | Second instance does not create a second timer | Automated pass; manual not run | artifacts/ui-smoke/summary.json proves the two-process smoke path |
| 15 | Second instance wakes the first | Automated pass; manual not run | artifacts/ui-smoke/summary.json and SHOW signalling path |
| 16 | Ctrl+N, Ctrl+Shift+T, Enter and Space follow state | Not run | Native keyboard UI unavailable |
| 17 | Space in text input does not pause | Not run | Native keyboard UI unavailable |
| 18 | Lock screen pauses conservatively | Not run | Lock screen cannot be exercised through the available UI service |
| 19 | Unlock does not auto-resume | Not run | Lock screen cannot be exercised through the available UI service |
| 20 | Sleep/wake does not backfill | Not run | Power transition not exercised |
| 21 | Session disconnect does not keep accruing | Not run | Session transition not exercised |
| 22 | Forced exit/restart enters PausedSystem | Not run | Native restart interaction unavailable |
| 23 | Multi-monitor changes keep window visible | Not run | No multi-monitor UI session available |
| 24 | 125%/150%/200% scaling controls remain usable | Not run | Display scaling was not changed |
| 25 | Chinese/long names and notes preserve layout | Not run | Visual layout unavailable; installer path with Chinese and spaces was tested separately |
| 26 | Confirmation UI is prominent and keyboard focus is correct | Not run | Visual/accessibility observation unavailable |

The Windows application process itself was started from the self-contained publish output during the automated WPF smoke run, and the package/installer E2E runs below also started the installed/extracted executable. Those checks validate process startup and command-line smoke behavior, but they do not substitute for the visual, tray, notification, power-state, DPI, or multi-monitor observations above.

## Installer and data-safety E2E

The generated Inno installer was run silently into this fresh path containing spaces and Chinese characters:

    C:\Users\31774\AppData\Local\Temp\Taskronome E2E 空格 中文 7e66b70336b74c97a4f446a8cf6bab25

The installed self-contained executable ran with a passing smoke result and exit code 0. A sentinel file in an external data directory was present before uninstall and remained after uninstall. The uninstaller returned exit code 0; Inno first recorded a transient directory-delete retry, then removed the installation directory and logged Removed all? Yes. Evidence:

- [installer-result.json](../artifacts/installer-e2e-final/installer-result.json)
- [install.log](../artifacts/installer-e2e-final/install.log)
- [installed-smoke-result2.json](../artifacts/installer-e2e-final/installed-smoke-result2.json)
- [uninstall.log](../artifacts/installer-e2e-final/uninstall.log)

The package script also checked the ZIP entries and rejected source, test, artifact, user-data, and developer-absolute-path entries. The package is self-contained and uses the per-user Inno setup configuration in installer/Taskronome.iss.

## Packaging and checksums

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| Taskronome-1.0.0-win-x64-portable.zip | 132,110,139 | 909464b9468c5d6dc3f820ac4c334c5bbd6ee8193b0d8367c4e57b8519467835 |
| Taskronome-1.0.0-win-x64-setup.exe | 89,220,525 | bfc910381f38a843f204e1d7ff7a7db2288423efc246e8d75743d2dc56ee2417 |

The package manifest and [SHA256SUMS.txt](../artifacts/dist/SHA256SUMS.txt) were generated by scripts/package.ps1; the manifest records the same byte counts and hashes in [package-manifest.json](../artifacts/dist/package-manifest.json).

## Limitations and delivery state

1. Native Computer Use could not connect because the sky trusted RPC service was not configured. Consequently, the manual Windows checklist items that require visual UI, tray, notifications, power transitions, display changes, or keyboard interaction remain Not run.
2. The automated WPF smoke path, real monotonic-clock scenario, extracted portable executable, installed executable, and uninstaller all passed. These are process/runtime checks and are intentionally not reported as visual manual passes.
3. CI run: https://github.com/zmz2/Taskronome/actions/runs/33743333633. Pull Request: https://github.com/zmz2/Taskronome/pull/2. The implementation is not merged into main.
