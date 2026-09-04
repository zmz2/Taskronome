# Architecture

## 1. Design goals

Taskronome prioritizes correct duration accounting over animation precision. The UI can stall, the wall clock can change, and the process can be interrupted; none of those conditions may create unearned work time.

## 2. Project boundaries

### Taskronome.Core

The Core assembly targets plain `net10.0` and has no WPF or Windows dependency. It contains:

- `RotationEngine`: lock-protected deterministic state machine implementing `IRotationEngine`;
- `IMonotonicClock`: injectable monotonic duration source;
- task, checkpoint, work-segment and event models;
- task validation;
- `JsonFileDataStore`: atomic local persistence, backup recovery, concurrent-save serialization, and corruption isolation;
- `StatisticsCalculator` and `CsvFormatter`: local-date aggregation and Excel-compatible UTF-8 output without UI dependencies.

Core is directly unit-tested with a fake monotonic clock. This allows exact checks at the 10-second confirmation deadline and around sleep/lock gaps without waiting in real time.

### Taskronome.App

The App assembly targets `net10.0-windows10.0.19041.0` with WPF. It contains:

- WPF planning, running, statistics and settings views;
- `ResponsiveContentHost`, which constrains the measurement width of vertically scrollable pages when WPF supplies an infinite horizontal measure, then stretches the content back to the current viewport;
- `MainWindowViewModel`, which translates Core state into UI properties;
- a 250 ms display/pulse timer and a two-second durable checkpoint cadence;
- Windows App SDK app notifications;
- system tray and system-sound fallback;
- named mutex plus a one-command named pipe for single-instance activation;
- Win32/WTS handling for power and session changes;
- window placement clamping, taskbar flashing and foreground activation.

The UI timer is not a stopwatch. Every pulse asks Core to measure elapsed monotonic time. Only Core can mutate accounted duration.

## 3. State machine

```text
Idle / Completed
       |
       | Start
       v
AwaitingConfirmation --10 s timeout--> PausedAbsent
       |                                   |
       | in-app confirmation               | Resume rotation
       v                                   v
    Running <---------------------- AwaitingConfirmation
       |
       +-- manual pause ----------> PausedManual --resume--> Running
       +-- lock/suspend/gap ------> PausedSystem --user action--> prior safe state
       +-- slice expires ---------> next task / AwaitingConfirmation
       +-- skip ------------------> next task / AwaitingConfirmation
       +-- complete task ---------> next task or Completed
       +-- stop ------------------> Idle
```

`Running` is the only state that can increase `CurrentRunAccumulated` or reduce `Remaining`.

## 4. Timing rules

- `SystemMonotonicClock` delegates duration measurement to `TimeProvider.GetTimestamp()` and `GetElapsedTime()`.
- UTC wall time is stored only as explanatory metadata for work segments and events.
- Confirmation at or after the exact deadline is rejected by Core even if the UI still displays a stale fraction of a second.
- If a running heartbeat gap exceeds five seconds, the entire untrusted gap is discarded and the engine enters `PausedSystem`.
- On explicit system events, Core first accounts only the trusted elapsed interval since the previous pulse and then closes the active segment.
- On restart, already-checkpointed current work is finalized as `ApplicationInterrupted`; time between the checkpoint and restart is not added.

## 5. Persistence

`data.json` is written to a uniquely named temporary file with write-through and disk flush, then atomically replaced over the live file. Before replacement, the previous live file is copied to `data.json.bak`. A per-directory lock serializes concurrent saves. JSON/schema/validation failures are distinguished from I/O and permission failures; invalid main or backup files are preserved as `data.corrupt-*.json`, while a valid backup is restored to the main path.

Deserialization validates schema version, duplicate task IDs, task constraints, enum values, durations, timestamps, and checkpoint bounds. Invalid input is moved to `data.corrupt-<timestamp>.json`; the app starts with an empty safe data set only when both JSON candidates are invalid. Permission or transient I/O errors propagate to the UI instead of being misclassified as corruption.

## 6. Notifications and presence

Every transition into `AwaitingConfirmation` raises a view-model event. The window is restored and focused, the taskbar flashes, an optional system sound plays, and a Windows App SDK notification is sent. The notification activation callback only activates the window. It never calls `ConfirmCurrentTask()`.

If Windows notification registration or delivery fails, Taskronome retains the in-app countdown and uses the tray balloon/taskbar/sound path. Notification failure cannot terminate the rotation engine.

## 7. Windows interruption handling

`WindowsSessionMonitor` hooks the WPF HWND and registers for the current WTS session. It handles:

- `WM_POWERBROADCAST` / `PBT_APMSUSPEND`;
- `WM_POWERBROADCAST` / `PBT_APMRESUMEAUTOMATIC`;
- `WM_WTSSESSION_CHANGE` / lock, unlock and remote disconnect.

Suspend, lock and disconnect call `PauseForSystem`. Resume/unlock only informs the user; it does not restart accounting automatically.
