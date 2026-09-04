namespace Taskronome.Core;

public sealed class RotationEngine : IRotationEngine
{
    private readonly object _gate = new();
    private readonly IMonotonicClock _clock;
    private readonly RotationOptions _options;
    private readonly List<TaskItem> _tasks = new();
    private readonly List<WorkSegment> _segments = new();
    private readonly List<RotationEvent> _events = new();

    private RotationState _state = RotationState.Idle;
    private RotationState? _stateBeforeSystemPause;
    private Guid? _currentTaskId;
    private TimeSpan _remaining;
    private long _lastTimestamp;
    private long? _confirmationStartedTimestamp;
    private DateTimeOffset? _currentRunStartedAtUtc;
    private TimeSpan _currentRunAccumulated;
    private SystemPauseReason? _systemPauseReason;
    private long _revision;

    public RotationEngine(IMonotonicClock clock, RotationOptions? options = null)
    {
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _options = options ?? new RotationOptions();
        _options.Validate();
        _lastTimestamp = _clock.GetTimestamp();
    }

    public void ReplaceTasks(IEnumerable<TaskItem> tasks)
    {
        ArgumentNullException.ThrowIfNull(tasks);
        lock (_gate)
        {
            if (_state is not (RotationState.Idle or RotationState.Completed))
            {
                throw new InvalidOperationException("Tasks cannot be replaced while a rotation is active.");
            }

            ReplaceTasksLocked(tasks);
            if (_state == RotationState.Completed && FindFirstActiveTaskLocked() is not null)
            {
                SetStateLocked(RotationState.Idle);
            }
        }
    }

    public void Load(
        IEnumerable<TaskItem> tasks,
        IEnumerable<WorkSegment>? segments,
        RotationCheckpoint? checkpoint,
        IEnumerable<RotationEvent>? events = null)
    {
        ArgumentNullException.ThrowIfNull(tasks);
        if (checkpoint is not null && checkpoint.SchemaVersion is not 1)
        {
            throw new InvalidDataException($"Unsupported rotation checkpoint schema version: {checkpoint.SchemaVersion}.");
        }

        lock (_gate)
        {
            ReplaceTasksLocked(tasks);
            _segments.Clear();
            if (segments is not null)
            {
                _segments.AddRange(segments);
            }

            _events.Clear();
            if (events is not null)
            {
                _events.AddRange(events);
            }

            ResetRuntimeLocked();
            var nowTimestamp = _clock.GetTimestamp();
            _lastTimestamp = nowTimestamp;

            if (checkpoint is null || checkpoint.State == RotationState.Idle)
            {
                SetStateLocked(RotationState.Idle);
                return;
            }

            if (checkpoint.State == RotationState.Completed)
            {
                SetStateLocked(FindFirstActiveTaskLocked() is null
                    ? RotationState.Completed
                    : RotationState.Idle);
                return;
            }

            var currentTask = FindTaskLocked(checkpoint.CurrentTaskId);
            if (currentTask is null || !IsActive(currentTask))
            {
                ClearCurrentLocked();
                SetStateLocked(FindFirstActiveTaskLocked() is null ? RotationState.Completed : RotationState.Idle);
                return;
            }

            ValidateCheckpointForTaskLocked(checkpoint, currentTask);
            _currentTaskId = currentTask.Id;
            _remaining = ClampRemaining(checkpoint.Remaining, currentTask.SliceDuration);

            if (checkpoint.CurrentRunAccumulated > TimeSpan.Zero)
            {
                var duration = checkpoint.CurrentRunAccumulated;
                var endedAt = _clock.GetUtcNow();
                var startedAt = checkpoint.CurrentRunStartedAtUtc ?? endedAt - duration;
                if (endedAt < startedAt)
                {
                    endedAt = startedAt + duration;
                }

                _segments.Add(new WorkSegment(
                    Guid.NewGuid(),
                    currentTask.Id,
                    currentTask.Name,
                    startedAt,
                    endedAt,
                    duration,
                    WorkEndReason.ApplicationInterrupted));
            }

            _currentRunAccumulated = TimeSpan.Zero;
            _currentRunStartedAtUtc = null;
            _confirmationStartedTimestamp = null;
            _systemPauseReason = checkpoint.SystemPauseReason;

            switch (checkpoint.State)
            {
                case RotationState.Running:
                case RotationState.AwaitingConfirmation:
                    _stateBeforeSystemPause = checkpoint.State;
                    _systemPauseReason = SystemPauseReason.ApplicationRestart;
                    SetStateLocked(RotationState.PausedSystem);
                    AddEventLocked(
                        RotationEventType.ApplicationRecovered,
                        "应用重新启动；离线时间未计入任务时长。",
                        currentTask.Id,
                        currentTask.Name);
                    break;
                case RotationState.PausedManual:
                    SetStateLocked(RotationState.PausedManual);
                    break;
                case RotationState.PausedAbsent:
                    SetStateLocked(RotationState.PausedAbsent);
                    break;
                case RotationState.PausedSystem:
                    _stateBeforeSystemPause = checkpoint.StateBeforeSystemPause ?? RotationState.Running;
                    _systemPauseReason ??= SystemPauseReason.ApplicationRestart;
                    SetStateLocked(RotationState.PausedSystem);
                    break;
                default:
                    throw new InvalidDataException($"Unsupported rotation checkpoint state: {checkpoint.State}.");
            }
        }
    }

    public bool StartRotation()
    {
        lock (_gate)
        {
            var now = _clock.GetTimestamp();
            PulseLocked(now);
            if (_state is not (RotationState.Idle or RotationState.Completed))
            {
                return false;
            }

            var first = FindFirstActiveTaskLocked();
            if (first is null)
            {
                ClearCurrentLocked();
                SetStateLocked(RotationState.Completed);
                AddEventLocked(RotationEventType.RotationCompleted, "没有可轮转的任务。", null, string.Empty);
                return false;
            }

            SetCurrentTaskLocked(first);
            AddEventLocked(RotationEventType.RotationStarted, "轮转已开始。", first.Id, first.Name);
            EnterAwaitingConfirmationLocked(now);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool ConfirmCurrentTask()
    {
        lock (_gate)
        {
            var now = _clock.GetTimestamp();
            PulseLocked(now);
            if (_state != RotationState.AwaitingConfirmation)
            {
                return false;
            }

            var task = FindTaskLocked(_currentTaskId);
            if (task is null || !IsActive(task))
            {
                return false;
            }

            StartRunningLocked(now);
            AddEventLocked(
                RotationEventType.TaskConfirmed,
                "用户在应用内确认开始任务。",
                task?.Id,
                task?.Name ?? string.Empty);
            return true;
        }
    }

    public bool PauseManual()
    {
        lock (_gate)
        {
            var now = _clock.GetTimestamp();
            var intendedTaskId = _currentTaskId;
            PulseLocked(now);
            if (_state != RotationState.Running || intendedTaskId != _currentTaskId)
            {
                return false;
            }

            var task = FindTaskLocked(_currentTaskId);
            EndActiveSegmentLocked(WorkEndReason.ManualPause);
            SetStateLocked(RotationState.PausedManual);
            AddEventLocked(
                RotationEventType.ManualPaused,
                "用户主动暂停。",
                task?.Id,
                task?.Name ?? string.Empty);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool ResumeManual()
    {
        lock (_gate)
        {
            var task = FindTaskLocked(_currentTaskId);
            if (_state != RotationState.PausedManual || task is null || !IsActive(task))
            {
                return false;
            }

            StartRunningLocked(_clock.GetTimestamp());
            AddEventLocked(RotationEventType.ManualResumed, "用户恢复任务。", task.Id, task.Name);
            return true;
        }
    }

    public bool ResumeAfterAbsence()
    {
        lock (_gate)
        {
            if (_state != RotationState.PausedAbsent || FindTaskLocked(_currentTaskId) is not { } task || !IsActive(task))
            {
                return false;
            }

            var now = _clock.GetTimestamp();
            EnterAwaitingConfirmationLocked(now);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool PauseForSystem(SystemPauseReason reason)
    {
        lock (_gate)
        {
            if (_state is RotationState.Idle or RotationState.Completed or RotationState.PausedSystem)
            {
                return false;
            }

            var now = _clock.GetTimestamp();
            PulseLocked(now);
            if (_state == RotationState.PausedSystem)
            {
                return true;
            }

            var previousState = _state;
            var task = FindTaskLocked(_currentTaskId);
            if (_state == RotationState.Running)
            {
                EndActiveSegmentLocked(WorkEndReason.SystemPause);
            }

            _stateBeforeSystemPause = previousState;
            _systemPauseReason = reason;
            _confirmationStartedTimestamp = null;
            SetStateLocked(RotationState.PausedSystem);
            AddEventLocked(
                RotationEventType.SystemPaused,
                $"系统暂停：{reason}。",
                task?.Id,
                task?.Name ?? string.Empty);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool ResumeAfterSystemPause()
    {
        lock (_gate)
        {
            var task = FindTaskLocked(_currentTaskId);
            if (_state != RotationState.PausedSystem || task is null || !IsActive(task))
            {
                return false;
            }

            var now = _clock.GetTimestamp();
            var previousState = _stateBeforeSystemPause;
            _systemPauseReason = null;
            _stateBeforeSystemPause = null;

            switch (previousState)
            {
                case RotationState.Running:
                    StartRunningLocked(now);
                    break;
                case RotationState.AwaitingConfirmation:
                case RotationState.PausedAbsent:
                    EnterAwaitingConfirmationLocked(now);
                    break;
                case RotationState.PausedManual:
                    SetStateLocked(RotationState.PausedManual);
                    break;
                default:
                    // Unknown recovery history is handled conservatively. A user
                    // action may recover the task, but it still must pass the
                    // normal in-app confirmation boundary before work starts.
                    EnterAwaitingConfirmationLocked(now);
                    break;
            }

            AddEventLocked(
                RotationEventType.SystemResumed,
                "用户确认在场并处理系统暂停。",
                task.Id,
                task.Name);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool SkipCurrentSlice()
    {
        lock (_gate)
        {
            var intendedTaskId = _currentTaskId;
            var intendedState = _state;
            if (!HasControllableCurrentTaskLocked())
            {
                return false;
            }

            var now = _clock.GetTimestamp();
            PulseLocked(now);
            if (intendedTaskId != _currentTaskId ||
                (intendedState == RotationState.Running && _state != RotationState.Running))
            {
                return false;
            }

            var task = FindTaskLocked(_currentTaskId);
            if (task is null)
            {
                return false;
            }

            if (_state == RotationState.Running)
            {
                EndActiveSegmentLocked(WorkEndReason.Skipped);
            }

            AddEventLocked(RotationEventType.SliceSkipped, "用户跳过本轮；任务仍保留。", task.Id, task.Name);
            MoveToNextTaskLocked(task.Id, now);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool CompleteCurrentTask()
    {
        lock (_gate)
        {
            var intendedTaskId = _currentTaskId;
            var intendedState = _state;
            if (!HasControllableCurrentTaskLocked())
            {
                return false;
            }

            var now = _clock.GetTimestamp();
            PulseLocked(now);
            if (intendedTaskId != _currentTaskId ||
                (intendedState == RotationState.Running && _state != RotationState.Running))
            {
                return false;
            }

            var current = FindTaskLocked(_currentTaskId);
            if (current is null)
            {
                return false;
            }

            if (_state == RotationState.Running)
            {
                EndActiveSegmentLocked(WorkEndReason.CompletedEarly);
            }

            current.Completed = true;
            current.UpdatedAtUtc = _clock.GetUtcNow();
            AddEventLocked(
                RotationEventType.TaskCompletedEarly,
                "用户将任务标记为已完成。",
                current.Id,
                current.Name);
            MoveToNextTaskLocked(current.Id, now);
            _lastTimestamp = now;
            return true;
        }
    }

    public bool StopRotation()
    {
        lock (_gate)
        {
            var now = _clock.GetTimestamp();
            PulseLocked(now);
            if (_state == RotationState.Idle)
            {
                return false;
            }

            var task = FindTaskLocked(_currentTaskId);
            if (_state == RotationState.Running)
            {
                EndActiveSegmentLocked(WorkEndReason.Stopped);
            }

            AddEventLocked(
                RotationEventType.RotationStopped,
                "用户停止轮转。",
                task?.Id,
                task?.Name ?? string.Empty);
            ClearCurrentLocked();
            _stateBeforeSystemPause = null;
            _systemPauseReason = null;
            SetStateLocked(RotationState.Idle);
            _lastTimestamp = now;
            return true;
        }
    }

    public void Pulse()
    {
        lock (_gate)
        {
            PulseLocked(_clock.GetTimestamp());
        }
    }

    public RotationStatus GetStatus()
    {
        lock (_gate)
        {
            return BuildStatusLocked(_clock.GetTimestamp());
        }
    }

    public IReadOnlyList<TaskItem> GetTasks()
    {
        lock (_gate)
        {
            return _tasks
                .OrderBy(task => task.Order)
                .ThenBy(task => task.CreatedAtUtc)
                .Select(task => task.Clone())
                .ToArray();
        }
    }

    public IReadOnlyList<WorkSegment> GetSegments()
    {
        lock (_gate)
        {
            return _segments.ToArray();
        }
    }

    public IReadOnlyList<RotationEvent> GetEvents()
    {
        lock (_gate)
        {
            return _events.ToArray();
        }
    }

    public RotationCheckpoint CreateCheckpoint()
    {
        lock (_gate)
        {
            return new RotationCheckpoint
            {
                State = _state,
                StateBeforeSystemPause = _stateBeforeSystemPause,
                CurrentTaskId = _currentTaskId,
                Remaining = _remaining,
                CurrentRunAccumulated = _currentRunAccumulated,
                CurrentRunStartedAtUtc = _currentRunStartedAtUtc,
                SystemPauseReason = _systemPauseReason,
                SavedAtUtc = _clock.GetUtcNow(),
            };
        }
    }

    private void PulseLocked(long now)
    {
        if (_state == RotationState.Running)
        {
            var elapsed = _clock.GetElapsedTime(_lastTimestamp, now);
            if (elapsed < TimeSpan.Zero || elapsed > _options.HeartbeatGapThreshold)
            {
                var task = FindTaskLocked(_currentTaskId);
                EndActiveSegmentLocked(WorkEndReason.SystemPause);
                _stateBeforeSystemPause = RotationState.Running;
                _systemPauseReason = SystemPauseReason.HeartbeatGap;
                SetStateLocked(RotationState.PausedSystem);
                AddEventLocked(
                    RotationEventType.SystemPaused,
                    "检测到不可信计时空档；空档未计时。",
                    task?.Id,
                    task?.Name ?? string.Empty);
                _lastTimestamp = now;
                return;
            }

            if (elapsed > TimeSpan.Zero)
            {
                var consumed = elapsed >= _remaining ? _remaining : elapsed;
                _currentRunAccumulated += consumed;
                _remaining -= consumed;
                IncrementRevisionLocked();

                if (_remaining <= TimeSpan.Zero)
                {
                    var completedTaskId = _currentTaskId;
                    var completedTask = FindTaskLocked(completedTaskId);
                    _remaining = TimeSpan.Zero;
                    EndActiveSegmentLocked(WorkEndReason.SliceExpired);
                    AddEventLocked(
                        RotationEventType.SliceExpired,
                        "时间片自然结束。",
                        completedTask?.Id,
                        completedTask?.Name ?? string.Empty);
                    MoveToNextTaskLocked(completedTaskId, now);
                }
            }
        }
        else if (_state == RotationState.AwaitingConfirmation && _confirmationStartedTimestamp.HasValue)
        {
            var elapsed = _clock.GetElapsedTime(_confirmationStartedTimestamp.Value, now);
            if (elapsed < TimeSpan.Zero)
            {
                var task = FindTaskLocked(_currentTaskId);
                _confirmationStartedTimestamp = null;
                _stateBeforeSystemPause = RotationState.AwaitingConfirmation;
                _systemPauseReason = SystemPauseReason.HeartbeatGap;
                SetStateLocked(RotationState.PausedSystem);
                AddEventLocked(
                    RotationEventType.SystemPaused,
                    "检测到单调时钟异常；确认窗口已安全暂停。",
                    task?.Id,
                    task?.Name ?? string.Empty);
            }
            else if (elapsed >= _options.ConfirmationTimeout)
            {
                var task = FindTaskLocked(_currentTaskId);
                _confirmationStartedTimestamp = null;
                SetStateLocked(RotationState.PausedAbsent);
                AddEventLocked(
                    RotationEventType.ConfirmationTimedOut,
                    "10 秒内未在应用内确认；轮转已暂停。",
                    task?.Id,
                    task?.Name ?? string.Empty);
            }
        }

        _lastTimestamp = now;
    }

    private void ReplaceTasksLocked(IEnumerable<TaskItem> tasks)
    {
        var clones = tasks
            .Select(task => task?.Clone() ?? throw new ArgumentException("Task list contains null.", nameof(tasks)))
            .ToList();
        var duplicate = clones.GroupBy(task => task.Id).FirstOrDefault(group => group.Count() > 1);
        if (duplicate is not null)
        {
            throw new ArgumentException($"Duplicate task id: {duplicate.Key}", nameof(tasks));
        }

        foreach (var task in clones)
        {
            var validation = TaskValidator.Validate(task.Name, task.Notes, task.SliceDuration);
            if (!validation.IsValid)
            {
                throw new ArgumentException(string.Join(" ", validation.Errors), nameof(tasks));
            }

            task.Name = task.Name.Trim();
        }

        _tasks.Clear();
        var ordered = clones.OrderBy(task => task.Order).ThenBy(task => task.CreatedAtUtc).ToList();
        for (var index = 0; index < ordered.Count; index++)
        {
            ordered[index].Order = index;
            _tasks.Add(ordered[index]);
        }
    }

    private void ResetRuntimeLocked()
    {
        _state = RotationState.Idle;
        _stateBeforeSystemPause = null;
        _currentTaskId = null;
        _remaining = TimeSpan.Zero;
        _confirmationStartedTimestamp = null;
        _currentRunStartedAtUtc = null;
        _currentRunAccumulated = TimeSpan.Zero;
        _systemPauseReason = null;
        IncrementRevisionLocked();
    }

    private RotationStatus BuildStatusLocked(long now)
    {
        var current = FindTaskLocked(_currentTaskId);
        var next = FindNextActiveTaskLocked(_currentTaskId);
        var confirmationRemaining = TimeSpan.Zero;

        if (_state == RotationState.AwaitingConfirmation && _confirmationStartedTimestamp.HasValue)
        {
            var elapsed = _clock.GetElapsedTime(_confirmationStartedTimestamp.Value, now);
            confirmationRemaining = elapsed >= _options.ConfirmationTimeout
                ? TimeSpan.Zero
                : _options.ConfirmationTimeout - elapsed;
        }

        var sliceDuration = current?.SliceDuration ?? TimeSpan.Zero;
        var progress = sliceDuration <= TimeSpan.Zero
            ? 0d
            : Math.Clamp((sliceDuration - _remaining).TotalMilliseconds / sliceDuration.TotalMilliseconds, 0d, 1d);

        var cycleDuration = GetOrderedTasksLocked()
            .Where(IsActive)
            .Aggregate(TimeSpan.Zero, (total, task) => total + task.SliceDuration);

        return new RotationStatus(
            _revision,
            _state,
            current?.Id,
            current?.Name ?? string.Empty,
            next?.Name ?? string.Empty,
            sliceDuration,
            _remaining,
            confirmationRemaining,
            progress,
            cycleDuration,
            _systemPauseReason,
            _state is RotationState.Idle or RotationState.Completed);
    }

    private void SetCurrentTaskLocked(TaskItem task)
    {
        _currentTaskId = task.Id;
        _remaining = task.SliceDuration;
        _currentRunAccumulated = TimeSpan.Zero;
        _currentRunStartedAtUtc = null;
        _confirmationStartedTimestamp = null;
        _stateBeforeSystemPause = null;
        _systemPauseReason = null;
        IncrementRevisionLocked();
    }

    private void EnterAwaitingConfirmationLocked(long now)
    {
        _currentRunAccumulated = TimeSpan.Zero;
        _currentRunStartedAtUtc = null;
        _confirmationStartedTimestamp = now;
        _stateBeforeSystemPause = null;
        _systemPauseReason = null;
        SetStateLocked(RotationState.AwaitingConfirmation);
        var task = FindTaskLocked(_currentTaskId);
        AddEventLocked(
            RotationEventType.TaskConfirmationRequested,
            "任务已轮到，等待应用内确认。",
            task?.Id,
            task?.Name ?? string.Empty);
    }

    private void StartRunningLocked(long now)
    {
        _confirmationStartedTimestamp = null;
        _currentRunStartedAtUtc = _clock.GetUtcNow();
        _currentRunAccumulated = TimeSpan.Zero;
        _systemPauseReason = null;
        _stateBeforeSystemPause = null;
        _lastTimestamp = now;
        SetStateLocked(RotationState.Running);
    }

    private void EndActiveSegmentLocked(WorkEndReason reason)
    {
        if (_currentRunAccumulated <= TimeSpan.Zero)
        {
            _currentRunStartedAtUtc = null;
            _currentRunAccumulated = TimeSpan.Zero;
            return;
        }

        var task = FindTaskLocked(_currentTaskId);
        if (task is null)
        {
            _currentRunStartedAtUtc = null;
            _currentRunAccumulated = TimeSpan.Zero;
            return;
        }

        var endedAt = _clock.GetUtcNow();
        var startedAt = _currentRunStartedAtUtc ?? endedAt - _currentRunAccumulated;
        if (endedAt < startedAt)
        {
            endedAt = startedAt + _currentRunAccumulated;
        }

        _segments.Add(new WorkSegment(
            Guid.NewGuid(),
            task.Id,
            task.Name,
            startedAt,
            endedAt,
            _currentRunAccumulated,
            reason));

        _currentRunStartedAtUtc = null;
        _currentRunAccumulated = TimeSpan.Zero;
        IncrementRevisionLocked();
    }

    private void MoveToNextTaskLocked(Guid? afterTaskId, long now)
    {
        var next = FindNextActiveTaskLocked(afterTaskId);
        if (next is null)
        {
            ClearCurrentLocked();
            SetStateLocked(RotationState.Completed);
            AddEventLocked(RotationEventType.RotationCompleted, "所有启用任务均已完成。", null, string.Empty);
            return;
        }

        SetCurrentTaskLocked(next);
        EnterAwaitingConfirmationLocked(now);
    }

    private TaskItem? FindFirstActiveTaskLocked() => GetOrderedTasksLocked().FirstOrDefault(IsActive);

    private TaskItem? FindNextActiveTaskLocked(Guid? afterTaskId)
    {
        var ordered = GetOrderedTasksLocked();
        if (ordered.Count == 0)
        {
            return null;
        }

        var startIndex = afterTaskId.HasValue
            ? ordered.FindIndex(task => task.Id == afterTaskId.Value)
            : -1;

        for (var offset = 1; offset <= ordered.Count; offset++)
        {
            var index = (startIndex + offset + ordered.Count) % ordered.Count;
            if (IsActive(ordered[index]))
            {
                return ordered[index];
            }
        }

        return null;
    }

    private List<TaskItem> GetOrderedTasksLocked() =>
        _tasks.OrderBy(task => task.Order).ThenBy(task => task.CreatedAtUtc).ToList();

    private TaskItem? FindTaskLocked(Guid? taskId) =>
        taskId.HasValue ? _tasks.FirstOrDefault(task => task.Id == taskId.Value) : null;

    private static bool IsActive(TaskItem task) => task.Enabled && !task.Completed;

    private bool HasControllableCurrentTaskLocked()
    {
        return _currentTaskId.HasValue &&
               _state is RotationState.AwaitingConfirmation
                   or RotationState.Running
                   or RotationState.PausedManual
                   or RotationState.PausedAbsent
                   or RotationState.PausedSystem;
    }

    private void ClearCurrentLocked()
    {
        _currentTaskId = null;
        _remaining = TimeSpan.Zero;
        _confirmationStartedTimestamp = null;
        _currentRunStartedAtUtc = null;
        _currentRunAccumulated = TimeSpan.Zero;
        IncrementRevisionLocked();
    }

    private void SetStateLocked(RotationState state)
    {
        if (_state != state)
        {
            _state = state;
            IncrementRevisionLocked();
        }
    }

    private void AddEventLocked(
        RotationEventType type,
        string detail,
        Guid? taskId,
        string taskName)
    {
        _events.Add(new RotationEvent(
            Guid.NewGuid(),
            _clock.GetUtcNow(),
            type,
            taskId,
            taskName,
            detail));
        IncrementRevisionLocked();
    }

    private void IncrementRevisionLocked() => _revision++;

    private static TimeSpan ClampRemaining(TimeSpan remaining, TimeSpan sliceDuration)
    {
        if (remaining <= TimeSpan.Zero)
        {
            return sliceDuration;
        }

        return remaining > sliceDuration ? sliceDuration : remaining;
    }

    private static void ValidateCheckpointForTaskLocked(RotationCheckpoint checkpoint, TaskItem task)
    {
        if (!CheckpointValidator.FitsTaskSlice(checkpoint, task))
        {
            throw new InvalidDataException("The rotation checkpoint is invalid for its current task.");
        }
    }
}
