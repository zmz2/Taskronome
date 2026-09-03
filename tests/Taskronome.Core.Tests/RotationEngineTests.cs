using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class RotationEngineTests
{
    [Fact]
    public void StartRotation_RequiresConfirmationAndDoesNotCountWaitingTime()
    {
        var (clock, engine, tasks) = CreateEngine();

        Assert.True(engine.StartRotation());
        clock.Advance(TimeSpan.FromSeconds(4));
        engine.Pulse();

        var status = engine.GetStatus();
        Assert.Equal(RotationState.AwaitingConfirmation, status.State);
        Assert.Equal(tasks[0].Id, status.CurrentTaskId);
        Assert.Equal(tasks[0].SliceDuration, status.Remaining);
        Assert.Empty(engine.GetSegments());
    }

    [Fact]
    public void ConfirmBeforeDeadline_StartsRunning()
    {
        var (clock, engine, _) = CreateEngine();
        engine.StartRotation();
        clock.Advance(TimeSpan.FromSeconds(9.999));

        Assert.True(engine.ConfirmCurrentTask());
        Assert.Equal(RotationState.Running, engine.GetStatus().State);
    }

    [Fact]
    public void ConfirmAtDeadline_IsRejectedAndMarksAbsent()
    {
        var (clock, engine, _) = CreateEngine();
        engine.StartRotation();
        clock.Advance(TimeSpan.FromSeconds(10));

        Assert.False(engine.ConfirmCurrentTask());
        Assert.Equal(RotationState.PausedAbsent, engine.GetStatus().State);
        Assert.Empty(engine.GetSegments());
    }

    [Fact]
    public void AbsenceResume_StartsFreshConfirmationWindow()
    {
        var (clock, engine, _) = CreateEngine();
        engine.StartRotation();
        clock.Advance(TimeSpan.FromSeconds(11));
        engine.Pulse();

        Assert.True(engine.ResumeAfterAbsence());
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);

        clock.Advance(TimeSpan.FromSeconds(9));
        Assert.True(engine.ConfirmCurrentTask());
    }

    [Fact]
    public void Running_AccruesOnlyMonotonicElapsedTime()
    {
        var (clock, engine, tasks) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();

        clock.Advance(TimeSpan.FromSeconds(3));
        engine.Pulse();

        Assert.Equal(tasks[0].SliceDuration - TimeSpan.FromSeconds(3), engine.GetStatus().Remaining);
        Assert.Empty(engine.GetSegments());
    }

    [Fact]
    public void NaturalExpiry_CountsOnlyRemainingAndMovesToNextConfirmation()
    {
        var tasks = new[]
        {
            NewTask("A", TimeSpan.FromSeconds(3), 0),
            NewTask("B", TimeSpan.FromSeconds(4), 1),
        };
        var (clock, engine) = CreateEngine(tasks, heartbeatGap: TimeSpan.FromSeconds(20));
        engine.StartRotation();
        engine.ConfirmCurrentTask();

        clock.Advance(TimeSpan.FromSeconds(5));
        engine.Pulse();

        var status = engine.GetStatus();
        var segment = Assert.Single(engine.GetSegments());
        Assert.Equal(TimeSpan.FromSeconds(3), segment.Duration);
        Assert.Equal(WorkEndReason.SliceExpired, segment.EndReason);
        Assert.Equal(RotationState.AwaitingConfirmation, status.State);
        Assert.Equal(tasks[1].Id, status.CurrentTaskId);
        Assert.Equal(tasks[1].SliceDuration, status.Remaining);
    }

    [Fact]
    public void ManualPause_FreezesTimeAndResumeContinuesSameSlice()
    {
        var (clock, engine, tasks) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.True(engine.PauseManual());
        var remainingAtPause = engine.GetStatus().Remaining;
        clock.Advance(TimeSpan.FromMinutes(5));
        engine.Pulse();

        Assert.Equal(remainingAtPause, engine.GetStatus().Remaining);
        Assert.Equal(TimeSpan.FromSeconds(2), Assert.Single(engine.GetSegments()).Duration);

        Assert.True(engine.ResumeManual());
        clock.Advance(TimeSpan.FromSeconds(1));
        engine.Pulse();
        Assert.Equal(tasks[0].SliceDuration - TimeSpan.FromSeconds(3), engine.GetStatus().Remaining);
    }

    [Fact]
    public void Skip_DoesNotCompleteTaskAndRotates()
    {
        var (clock, engine, tasks) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.True(engine.SkipCurrentSlice());

        var status = engine.GetStatus();
        Assert.Equal(tasks[1].Id, status.CurrentTaskId);
        Assert.Equal(RotationState.AwaitingConfirmation, status.State);
        Assert.False(engine.GetTasks().Single(task => task.Id == tasks[0].Id).Completed);
        Assert.Equal(WorkEndReason.Skipped, Assert.Single(engine.GetSegments()).EndReason);
    }

    [Fact]
    public void CompleteEarly_MarksTaskCompleteAndExcludesIt()
    {
        var (clock, engine, tasks) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.True(engine.CompleteCurrentTask());

        Assert.True(engine.GetTasks().Single(task => task.Id == tasks[0].Id).Completed);
        Assert.Equal(tasks[1].Id, engine.GetStatus().CurrentTaskId);
        Assert.Equal(WorkEndReason.CompletedEarly, Assert.Single(engine.GetSegments()).EndReason);
    }

    [Fact]
    public void SingleActiveTask_ReturnsToConfirmationAfterEverySlice()
    {
        var task = NewTask("Only", TimeSpan.FromSeconds(2), 0);
        var (clock, engine) = CreateEngine(new[] { task }, heartbeatGap: TimeSpan.FromSeconds(10));
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));
        engine.Pulse();

        var status = engine.GetStatus();
        Assert.Equal(RotationState.AwaitingConfirmation, status.State);
        Assert.Equal(task.Id, status.CurrentTaskId);
        Assert.Equal(task.SliceDuration, status.Remaining);
    }

    [Fact]
    public void HeartbeatGap_PausesSystemAndDiscardsUntrustedGap()
    {
        var (clock, engine, tasks) = CreateEngine(heartbeatGap: TimeSpan.FromSeconds(5));
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));
        engine.Pulse();
        clock.Advance(TimeSpan.FromSeconds(6));
        engine.Pulse();

        var status = engine.GetStatus();
        Assert.Equal(RotationState.PausedSystem, status.State);
        Assert.Equal(SystemPauseReason.HeartbeatGap, status.SystemPauseReason);
        Assert.Equal(tasks[0].SliceDuration - TimeSpan.FromSeconds(2), status.Remaining);
        Assert.Equal(TimeSpan.FromSeconds(2), Assert.Single(engine.GetSegments()).Duration);
    }

    [Fact]
    public void ExplicitSystemPause_DoesNotCountOfflineTimeAndCanResume()
    {
        var (clock, engine, tasks) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.True(engine.PauseForSystem(SystemPauseReason.Lock));
        var remaining = engine.GetStatus().Remaining;
        clock.Advance(TimeSpan.FromHours(1));
        engine.Pulse();
        Assert.Equal(remaining, engine.GetStatus().Remaining);

        Assert.True(engine.ResumeAfterSystemPause());
        Assert.Equal(RotationState.Running, engine.GetStatus().State);
        clock.Advance(TimeSpan.FromSeconds(1));
        engine.Pulse();
        Assert.Equal(tasks[0].SliceDuration - TimeSpan.FromSeconds(3), engine.GetStatus().Remaining);
    }

    [Fact]
    public void SystemPauseDuringConfirmation_RequiresASecondConfirmation()
    {
        var (_, engine, _) = CreateEngine();
        engine.StartRotation();
        Assert.True(engine.PauseForSystem(SystemPauseReason.Lock));

        Assert.True(engine.ResumeAfterSystemPause());
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);
    }

    [Fact]
    public void RestartRecovery_FinalizesCheckpointedWorkAndNeverCountsOfflineTime()
    {
        var (clock, engine, tasks) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(3));
        engine.Pulse();
        var checkpoint = engine.CreateCheckpoint();

        clock.Advance(TimeSpan.FromHours(8));
        var restored = new RotationEngine(clock, Options());
        restored.Load(engine.GetTasks(), engine.GetSegments(), checkpoint);

        var status = restored.GetStatus();
        var segment = Assert.Single(restored.GetSegments());
        Assert.Equal(RotationState.PausedSystem, status.State);
        Assert.Equal(SystemPauseReason.ApplicationRestart, status.SystemPauseReason);
        Assert.Equal(TimeSpan.FromSeconds(3), segment.Duration);
        Assert.Equal(WorkEndReason.ApplicationInterrupted, segment.EndReason);
        Assert.Equal(tasks[0].SliceDuration - TimeSpan.FromSeconds(3), status.Remaining);
    }

    [Fact]
    public void WallClockChange_DoesNotAffectDuration()
    {
        var (clock, engine, _) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.AdvanceMonotonicOnly(TimeSpan.FromSeconds(2));
        clock.SetUtcNow(clock.GetUtcNow() - TimeSpan.FromDays(1));

        Assert.True(engine.PauseManual());

        var segment = Assert.Single(engine.GetSegments());
        Assert.Equal(TimeSpan.FromSeconds(2), segment.Duration);
        Assert.True(segment.EndedAtUtc >= segment.StartedAtUtc);
    }

    [Fact]
    public void DisabledAndCompletedTasks_AreExcluded()
    {
        var disabled = NewTask("Disabled", TimeSpan.FromMinutes(1), 0);
        disabled.Enabled = false;
        var completed = NewTask("Completed", TimeSpan.FromMinutes(1), 1);
        completed.Completed = true;
        var active = NewTask("Active", TimeSpan.FromMinutes(1), 2);
        var (_, engine) = CreateEngine(new[] { disabled, completed, active });

        Assert.True(engine.StartRotation());
        Assert.Equal(active.Id, engine.GetStatus().CurrentTaskId);
        Assert.Equal(active.SliceDuration, engine.GetStatus().ActiveCycleDuration);
    }

    [Fact]
    public void AllTasksCompleted_TransitionsToCompleted()
    {
        var completed = NewTask("Done", TimeSpan.FromMinutes(1), 0);
        completed.Completed = true;
        var (_, engine) = CreateEngine(new[] { completed });

        Assert.False(engine.StartRotation());
        Assert.Equal(RotationState.Completed, engine.GetStatus().State);
    }

    [Fact]
    public void DoubleConfirm_IsIdempotent()
    {
        var (_, engine, _) = CreateEngine();
        engine.StartRotation();

        Assert.True(engine.ConfirmCurrentTask());
        Assert.False(engine.ConfirmCurrentTask());
        Assert.Equal(RotationState.Running, engine.GetStatus().State);
    }

    [Fact]
    public void Stop_PreservesWorkedSegmentAndReturnsIdle()
    {
        var (clock, engine, _) = CreateEngine();
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.True(engine.StopRotation());

        Assert.Equal(RotationState.Idle, engine.GetStatus().State);
        var segment = Assert.Single(engine.GetSegments());
        Assert.Equal(TimeSpan.FromSeconds(2), segment.Duration);
        Assert.Equal(WorkEndReason.Stopped, segment.EndReason);
    }

    [Fact]
    public void ReplaceTasks_DetectsDuplicateIds()
    {
        var (_, engine, tasks) = CreateEngine();
        var duplicate = tasks[0].Clone();
        duplicate.Name = "Duplicate";

        Assert.Throws<ArgumentException>(() => engine.ReplaceTasks(new[] { tasks[0], duplicate }));
    }

    [Fact]
    public void ReplaceTasks_IsForbiddenDuringRotation()
    {
        var (_, engine, tasks) = CreateEngine();
        engine.StartRotation();

        Assert.Throws<InvalidOperationException>(() => engine.ReplaceTasks(tasks));
    }

    private static (FakeClock Clock, RotationEngine Engine, TaskItem[] Tasks) CreateEngine(
        TimeSpan? heartbeatGap = null)
    {
        var tasks = new[]
        {
            NewTask("Alpha", TimeSpan.FromMinutes(20), 0),
            NewTask("Beta", TimeSpan.FromMinutes(10), 1),
        };
        var (clock, engine) = CreateEngine(tasks, heartbeatGap);
        return (clock, engine, tasks);
    }

    private static (FakeClock Clock, RotationEngine Engine) CreateEngine(
        IEnumerable<TaskItem> tasks,
        TimeSpan? heartbeatGap = null)
    {
        var clock = new FakeClock();
        var engine = new RotationEngine(clock, Options(heartbeatGap));
        engine.ReplaceTasks(tasks);
        return (clock, engine);
    }

    private static RotationOptions Options(TimeSpan? heartbeatGap = null)
    {
        return new RotationOptions
        {
            ConfirmationTimeout = TimeSpan.FromSeconds(10),
            HeartbeatGapThreshold = heartbeatGap ?? TimeSpan.FromMinutes(10),
        };
    }

    private static TaskItem NewTask(string name, TimeSpan duration, int order)
    {
        return new TaskItem
        {
            Name = name,
            SliceDuration = duration,
            Order = order,
            CreatedAtUtc = new DateTimeOffset(2026, 9, 3, 0, order, 0, TimeSpan.Zero),
            UpdatedAtUtc = new DateTimeOffset(2026, 9, 3, 0, order, 0, TimeSpan.Zero),
        };
    }
}
