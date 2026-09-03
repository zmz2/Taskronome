using System.Text.Json;
using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class InvariantTests
{
    [Fact]
    public void EmptyTaskList_CannotStartRotation()
    {
        var engine = CreateEngine(new FakeClock());

        Assert.False(engine.StartRotation());
        Assert.Equal(RotationState.Completed, engine.GetStatus().State);
        Assert.Contains(engine.GetEvents(), item => item.Type == RotationEventType.RotationCompleted);
    }

    [Fact]
    public void DisabledTask_IsNotSelectedForRotation()
    {
        var clock = new FakeClock();
        var disabled = NewTask("disabled", 0);
        disabled.Enabled = false;
        var enabled = NewTask("enabled", 1);
        var engine = CreateEngine(clock, disabled, enabled);

        Assert.True(engine.StartRotation());
        Assert.Equal(enabled.Id, engine.GetStatus().CurrentTaskId);
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);
    }

    [Fact]
    public void ReenabledCompletedTask_BecomesEligibleAgain()
    {
        var clock = new FakeClock();
        var task = NewTask("reopen", 0);
        task.Completed = true;
        var engine = CreateEngine(clock, task);

        Assert.False(engine.StartRotation());
        task.Completed = false;
        task.Enabled = true;
        engine.ReplaceTasks(new[] { task });

        Assert.True(engine.StartRotation());
        Assert.Equal(task.Id, engine.GetStatus().CurrentTaskId);
    }

    [Fact]
    public void ConfirmationJustBeforeDeadline_IsAccepted()
    {
        var clock = new FakeClock();
        var engine = CreateEngine(clock, NewTask("deadline", 0));
        Assert.True(engine.StartRotation());

        clock.Advance(TimeSpan.FromSeconds(9) + TimeSpan.FromMilliseconds(999));

        Assert.True(engine.ConfirmCurrentTask());
        Assert.Equal(RotationState.Running, engine.GetStatus().State);
        Assert.Empty(engine.GetSegments());
    }

    [Fact]
    public void ConfirmationAfterDeadline_IsRejected()
    {
        var clock = new FakeClock();
        var engine = CreateEngine(clock, NewTask("deadline", 0));
        Assert.True(engine.StartRotation());
        clock.Advance(TimeSpan.FromSeconds(10) + TimeSpan.FromTicks(1));

        Assert.False(engine.ConfirmCurrentTask());
        Assert.Equal(RotationState.PausedAbsent, engine.GetStatus().State);
        Assert.Empty(engine.GetSegments());
    }

    [Fact]
    public void ManualPauseAndResume_AreIdempotentAndKeepOneSlice()
    {
        var clock = new FakeClock();
        var task = NewTask("pause", 0);
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));

        Assert.True(engine.PauseManual());
        var remaining = engine.GetStatus().Remaining;
        var segments = engine.GetSegments().Count;
        Assert.False(engine.PauseManual());
        Assert.Equal(segments, engine.GetSegments().Count);

        Assert.True(engine.ResumeManual());
        Assert.False(engine.ResumeManual());
        clock.Advance(TimeSpan.FromSeconds(1));
        engine.Pulse();
        Assert.Equal(remaining - TimeSpan.FromSeconds(1), engine.GetStatus().Remaining);
        Assert.Equal(segments, engine.GetSegments().Count);
    }

    [Fact]
    public void CompleteWhileAwaitingConfirmation_RecordsZeroWorkAndIsIdempotent()
    {
        var clock = new FakeClock();
        var task = NewTask("complete", 0);
        var engine = CreateEngine(clock, task);
        engine.StartRotation();

        Assert.True(engine.CompleteCurrentTask());
        Assert.Empty(engine.GetSegments());
        Assert.True(engine.GetTasks().Single().Completed);
        var eventCount = engine.GetEvents().Count;
        Assert.False(engine.CompleteCurrentTask());
        Assert.Equal(eventCount, engine.GetEvents().Count);
        Assert.Equal(RotationState.Completed, engine.GetStatus().State);
    }

    [Fact]
    public void Stop_IsIdempotentAfterSafeShutdown()
    {
        var clock = new FakeClock();
        var engine = CreateEngine(clock, NewTask("stop", 0));
        engine.StartRotation();

        Assert.True(engine.StopRotation());
        var eventCount = engine.GetEvents().Count;
        Assert.False(engine.StopRotation());
        Assert.Equal(eventCount, engine.GetEvents().Count);
        Assert.Equal(RotationState.Idle, engine.GetStatus().State);
    }

    [Fact]
    public void RestartFromRunning_StopsAtCheckpointAndDoesNotCountOfflineTime()
    {
        var clock = new FakeClock();
        var task = NewTask("restart", 0);
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));
        engine.Pulse();
        var checkpoint = engine.CreateCheckpoint();

        clock.Advance(TimeSpan.FromHours(8));
        var restored = CreateEngine(clock);
        restored.Load(new[] { task }, engine.GetSegments(), checkpoint, engine.GetEvents());
        restored.Pulse();

        Assert.Equal(RotationState.PausedSystem, restored.GetStatus().State);
        Assert.Equal(TimeSpan.FromSeconds(2), TotalDuration(restored));
        Assert.Equal(WorkEndReason.ApplicationInterrupted, Assert.Single(restored.GetSegments()).EndReason);
    }

    [Fact]
    public void RestartFromAwaitingConfirmation_RequiresExplicitRecoveryAction()
    {
        var clock = new FakeClock();
        var task = NewTask("waiting restart", 0);
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        var checkpoint = engine.CreateCheckpoint();

        var restored = CreateEngine(clock);
        restored.Load(new[] { task }, null, checkpoint);

        Assert.Equal(RotationState.PausedSystem, restored.GetStatus().State);
        Assert.False(restored.ConfirmCurrentTask());
        Assert.True(restored.ResumeAfterSystemPause());
        Assert.Equal(RotationState.AwaitingConfirmation, restored.GetStatus().State);
        Assert.True(restored.ConfirmCurrentTask());
    }

    [Fact]
    public void NegativeMonotonicGapDuringConfirmation_SafelyPauses()
    {
        var clock = new FakeClock();
        var engine = CreateEngine(clock, NewTask("clock", 0));
        engine.StartRotation();
        clock.RewindMonotonicOnly(TimeSpan.FromSeconds(1));
        engine.Pulse();

        Assert.Equal(RotationState.PausedSystem, engine.GetStatus().State);
        Assert.Equal(SystemPauseReason.HeartbeatGap, engine.GetStatus().SystemPauseReason);
        Assert.Empty(engine.GetSegments());
    }

    [Fact]
    public void WallClockForwardJump_DoesNotChangeRunningRemaining()
    {
        var clock = new FakeClock();
        var task = NewTask("wall clock", 0);
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));
        engine.Pulse();
        var remaining = engine.GetStatus().Remaining;
        clock.SetUtcNow(clock.GetUtcNow().AddDays(30));
        engine.Pulse();

        Assert.Equal(remaining, engine.GetStatus().Remaining);
    }

    [Fact]
    public void WallClockBackwardJump_DoesNotChangeRunningRemaining()
    {
        var clock = new FakeClock();
        var task = NewTask("wall clock", 0);
        var engine = CreateEngine(clock, task);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(TimeSpan.FromSeconds(2));
        engine.Pulse();
        var remaining = engine.GetStatus().Remaining;
        clock.SetUtcNow(clock.GetUtcNow().AddDays(-30));
        engine.Pulse();

        Assert.Equal(remaining, engine.GetStatus().Remaining);
    }

    [Fact]
    public void InactiveCheckpointTask_FallsBackToSafeIdleState()
    {
        var clock = new FakeClock();
        var task = NewTask("inactive", 0);
        task.Enabled = false;
        var checkpoint = new RotationCheckpoint
        {
            State = RotationState.Running,
            CurrentTaskId = task.Id,
            Remaining = task.SliceDuration,
        };
        var active = NewTask("active", 1);
        var engine = CreateEngine(clock);

        engine.Load(new[] { task, active }, null, checkpoint);

        Assert.Equal(RotationState.Idle, engine.GetStatus().State);
        Assert.Null(engine.GetStatus().CurrentTaskId);
    }

    [Fact]
    public void InvalidCheckpointState_IsRejected()
    {
        var clock = new FakeClock();
        var task = NewTask("invalid state", 0);
        var checkpoint = new RotationCheckpoint
        {
            State = (RotationState)999,
            CurrentTaskId = task.Id,
            Remaining = task.SliceDuration,
        };
        var engine = CreateEngine(clock);

        Assert.Throws<InvalidDataException>(() => engine.Load(new[] { task }, null, checkpoint));
    }

    [Fact]
    public void OverlongCheckpoint_IsRejected()
    {
        var clock = new FakeClock();
        var task = NewTask("overlong", 0);
        var checkpoint = new RotationCheckpoint
        {
            State = RotationState.PausedManual,
            CurrentTaskId = task.Id,
            Remaining = task.SliceDuration + TimeSpan.FromSeconds(1),
        };
        var engine = CreateEngine(clock);

        Assert.Throws<InvalidDataException>(() => engine.Load(new[] { task }, null, checkpoint));
    }

    [Fact]
    public void WrapAroundSelection_SkipsCompletedAndDisabledTasks()
    {
        var clock = new FakeClock();
        var first = NewTask("first", 0);
        var disabled = NewTask("disabled", 1);
        disabled.Enabled = false;
        var completed = NewTask("completed", 2);
        completed.Completed = true;
        var last = NewTask("last", 3);
        var engine = CreateEngine(clock, first, disabled, completed, last);
        engine.StartRotation();
        engine.ConfirmCurrentTask();
        clock.Advance(first.SliceDuration);
        engine.Pulse();

        Assert.Equal(last.Id, engine.GetStatus().CurrentTaskId);
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);
    }

    [Fact]
    public void SkipAndCompleteBeforeRunning_CreateEventsWithoutWorkSegments()
    {
        var clock = new FakeClock();
        var first = NewTask("skip", 0);
        var second = NewTask("complete", 1);
        var engine = CreateEngine(clock, first, second);
        engine.StartRotation();

        Assert.True(engine.SkipCurrentSlice());
        Assert.True(engine.CompleteCurrentTask());
        Assert.Empty(engine.GetSegments());
        Assert.Contains(engine.GetEvents(), item => item.Type == RotationEventType.SliceSkipped);
        Assert.Contains(engine.GetEvents(), item => item.Type == RotationEventType.TaskCompletedEarly);
    }

    [Fact]
    public void CsvFormatter_QuotesCommaQuotesNewlinesAndChinese()
    {
        var row = CsvFormatter.FormatRow(new string?[] { "中文,任务", "他说\"好\"", "第一行\n第二行", null });

        Assert.Equal("\"中文,任务\",\"他说\"\"好\"\"\",\"第一行\n第二行\",\"\"", row);
        Assert.Equal("\"\"", CsvFormatter.Escape(string.Empty));
    }

    [Fact]
    public void StatisticsFilter_UsesLocalTodayBoundary()
    {
        var localNow = new DateTimeOffset(2026, 9, 3, 12, 0, 0, TimeSpan.FromHours(8));
        var beforeMidnight = Segment("before", new DateTimeOffset(2026, 9, 2, 15, 59, 0, TimeSpan.Zero));
        var afterMidnight = Segment("after", new DateTimeOffset(2026, 9, 2, 16, 1, 0, TimeSpan.Zero));

        var today = StatisticsCalculator.Filter(new[] { beforeMidnight, afterMidnight }, "Today", localNow);

        Assert.Single(today);
        Assert.Equal(afterMidnight.TaskName, today[0].TaskName);
    }

    [Fact]
    public void StatisticsFilter_SevenDaysWindowIsInclusive()
    {
        var localNow = new DateTimeOffset(2026, 9, 3, 12, 0, 0, TimeSpan.FromHours(8));
        var firstIncluded = Segment("first", new DateTimeOffset(2026, 8, 28, 0, 0, 0, TimeSpan.FromHours(8)));
        var excluded = Segment("excluded", new DateTimeOffset(2026, 8, 27, 23, 59, 0, TimeSpan.FromHours(8)));

        var sevenDays = StatisticsCalculator.Filter(new[] { firstIncluded, excluded }, "SevenDays", localNow);

        Assert.Single(sevenDays);
        Assert.Equal("first", sevenDays[0].TaskName);
    }

    [Fact]
    public void CorruptMainWithGoodBackup_IsRecoveredAndMainIsRestored()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("good") } });
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("new") } });
            File.WriteAllText(store.DataFilePath, "{ broken main");

            var result = store.Load();

            Assert.True(result.RecoveredFromBackup);
            Assert.Equal("good", Assert.Single(result.Data.Tasks).Name);
            Assert.NotNull(result.CorruptFilePath);
            Assert.True(File.Exists(result.CorruptFilePath));
            Assert.True(File.Exists(store.DataFilePath));
            Assert.Equal("good", Assert.Single(store.Load().Data.Tasks).Name);
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void CorruptMainAndBackup_AreBothPreservedBeforeFreshInitialization()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("good") } });
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("new") } });
            File.WriteAllText(store.DataFilePath, "{ broken main");
            File.WriteAllText(store.BackupFilePath, "{ broken backup");

            var result = store.Load();

            Assert.True(result.RecoveredFromCorruption);
            Assert.NotNull(result.CorruptFilePath);
            Assert.NotNull(result.CorruptBackupFilePath);
            Assert.True(File.Exists(result.CorruptFilePath));
            Assert.True(File.Exists(result.CorruptBackupFilePath));
            Assert.Empty(result.Data.Tasks);
            Assert.False(File.Exists(store.DataFilePath));
            Assert.False(File.Exists(store.BackupFilePath));
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void MissingMainWithGoodBackup_RestoresBackupWithoutDataLoss()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("good") } });
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("new") } });
            File.Delete(store.DataFilePath);

            var result = store.Load();

            Assert.True(result.RecoveredFromBackup);
            Assert.Equal("good", Assert.Single(result.Data.Tasks).Name);
            Assert.True(File.Exists(store.DataFilePath));
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void FileSystemSharingFailure_IsNotMisclassifiedAsCorruption()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            store.Save(new TaskronomeData { Tasks = new List<TaskItem> { NewTask("locked") } });
            using var file = new FileStream(store.DataFilePath, FileMode.Open, FileAccess.Read, FileShare.None);

            Assert.ThrowsAny<IOException>(() => store.Load());
            Assert.True(File.Exists(store.DataFilePath));
            Assert.Empty(Directory.GetFiles(directory, "data.corrupt-*.json"));
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public async Task ConcurrentSaves_LeaveCompleteJsonAndNoTemporaryFiles()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var saveTasks = Enumerable.Range(0, 8)
                .Select(index => Task.Run(() =>
                {
                    var store = new JsonFileDataStore(directory);
                    store.Save(new TaskronomeData
                    {
                        Tasks = new List<TaskItem> { NewTask($"save-{index}") },
                    });
                }))
                .ToArray();
            await Task.WhenAll(saveTasks);

            var finalStore = new JsonFileDataStore(directory);
            var result = finalStore.Load();
            using var document = JsonDocument.Parse(File.ReadAllText(finalStore.DataFilePath));

            Assert.False(result.RecoveredFromCorruption);
            Assert.Single(result.Data.Tasks);
            Assert.Equal(JsonValueKind.Object, document.RootElement.ValueKind);
            Assert.Empty(Directory.GetFiles(directory, "data.*.tmp"));
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void TaskValidation_RejectsOverflowAndAcceptsExactBoundaries()
    {
        Assert.True(TaskValidator.Validate("a", string.Empty, TaskValidator.MinimumDuration).IsValid);
        Assert.True(TaskValidator.Validate("a", new string('x', 500), TaskValidator.MaximumDuration).IsValid);
        Assert.False(TaskValidator.Validate("a", string.Empty, TimeSpan.MaxValue).IsValid);
        Assert.False(TaskValidator.Validate("   ", string.Empty, TimeSpan.FromSeconds(1)).IsValid);
    }

    private static RotationEngine CreateEngine(FakeClock clock, params TaskItem[] tasks)
    {
        var engine = new RotationEngine(clock, new RotationOptions
        {
            ConfirmationTimeout = TimeSpan.FromSeconds(10),
            HeartbeatGapThreshold = TimeSpan.FromMinutes(1),
        });
        if (tasks.Length > 0)
        {
            engine.ReplaceTasks(tasks);
        }

        return engine;
    }

    private static TaskItem NewTask(string name, int order = 0)
    {
        var timestamp = new DateTimeOffset(2026, 9, 3, 0, order, 0, TimeSpan.Zero);
        return new TaskItem
        {
            Name = name,
            SliceDuration = TimeSpan.FromMinutes(1),
            Order = order,
            CreatedAtUtc = timestamp,
            UpdatedAtUtc = timestamp,
        };
    }

    private static WorkSegment Segment(string name, DateTimeOffset startedAtUtc)
    {
        return new WorkSegment(
            Guid.NewGuid(),
            Guid.NewGuid(),
            name,
            startedAtUtc,
            startedAtUtc.AddMinutes(1),
            TimeSpan.FromMinutes(1),
            WorkEndReason.ManualPause);
    }

    private static TimeSpan TotalDuration(RotationEngine engine) =>
        engine.GetSegments().Aggregate(TimeSpan.Zero, (total, segment) => total + segment.Duration);

    private static string CreateTemporaryDirectory() =>
        Path.Combine(Path.GetTempPath(), $"TaskronomeInvariant-{Guid.NewGuid():N}");

    private static void DeleteTemporaryDirectory(string directory)
    {
        if (Directory.Exists(directory))
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
