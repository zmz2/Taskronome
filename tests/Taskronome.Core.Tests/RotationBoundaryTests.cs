using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class RotationBoundaryTests
{
    [Fact]
    public void CompleteCommandAfterNaturalExpiry_DoesNotCompleteTheNextTask()
    {
        var first = NewTask("First", TimeSpan.FromSeconds(2), 0);
        var second = NewTask("Second", TimeSpan.FromSeconds(5), 1);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, first, second);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.False(engine.CompleteCurrentTask());

        Assert.Equal(second.Id, engine.GetStatus().CurrentTaskId);
        Assert.False(engine.GetTasks().Single(task => task.Id == second.Id).Completed);
        Assert.True(engine.GetEvents().Any(item => item.Type == RotationEventType.SliceExpired));
        Assert.False(engine.GetEvents().Any(item => item.Type == RotationEventType.TaskCompletedEarly));
    }

    [Fact]
    public void SkipCommandAfterNaturalExpiry_DoesNotSkipTheNextTask()
    {
        var first = NewTask("First", TimeSpan.FromSeconds(2), 0);
        var second = NewTask("Second", TimeSpan.FromSeconds(5), 1);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, first, second);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.False(engine.SkipCurrentSlice());

        Assert.Equal(second.Id, engine.GetStatus().CurrentTaskId);
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);
        Assert.False(engine.GetEvents().Any(item => item.Type == RotationEventType.SliceSkipped));
    }

    [Fact]
    public void SystemInterruptionWhileManuallyPaused_PreservesManualPause()
    {
        var task = NewTask("Only", TimeSpan.FromMinutes(2), 0);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(3));
        engine.PauseManual();

        Assert.True(engine.PauseForSystem(SystemPauseReason.Lock));
        Assert.True(engine.ResumeAfterSystemPause());

        Assert.Equal(RotationState.PausedManual, engine.GetStatus().State);
        clock.Advance(TimeSpan.FromMinutes(30));
        engine.Pulse();
        Assert.Equal(task.SliceDuration - TimeSpan.FromSeconds(3), engine.GetStatus().Remaining);
    }

    [Fact]
    public void SkipWhileWaiting_RecordsEventEvenWithoutWorkSegment()
    {
        var first = NewTask("First", TimeSpan.FromMinutes(2), 0);
        var second = NewTask("Second", TimeSpan.FromMinutes(2), 1);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, first, second);
        engine.StartRotation();

        Assert.True(engine.SkipCurrentSlice());

        Assert.Empty(engine.GetSegments());
        var skipped = Assert.Single(engine.GetEvents().Where(item => item.Type == RotationEventType.SliceSkipped));
        Assert.Equal(first.Id, skipped.TaskId);
        Assert.Equal(second.Id, engine.GetStatus().CurrentTaskId);
    }

    [Fact]
    public void RestartWhileWaiting_DoesNotCountConfirmationWindow()
    {
        var task = NewTask("Only", TimeSpan.FromMinutes(2), 0);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        clock.Advance(TimeSpan.FromSeconds(8));
        var checkpoint = engine.CreateCheckpoint();

        clock.Advance(TimeSpan.FromHours(9));
        var restored = new RotationEngine(clock, Options());
        restored.Load(engine.GetTasks(), engine.GetSegments(), checkpoint, engine.GetEvents());

        Assert.Equal(RotationState.PausedSystem, restored.GetStatus().State);
        Assert.Equal(task.SliceDuration, restored.GetStatus().Remaining);
        Assert.Empty(restored.GetSegments());
    }

    [Fact]
    public void ReplaceTasks_NormalizesWhitespaceAndOrder()
    {
        var late = NewTask("  Late  ", TimeSpan.FromMinutes(1), 50);
        var early = NewTask("Early", TimeSpan.FromMinutes(1), -3);
        var engine = new RotationEngine(new FakeClock(), Options());

        engine.ReplaceTasks(new[] { late, early });

        var result = engine.GetTasks();
        Assert.Collection(
            result,
            item =>
            {
                Assert.Equal("Early", item.Name);
                Assert.Equal(0, item.Order);
            },
            item =>
            {
                Assert.Equal("Late", item.Name);
                Assert.Equal(1, item.Order);
            });
    }

    [Fact]
    public void StopDuringConfirmation_DoesNotCreateWorkSegment()
    {
        var task = NewTask("Only", TimeSpan.FromMinutes(1), 0);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        clock.Advance(TimeSpan.FromSeconds(4));

        Assert.True(engine.StopRotation());

        Assert.Empty(engine.GetSegments());
        Assert.Equal(RotationState.Idle, engine.GetStatus().State);
    }

    [Fact]
    public void RepeatedSystemPause_IsIdempotent()
    {
        var task = NewTask("Only", TimeSpan.FromMinutes(1), 0);
        var clock = new FakeClock();
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        engine.ConfirmCurrentTask();

        Assert.True(engine.PauseForSystem(SystemPauseReason.Lock));
        Assert.False(engine.PauseForSystem(SystemPauseReason.Suspend));
        Assert.Equal(
            1,
            engine.GetEvents().Count(item => item.Type == RotationEventType.SystemPaused));
    }

    private static RotationEngine CreateEngine(FakeClock clock, params TaskItem[] tasks)
    {
        var engine = new RotationEngine(clock, Options());
        engine.ReplaceTasks(tasks);
        return engine;
    }

    private static RotationOptions Options()
    {
        return new RotationOptions
        {
            ConfirmationTimeout = TimeSpan.FromSeconds(10),
            HeartbeatGapThreshold = TimeSpan.FromHours(1),
        };
    }

    private static TaskItem NewTask(string name, TimeSpan duration, int order)
    {
        return new TaskItem
        {
            Name = name,
            SliceDuration = duration,
            Order = order,
            CreatedAtUtc = DateTimeOffset.Parse("2026-09-03T00:00:00Z").AddMinutes(order),
            UpdatedAtUtc = DateTimeOffset.Parse("2026-09-03T00:00:00Z").AddMinutes(order),
        };
    }
}
