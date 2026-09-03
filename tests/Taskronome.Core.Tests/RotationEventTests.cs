using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class RotationEventTests
{
    [Fact]
    public void FullTurn_RecordsAuditableEventSequence()
    {
        var clock = new FakeClock();
        var task = new TaskItem
        {
            Name = "Audit",
            SliceDuration = TimeSpan.FromSeconds(2),
            Order = 0,
        };
        var engine = new RotationEngine(
            clock,
            new RotationOptions
            {
                ConfirmationTimeout = TimeSpan.FromSeconds(10),
                HeartbeatGapThreshold = TimeSpan.FromSeconds(30),
            });
        engine.ReplaceTasks(new[] { task });

        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));
        engine.Pulse();

        var types = engine.GetEvents().Select(item => item.Type).ToArray();
        Assert.Equal(
            new[]
            {
                RotationEventType.RotationStarted,
                RotationEventType.TaskConfirmationRequested,
                RotationEventType.TaskConfirmed,
                RotationEventType.SliceExpired,
                RotationEventType.TaskConfirmationRequested,
            },
            types);
    }

    [Fact]
    public void ConfirmationTimeout_RecordsNoWork()
    {
        var clock = new FakeClock();
        var task = new TaskItem
        {
            Name = "Timeout",
            SliceDuration = TimeSpan.FromMinutes(1),
        };
        var engine = new RotationEngine(
            clock,
            new RotationOptions
            {
                ConfirmationTimeout = TimeSpan.FromSeconds(10),
                HeartbeatGapThreshold = TimeSpan.FromMinutes(1),
            });
        engine.ReplaceTasks(new[] { task });
        engine.StartRotation();
        clock.Advance(TimeSpan.FromSeconds(10));
        engine.Pulse();

        Assert.Equal(RotationState.PausedAbsent, engine.GetStatus().State);
        Assert.Empty(engine.GetSegments());
        Assert.Contains(engine.GetEvents(), item => item.Type == RotationEventType.ConfirmationTimedOut);
    }
}
