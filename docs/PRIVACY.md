# Taskronome privacy

Effective date: 2026-09-03

Taskronome is a local Windows desktop application. It does not require an account, connect to a Taskronome server, use advertising or analytics SDKs, send crash telemetry, or provide cloud synchronization.

## Local data

The app stores the following under `%LOCALAPPDATA%\Taskronome` by default:

- task names, notes, order, slice durations, enabled/completed flags;
- settings and window placement;
- confirmed `Running` work segments;
- rotation, confirmation, pause, skip, completion, and system-interruption events;
- a checkpoint used for conservative recovery;
- local diagnostic logs.

The logs are for local troubleshooting. They do not intentionally contain task notes, notification credentials, account data, or network tokens.

## Windows integrations

Taskronome may use Windows notifications, system sounds, taskbar flashing, the notification-area tray, and lock/sleep/session notifications. Notification content is shown only in the current Windows user's notification center. A notification activation only brings the app forward; it never confirms a task or uploads task data.

## Export, deletion, and uninstall

The settings view can open the data directory. The statistics view exports work segments to a user-selected UTF-8 CSV. Exit the app before manually deleting or backing up the data directory.

Uninstall does not delete `%LOCALAPPDATA%\Taskronome`; the user may remove that directory separately when the history is no longer needed.

The root [PRIVACY.md](../PRIVACY.md) is kept synchronized for packaged distributions.
