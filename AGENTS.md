# Taskronome agent instructions

## Mission

Implement and maintain the complete Windows desktop application described in GitHub Issue #1. Treat that issue as the authoritative product and acceptance specification.

## Non-negotiable behavior

- Only the `Running` rotation state may add to actual task time.
- Every task turn, including the first, requires an in-app confirmation before its slice starts.
- The production confirmation deadline is 10 seconds. A Windows notification click may activate the app but must never count as confirmation.
- Confirmation timeout, manual pause, lock, suspend, session disconnect, process interruption, restart, and an untrusted heartbeat gap must not add task time.
- Use monotonic time for durations; wall-clock time is only for display and event timestamps.
- Keep the domain/rotation engine independent of WPF and Windows APIs so it can be tested deterministically.
- Do not add telemetry, cloud services, administrator requirements, unknown assets, or copyleft runtime dependencies.

## Required stack and quality

- C#, WPF, .NET 10 LTS, stable Windows App SDK app notifications, win-x64 self-contained deployment.
- MVVM-style separation; nullable enabled; deterministic builds; warnings treated as errors; locked dependencies.
- Use original geometric artwork, system fonts, and system sounds only.
- No unfinished TODOs, placeholders, empty controls, production mocks, `NotImplementedException`, disabled assertions, or silently skipped acceptance tests.

## Validation

Create and keep these commands working:

- `pwsh -NoProfile -File ./scripts/bootstrap-and-verify.ps1 -Package` — source audit, locked restore, format check, Release build, all tests, coverage gates, real short-duration scenario, publish, Windows UI/single-instance smoke, portable win-x64 ZIP, per-user Inno Setup installer, and SHA-256 checksums.
- `pwsh -NoProfile -File ./scripts/verify.ps1` — run the same validation gates without packaging.
- `pwsh -NoProfile -File ./scripts/package.ps1 -Version 1.0.0` — produce the portable win-x64 ZIP, per-user Inno Setup installer, and SHA-256 checksums after validation.

GitHub Actions on `windows-latest` must run the same gates and upload logs, test results, coverage, the portable package, and the installer. Fix failures and rerun until CI is green. Never claim a visual/manual Windows check unless it was actually performed.

## Documentation and delivery

Keep README, architecture, privacy, test plan, real test report, manual test checklist, third-party notices, security policy, and contributing guide synchronized with the implementation. Finish through a pull request to `main`; the PR must contain real commands/results, test counts, coverage, artifact names and hashes, limitations, and a final self-review.
