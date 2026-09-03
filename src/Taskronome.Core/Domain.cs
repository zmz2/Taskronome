using System.Collections.ObjectModel;

namespace Taskronome.Core;

public enum RotationState
{
    Idle,
    AwaitingConfirmation,
    Running,
    PausedManual,
    PausedAbsent,
    PausedSystem,
    Completed,
}

public enum WorkEndReason
{
    SliceExpired,
    ManualPause,
    Skipped,
    CompletedEarly,
    Stopped,
    SystemPause,
    ApplicationInterrupted,
}

public enum SystemPauseReason
{
    Lock,
    Suspend,
    SessionDisconnected,
    HeartbeatGap,
    ApplicationExit,
    ApplicationRestart,
    Unknown,
}

public enum RotationEventType
{
    RotationStarted,
    TaskConfirmationRequested,
    TaskConfirmed,
    ConfirmationTimedOut,
    ManualPaused,
    ManualResumed,
    SliceSkipped,
    TaskCompletedEarly,
    SliceExpired,
    SystemPaused,
    SystemResumed,
    RotationStopped,
    RotationCompleted,
    ApplicationRecovered,
}

public sealed class TaskItem
{
    public Guid Id { get; set; } = Guid.NewGuid();

    public string Name { get; set; } = string.Empty;

    public string Notes { get; set; } = string.Empty;

    public TimeSpan SliceDuration { get; set; } = TimeSpan.FromMinutes(25);

    public int Order { get; set; }

    public bool Enabled { get; set; } = true;

    public bool Completed { get; set; }

    public DateTimeOffset CreatedAtUtc { get; set; } = DateTimeOffset.UtcNow;

    public DateTimeOffset UpdatedAtUtc { get; set; } = DateTimeOffset.UtcNow;

    public TaskItem Clone()
    {
        return new TaskItem
        {
            Id = Id,
            Name = Name,
            Notes = Notes,
            SliceDuration = SliceDuration,
            Order = Order,
            Enabled = Enabled,
            Completed = Completed,
            CreatedAtUtc = CreatedAtUtc,
            UpdatedAtUtc = UpdatedAtUtc,
        };
    }
}

public sealed record WorkSegment(
    Guid Id,
    Guid TaskId,
    string TaskName,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset EndedAtUtc,
    TimeSpan Duration,
    WorkEndReason EndReason);

public sealed record RotationEvent(
    Guid Id,
    DateTimeOffset OccurredAtUtc,
    RotationEventType Type,
    Guid? TaskId,
    string TaskName,
    string Detail);

public sealed class RotationOptions
{
    public TimeSpan ConfirmationTimeout { get; init; } = TimeSpan.FromSeconds(10);

    public TimeSpan HeartbeatGapThreshold { get; init; } = TimeSpan.FromSeconds(5);

    public void Validate()
    {
        if (ConfirmationTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(ConfirmationTimeout));
        }

        if (HeartbeatGapThreshold <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(HeartbeatGapThreshold));
        }
    }
}

public sealed class RotationCheckpoint
{
    public int SchemaVersion { get; set; } = 1;

    public RotationState State { get; set; } = RotationState.Idle;

    public RotationState? StateBeforeSystemPause { get; set; }

    public Guid? CurrentTaskId { get; set; }

    public TimeSpan Remaining { get; set; }

    public TimeSpan CurrentRunAccumulated { get; set; }

    public DateTimeOffset? CurrentRunStartedAtUtc { get; set; }

    public SystemPauseReason? SystemPauseReason { get; set; }

    public DateTimeOffset SavedAtUtc { get; set; }
}

public sealed record RotationStatus(
    long Revision,
    RotationState State,
    Guid? CurrentTaskId,
    string CurrentTaskName,
    string NextTaskName,
    TimeSpan SliceDuration,
    TimeSpan Remaining,
    TimeSpan ConfirmationRemaining,
    double Progress,
    TimeSpan ActiveCycleDuration,
    SystemPauseReason? SystemPauseReason,
    bool CanEditTasks);

public interface IMonotonicClock
{
    long GetTimestamp();

    TimeSpan GetElapsedTime(long startTimestamp, long endTimestamp);

    DateTimeOffset GetUtcNow();
}

public sealed class SystemMonotonicClock : IMonotonicClock
{
    private readonly TimeProvider _timeProvider;

    public SystemMonotonicClock()
        : this(TimeProvider.System)
    {
    }

    public SystemMonotonicClock(TimeProvider timeProvider)
    {
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
    }

    public long GetTimestamp() => _timeProvider.GetTimestamp();

    public TimeSpan GetElapsedTime(long startTimestamp, long endTimestamp) =>
        _timeProvider.GetElapsedTime(startTimestamp, endTimestamp);

    public DateTimeOffset GetUtcNow() => _timeProvider.GetUtcNow();
}

public sealed record TaskValidationResult(bool IsValid, IReadOnlyList<string> Errors)
{
    public static TaskValidationResult Success { get; } = new(true, Array.Empty<string>());
}

public static class TaskValidator
{
    public static readonly TimeSpan MinimumDuration = TimeSpan.FromSeconds(1);
    public static readonly TimeSpan MaximumDuration = new(23, 59, 59);

    public static TaskValidationResult Validate(string? name, string? notes, TimeSpan duration)
    {
        var errors = new List<string>();
        var trimmedName = name?.Trim() ?? string.Empty;

        if (trimmedName.Length is < 1 or > 80)
        {
            errors.Add("任务名称去除首尾空格后必须为 1–80 个字符。");
        }

        if ((notes?.Length ?? 0) > 500)
        {
            errors.Add("任务备注不能超过 500 个字符。");
        }

        if (duration < MinimumDuration || duration > MaximumDuration)
        {
            errors.Add("时间片必须在 1 秒到 23:59:59 之间。");
        }

        return errors.Count == 0
            ? TaskValidationResult.Success
            : new TaskValidationResult(false, new ReadOnlyCollection<string>(errors));
    }
}
