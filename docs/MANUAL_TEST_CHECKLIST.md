# Windows manual acceptance checklist

This is the canonical interactive checklist. Record one row per check in the release report or an attached log. Do not mark a check Pass unless it was performed on the stated machine.

## Test record

- Tester:
- Date/time and timezone:
- Windows edition/build:
- Architecture:
- Display scale and monitor setup:
- Commit SHA:
- Portable ZIP SHA-256:
- Installer SHA-256:
- Evidence directory:

Use `Pass`, `Fail`, or `N/A` and include a screenshot or log path for every non-trivial check. Do not use `Not run` for a release-blocking check; use `N/A` only with concrete hardware, permission, or session evidence.

## A. Installation and launch

- [ ] Standard-user install completes without a UAC prompt.
- [ ] Start-menu shortcut opens one Taskronome window.
- [ ] Launching the executable again activates the existing window without a second timer or tray icon.
- [ ] Portable ZIP runs after extraction without installation or a preinstalled .NET runtime.
- [ ] Uninstall removes program files and shortcuts while preserving `%LOCALAPPDATA%\Taskronome`.
- [ ] Installer works when the install path contains spaces and Chinese characters.

## B. Task management

- [ ] Create three tasks with different hour/minute/second values; edit, delete, enable/disable, move up/down, and double-click edit work.
- [ ] Blank/81-character names, 501-character notes, zero/negative-like text, minute 60, and a 24-hour duration are rejected.
- [ ] A completed task can be reopened; resetting completion preserves historical work segments.
- [ ] While rotation is active, editing, deleting, and reordering controls are disabled.

## C. Strict round-robin flow

- [ ] Start always opens confirmation for the first task; statistics do not increase before confirmation.
- [ ] In-app confirmation within 10 seconds starts timing from the confirmation action.
- [ ] Natural expiry selects the next enabled unfinished task and requires new confirmation.
- [ ] A one-task rotation returns to a fresh confirmation for that same task after expiry.
- [ ] Skip records an audit event, moves on, and does not mark the task complete.
- [ ] Early completion records only actual worked time and excludes the task from later rounds.
- [ ] Rapid double-clicks on confirm, pause, skip, complete, and stop do not duplicate accounting or skip turns.

## D. Presence and notifications

- [ ] Let confirmation expire without clicking; the app enters absence pause and records no task time.
- [ ] Resume after absence starts a fresh full confirmation window for the same task.
- [ ] The Windows notification title is `轮到：任务名`, and its body identifies the 10-second in-app confirmation requirement.
- [ ] Clicking the notification restores/focuses Taskronome but does not confirm the task.
- [ ] With Windows notification permission disabled, in-app confirmation, taskbar flashing, sound, and tray fallback remain usable and the app does not crash.
- [ ] “Test system notification” reports notification failure clearly when delivery is unavailable.

## E. Pause and interruption accounting

- [ ] Manual pause freezes remaining time for at least 30 seconds; resume continues the same remainder.
- [ ] Lock Windows during a running task for at least 30 seconds; unlock leaves Taskronome safely paused and excludes locked time.
- [ ] Repeat the interruption check using sleep/wake.
- [ ] Repeat using remote-session disconnect/reconnect when available.
- [ ] Kill Taskronome during a running task, wait, and relaunch; it opens in system-pause recovery with no offline-time credit.
- [ ] Change Windows time forward and backward while running; remaining time and measured duration do not jump.
- [ ] Freeze/suspend the process beyond the heartbeat threshold; the untrusted gap is discarded and the app enters system pause.

## F. Window, tray, keyboard, and DPI

- [ ] The window is topmost on first launch; the setting and `Ctrl+Shift+T` persist after restart.
- [ ] Closing during rotation minimizes to tray without stopping or duplicating time.
- [ ] Tray double-click restores; tray display, pause/resume, topmost, and exit commands work.
- [ ] `Ctrl+N`, `Ctrl+Shift+T`, Enter, and Space work only in the appropriate state; Space in a text field does not pause.
- [ ] Move/maximize/close/reopen across monitors; after disconnecting a monitor the window returns to a visible work area.
- [ ] At 100%, 125%, 150%, and 200% scaling, controls, countdown, and dialogs remain usable.
- [ ] Keyboard-only navigation has visible focus; long Chinese names/notes and the minimum window size do not break layout.
- [ ] High-contrast mode remains legible for the core actions.

## G. Data and statistics

- [ ] Tasks, order, completion state, settings, and window placement survive restart.
- [ ] Today/7-day/30-day/all-time totals match the recorded work segments.
- [ ] CSV opens in Excel with readable Chinese, quoted fields, timestamps, and durations.
- [ ] Replacing `data.json` with invalid JSON preserves it as `data.corrupt-*.json`, starts safely, and reports recovery.
- [ ] After two saves, `data.json.bak` contains a recoverable prior snapshot.
- [ ] Normal operation creates no network/telemetry request; inspect the app behavior and local logs.
