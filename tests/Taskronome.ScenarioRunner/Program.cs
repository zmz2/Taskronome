using System.Diagnostics;
using System.Text.Json;
using Taskronome.Core;

var resultPath = GetOption(args, "--result") ?? Path.Combine(Environment.CurrentDirectory, "artifacts", "scenario-result.json");
var logPath = GetOption(args, "--log") ?? Path.Combine(Environment.CurrentDirectory, "artifacts", "scenario-log.txt");
var timeline = new List<ScenarioObservation>();
var stopwatch = Stopwatch.StartNew();

try
{
    var tasks = new[]
    {
        NewTask("任务 A", TimeSpan.FromSeconds(2), 0),
        NewTask("任务 B", TimeSpan.FromSeconds(3), 1),
    };
    var clock = new SystemMonotonicClock();
    var engine = new RotationEngine(
        clock,
        new RotationOptions
        {
            ConfirmationTimeout = TimeSpan.FromSeconds(2),
            HeartbeatGapThreshold = TimeSpan.FromSeconds(6),
        });
    engine.ReplaceTasks(tasks);
    Observe("initial", engine, timeline, stopwatch);

    Require(engine.StartRotation(), "轮转未开始");
    Observe("start-awaiting-A", engine, timeline, stopwatch);
    Thread.Sleep(250);
    engine.Pulse();
    Require(engine.GetStatus().State == RotationState.AwaitingConfirmation, "确认前状态错误");
    Require(engine.GetSegments().Count == 0, "确认前不应有工作段");
    Observe("waiting-does-not-count", engine, timeline, stopwatch);

    Require(engine.ConfirmCurrentTask(), "任务 A 确认失败");
    Observe("confirmed-A", engine, timeline, stopwatch);
    Thread.Sleep(2150);
    engine.Pulse();
    var afterA = engine.GetStatus();
    Require(afterA.State == RotationState.AwaitingConfirmation, "任务 A 未自然结束并进入下一项确认");
    Require(afterA.CurrentTaskId == tasks[1].Id, "自然结束后没有轮到任务 B");
    var firstA = engine.GetSegments().Single(segment => segment.TaskId == tasks[0].Id);
    Require(firstA.EndReason == WorkEndReason.SliceExpired, "任务 A 结束原因错误");
    Require(firstA.Duration >= TimeSpan.FromMilliseconds(1950) && firstA.Duration <= TimeSpan.FromMilliseconds(2050), "任务 A 实际时长偏离 2 秒过大");
    Observe("expired-A-awaiting-B", engine, timeline, stopwatch);

    Require(engine.ConfirmCurrentTask(), "任务 B 确认失败");
    Thread.Sleep(850);
    engine.Pulse();
    Require(engine.PauseManual(), "任务 B 手动暂停失败");
    var pausedRemaining = engine.GetStatus().Remaining;
    Observe("manual-paused-B", engine, timeline, stopwatch);
    Thread.Sleep(400);
    engine.Pulse();
    Require(engine.GetStatus().Remaining == pausedRemaining, "手动暂停期间仍在计时");
    Observe("manual-pause-still-frozen", engine, timeline, stopwatch);

    Require(engine.ResumeManual(), "任务 B 手动恢复失败");
    Thread.Sleep(550);
    engine.Pulse();
    Require(engine.CompleteCurrentTask(), "任务 B 提前完成失败");
    var completedB = engine.GetTasks().Single(task => task.Id == tasks[1].Id);
    Require(completedB.Completed, "提前完成后任务 B 仍未标记完成");
    Require(engine.GetStatus().State == RotationState.AwaitingConfirmation, "任务 B 完成后没有回到任务 A 确认");
    Require(engine.GetStatus().CurrentTaskId == tasks[0].Id, "任务 B 完成后任务 A 未成为当前任务");
    Observe("completed-early-B", engine, timeline, stopwatch);

    var segmentCountBeforeAbsence = engine.GetSegments().Count;
    var totalBeforeAbsence = TotalDuration(engine);
    Thread.Sleep(2200);
    engine.Pulse();
    Require(engine.GetStatus().State == RotationState.PausedAbsent, "确认超时没有进入离开暂停");
    Require(engine.GetSegments().Count == segmentCountBeforeAbsence, "确认超时产生了虚假工作段");
    Require(TotalDuration(engine) == totalBeforeAbsence, "确认超时增加了虚假时长");
    Observe("confirmation-timeout-absence", engine, timeline, stopwatch);
    Thread.Sleep(400);
    engine.Pulse();
    Require(TotalDuration(engine) == totalBeforeAbsence, "离开暂停期间统计增长");
    Observe("absence-still-frozen", engine, timeline, stopwatch);

    Require(engine.ResumeAfterAbsence(), "离开暂停恢复失败");
    Require(engine.GetStatus().State == RotationState.AwaitingConfirmation, "恢复离开暂停没有重新发起确认");
    Require(engine.ConfirmCurrentTask(), "恢复后的任务 A 确认失败");
    Thread.Sleep(450);
    engine.Pulse();
    Require(engine.PauseManual(), "第二轮手动暂停失败");
    var secondPausedRemaining = engine.GetStatus().Remaining;
    Thread.Sleep(350);
    engine.Pulse();
    Require(engine.GetStatus().Remaining == secondPausedRemaining, "第二轮手动暂停期间统计增长");
    Require(engine.ResumeManual(), "第二轮手动恢复失败");
    Thread.Sleep(1800);
    engine.Pulse();
    Require(engine.GetStatus().State == RotationState.AwaitingConfirmation, "任务 A 第二轮未自然结束");
    Require(engine.GetStatus().CurrentTaskId == tasks[0].Id, "已完成任务 B 又被错误选中");
    Observe("second-natural-A", engine, timeline, stopwatch);

    Require(engine.ConfirmCurrentTask(), "最后一轮任务 A 确认失败");
    Thread.Sleep(250);
    engine.Pulse();
    Require(engine.CompleteCurrentTask(), "最后一轮提前完成任务 A 失败");
    Require(engine.GetStatus().State == RotationState.Completed, "所有任务完成后没有进入 Completed");
    Observe("completed", engine, timeline, stopwatch);

    var temporaryDirectory = Path.Combine(Path.GetTempPath(), $"Taskronome-Scenario-{Guid.NewGuid():N}");
    try
    {
        var store = new JsonFileDataStore(temporaryDirectory);
        var data = new TaskronomeData
        {
            Tasks = engine.GetTasks().ToList(),
            WorkSegments = engine.GetSegments().ToList(),
            Events = engine.GetEvents().ToList(),
            Checkpoint = engine.CreateCheckpoint(),
        };
        store.Save(data);
        var loaded = store.Load();
        Require(!loaded.RecoveredFromCorruption, "正常保存后的重载被错误标记为损坏");
        Require(loaded.Data.Tasks.Count == data.Tasks.Count, "重载后任务数量不一致");
        Require(loaded.Data.WorkSegments.Count == data.WorkSegments.Count, "重载后工作段数量不一致");
        Require(loaded.Data.Events.Count == data.Events.Count, "重载后事件数量不一致");
        Observe("persisted-and-reloaded", engine, timeline, stopwatch);
    }
    finally
    {
        if (Directory.Exists(temporaryDirectory))
        {
            Directory.Delete(temporaryDirectory, recursive: true);
        }
    }

    var totalRecorded = TotalDuration(engine);
    Require(totalRecorded >= TimeSpan.FromSeconds(4), "真实场景记录的工作时长过少");
    Require(totalRecorded <= TimeSpan.FromSeconds(6), "真实场景记录了确认/暂停/离线时间");
    var passed = new
    {
        result = "passed",
        elapsedMilliseconds = Math.Round(stopwatch.Elapsed.TotalMilliseconds, 1),
        segmentCount = engine.GetSegments().Count,
        recordedMilliseconds = Math.Round(totalRecorded.TotalMilliseconds, 1),
        events = engine.GetEvents().Count,
        timeline,
    };
    WriteEvidence(resultPath, logPath, passed, timeline);
    Console.WriteLine(JsonSerializer.Serialize(passed));
    return 0;
}
catch (Exception exception)
{
    var failed = new
    {
        result = "failed",
        elapsedMilliseconds = Math.Round(stopwatch.Elapsed.TotalMilliseconds, 1),
        error = exception.Message,
        timeline,
    };
    WriteEvidence(resultPath, logPath, failed, timeline);
    Console.Error.WriteLine($"SCENARIO FAILED: {exception.Message}");
    return 1;
}

static TaskItem NewTask(string name, TimeSpan duration, int order) => new()
{
    Name = name,
    SliceDuration = duration,
    Order = order,
    CreatedAtUtc = DateTimeOffset.UtcNow,
    UpdatedAtUtc = DateTimeOffset.UtcNow,
};

static void Observe(string label, RotationEngine engine, ICollection<ScenarioObservation> timeline, Stopwatch stopwatch)
{
    var status = engine.GetStatus();
    timeline.Add(new ScenarioObservation(
        label,
        Math.Round(stopwatch.Elapsed.TotalMilliseconds, 1),
        status.State.ToString(),
        status.CurrentTaskName,
        Math.Round(status.Remaining.TotalMilliseconds, 1),
        engine.GetSegments().Count,
        Math.Round(TotalDuration(engine).TotalMilliseconds, 1)));
}

static TimeSpan TotalDuration(RotationEngine engine) =>
    engine.GetSegments().Aggregate(TimeSpan.Zero, (total, segment) => total + segment.Duration);

static string? GetOption(string[] args, string option)
{
    var index = Array.FindIndex(args, argument => string.Equals(argument, option, StringComparison.OrdinalIgnoreCase));
    if (index < 0)
    {
        return null;
    }

    if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]))
    {
        throw new ArgumentException($"{option} requires a path.", nameof(args));
    }

    return Path.GetFullPath(args[index + 1]);
}

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void WriteEvidence(string resultPath, string logPath, object result, IEnumerable<ScenarioObservation> timeline)
{
    var resultDirectory = Path.GetDirectoryName(resultPath);
    if (!string.IsNullOrWhiteSpace(resultDirectory))
    {
        Directory.CreateDirectory(resultDirectory);
    }

    var logDirectory = Path.GetDirectoryName(logPath);
    if (!string.IsNullOrWhiteSpace(logDirectory))
    {
        Directory.CreateDirectory(logDirectory);
    }

    File.WriteAllText(
        resultPath,
        JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }),
        new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    File.WriteAllLines(
        logPath,
        timeline.Select(item => $"{item.ElapsedMilliseconds,8:0.0} ms | {item.Label,-30} | {item.State,-24} | {item.CurrentTaskName,-8} | remaining {item.RemainingMilliseconds,8:0.0} ms | segments {item.SegmentCount} | total {item.RecordedMilliseconds,8:0.0} ms"));
}

internal sealed record ScenarioObservation(
    string Label,
    double ElapsedMilliseconds,
    string State,
    string CurrentTaskName,
    double RemainingMilliseconds,
    int SegmentCount,
    double RecordedMilliseconds);
