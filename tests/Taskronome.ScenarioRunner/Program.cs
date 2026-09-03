using System.Text.Json;
using Taskronome.Core;

var tasks = new[]
{
    new TaskItem { Name = "scenario-a", SliceDuration = TimeSpan.FromSeconds(1), Order = 0 },
    new TaskItem { Name = "scenario-b", SliceDuration = TimeSpan.FromSeconds(1), Order = 1 },
};

var engine = new RotationEngine(
    new SystemMonotonicClock(),
    new RotationOptions
    {
        ConfirmationTimeout = TimeSpan.FromSeconds(2),
        HeartbeatGapThreshold = TimeSpan.FromSeconds(3),
    });

engine.ReplaceTasks(tasks);
Require(engine.StartRotation(), "rotation did not start");
Require(engine.GetStatus().State == RotationState.AwaitingConfirmation, "first task skipped confirmation");
Require(engine.ConfirmCurrentTask(), "first confirmation failed");

Thread.Sleep(1125);
engine.Pulse();
var afterFirst = engine.GetStatus();
Require(afterFirst.State == RotationState.AwaitingConfirmation, "first slice did not expire into confirmation");
Require(afterFirst.CurrentTaskId == tasks[1].Id, "rotation did not move to second task");

Require(engine.ConfirmCurrentTask(), "second confirmation failed");
Thread.Sleep(350);
Require(engine.PauseManual(), "manual pause failed");
var pausedRemaining = engine.GetStatus().Remaining;
Thread.Sleep(300);
engine.Pulse();
Require(engine.GetStatus().Remaining == pausedRemaining, "paused time was incorrectly counted");

Require(engine.ResumeManual(), "manual resume failed");
Thread.Sleep(750);
engine.Pulse();
var finalStatus = engine.GetStatus();
var segments = engine.GetSegments();

Require(finalStatus.State == RotationState.AwaitingConfirmation, "second slice did not complete");
Require(finalStatus.CurrentTaskId == tasks[0].Id, "round-robin did not return to first task");
Require(segments.Count == 3, $"expected 3 work segments, got {segments.Count}");
Require(segments.Sum(segment => segment.Duration) >= TimeSpan.FromMilliseconds(1900), "too little real work was recorded");
Require(segments.Sum(segment => segment.Duration) <= TimeSpan.FromMilliseconds(2100), "too much time was recorded");

Console.WriteLine(JsonSerializer.Serialize(new
{
    result = "passed",
    state = finalStatus.State.ToString(),
    currentTask = finalStatus.CurrentTaskName,
    segmentCount = segments.Count,
    recordedMilliseconds = Math.Round(segments.Sum(segment => segment.Duration).TotalMilliseconds, 1),
}));

return;

static void Require(bool condition, string message)
{
    if (!condition)
    {
        Console.Error.WriteLine($"SCENARIO FAILED: {message}");
        Environment.Exit(1);
    }
}
