using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class CoverageEdgeTests
{
    [Fact]
    public void RotationOptions_RejectsBothNonPositiveTimeouts()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new RotationOptions
        {
            ConfirmationTimeout = TimeSpan.Zero,
        }.Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new RotationOptions
        {
            HeartbeatGapThreshold = TimeSpan.Zero,
        }.Validate());
    }

    [Fact]
    public void SystemMonotonicClock_DelegatesAndRejectsNullProvider()
    {
        var clock = new SystemMonotonicClock(TimeProvider.System);
        var timestamp = clock.GetTimestamp();

        Assert.Equal(TimeSpan.Zero, clock.GetElapsedTime(timestamp, timestamp));
        Assert.NotEqual(default, clock.GetUtcNow());
        Assert.Throws<ArgumentNullException>(() => new SystemMonotonicClock(null!));
    }

    [Fact]
    public void StatisticsFilter_AllAndUnknownScopeBehaveSafely()
    {
        var localNow = new DateTimeOffset(2026, 9, 3, 12, 0, 0, TimeSpan.FromHours(8));
        var segment = Segment("all", new DateTimeOffset(2020, 1, 1, 0, 0, 0, TimeSpan.Zero));

        Assert.Single(StatisticsCalculator.Filter(new[] { segment }, "All", localNow));
        Assert.Empty(StatisticsCalculator.Filter(new[] { segment }, "unknown", localNow));
    }

    [Fact]
    public void StatisticsFilter_ThirtyDaysIncludesLocalStart()
    {
        var localNow = new DateTimeOffset(2026, 9, 3, 12, 0, 0, TimeSpan.FromHours(8));
        var included = Segment("included", new DateTimeOffset(2026, 8, 5, 0, 0, 0, TimeSpan.FromHours(8)));
        var excluded = Segment("excluded", new DateTimeOffset(2026, 8, 4, 23, 59, 0, TimeSpan.FromHours(8)));

        var result = StatisticsCalculator.Filter(new[] { included, excluded }, "ThirtyDays", localNow);

        Assert.Equal("included", Assert.Single(result).TaskName);
    }

    [Fact]
    public void EmptyStoreLoad_ReturnsFreshDataWithoutRecovery()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var result = new JsonFileDataStore(directory).Load();

            Assert.False(result.RecoveredFromCorruption);
            Assert.False(result.RecoveredFromBackup);
            Assert.Empty(result.Data.Tasks);
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void NullCollections_AreNormalizedBeforeSave()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var data = new TaskronomeData
            {
                Settings = null!,
                WindowPlacement = null!,
                Tasks = null!,
                WorkSegments = null!,
                Events = null!,
            };
            var store = new JsonFileDataStore(directory);

            store.Save(data);
            var result = store.Load();

            Assert.NotNull(result.Data.Settings);
            Assert.NotNull(result.Data.WindowPlacement);
            Assert.NotNull(result.Data.Tasks);
            Assert.NotNull(result.Data.WorkSegments);
            Assert.NotNull(result.Data.Events);
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void NullJson_IsPreservedAsCorruption()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            Directory.CreateDirectory(directory);
            File.WriteAllText(store.DataFilePath, "null");

            var result = store.Load();

            Assert.True(result.RecoveredFromCorruption);
            Assert.NotNull(result.CorruptFilePath);
            Assert.True(File.Exists(result.CorruptFilePath));
        }
        finally
        {
            DeleteTemporaryDirectory(directory);
        }
    }

    [Fact]
    public void NullTask_IsRejectedAsInvalidData()
    {
        var data = new TaskronomeData
        {
            Tasks = new List<TaskItem> { null! },
        };

        Assert.Throws<InvalidDataException>(() => new JsonFileDataStore(CreateTemporaryDirectory()).Save(data));
    }

    [Fact]
    public void DuplicateTaskIds_AreRejectedAsInvalidData()
    {
        var first = NewTask("first", 0);
        var second = NewTask("second", 1);
        second.Id = first.Id;
        var data = new TaskronomeData { Tasks = new List<TaskItem> { first, second } };

        Assert.Throws<InvalidDataException>(() => new JsonFileDataStore(CreateTemporaryDirectory()).Save(data));
    }

    [Fact]
    public void SegmentDurationBeyondTimestampInterval_IsRejectedAsInvalidData()
    {
        var segment = new WorkSegment(
            Guid.NewGuid(),
            Guid.NewGuid(),
            "wide",
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow.AddSeconds(1),
            TimeSpan.MaxValue,
            WorkEndReason.ManualPause);
        var data = new TaskronomeData { WorkSegments = new List<WorkSegment> { segment } };

        Assert.Throws<InvalidDataException>(() => new JsonFileDataStore(CreateTemporaryDirectory()).Save(data));
    }

    [Fact]
    public void InvalidEvent_IsRejectedAsInvalidData()
    {
        var item = new RotationEvent(
            Guid.NewGuid(),
            DateTimeOffset.UtcNow,
            (RotationEventType)999,
            null,
            string.Empty,
            string.Empty);
        var data = new TaskronomeData { Events = new List<RotationEvent> { item } };

        Assert.Throws<InvalidDataException>(() => new JsonFileDataStore(CreateTemporaryDirectory()).Save(data));
    }

    [Fact]
    public void InvalidCheckpointEnum_IsRejectedAsInvalidData()
    {
        var data = new TaskronomeData
        {
            Checkpoint = new RotationCheckpoint
            {
                State = (RotationState)999,
            },
        };

        Assert.Throws<InvalidDataException>(() => new JsonFileDataStore(CreateTemporaryDirectory()).Save(data));
    }

    [Fact]
    public void CompletedCheckpoint_ChoosesCompletedOrIdleByTaskAvailability()
    {
        var completed = NewTask("completed", 0);
        completed.Completed = true;
        var completedEngine = new RotationEngine(new FakeClock());
        completedEngine.Load(new[] { completed }, null, new RotationCheckpoint { State = RotationState.Completed });
        Assert.Equal(RotationState.Completed, completedEngine.GetStatus().State);

        var active = NewTask("active", 0);
        var activeEngine = new RotationEngine(new FakeClock());
        activeEngine.Load(new[] { active }, null, new RotationCheckpoint { State = RotationState.Completed });
        Assert.Equal(RotationState.Idle, activeEngine.GetStatus().State);
    }

    [Fact]
    public void PausedSystemCheckpointWithUnknownPreviousState_RequiresConfirmation()
    {
        var clock = new FakeClock();
        var task = NewTask("recovery", 0);
        var engine = new RotationEngine(clock);
        engine.Load(
            new[] { task },
            null,
            new RotationCheckpoint
            {
                State = RotationState.PausedSystem,
                StateBeforeSystemPause = RotationState.Idle,
                CurrentTaskId = task.Id,
                Remaining = task.SliceDuration,
            });

        Assert.True(engine.ResumeAfterSystemPause());
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);
        Assert.True(engine.ConfirmCurrentTask());
    }

    [Fact]
    public void PausedAbsentCheckpointCanResumeIntoFreshConfirmation()
    {
        var task = NewTask("absent", 0);
        var engine = new RotationEngine(new FakeClock());
        engine.Load(
            new[] { task },
            null,
            new RotationCheckpoint
            {
                State = RotationState.PausedAbsent,
                CurrentTaskId = task.Id,
                Remaining = task.SliceDuration,
            });

        Assert.True(engine.ResumeAfterAbsence());
        Assert.Equal(RotationState.AwaitingConfirmation, engine.GetStatus().State);
    }

    [Fact]
    public void ZeroRemainingCheckpointIsClampedToFreshSlice()
    {
        var task = NewTask("clamp", 0);
        var engine = new RotationEngine(new FakeClock());
        engine.Load(
            new[] { task },
            null,
            new RotationCheckpoint
            {
                State = RotationState.PausedManual,
                CurrentTaskId = task.Id,
                Remaining = TimeSpan.Zero,
            });

        Assert.Equal(task.SliceDuration, engine.GetStatus().Remaining);
        Assert.True(engine.ResumeManual());
    }

    [Fact]
    public void CommandsFromSafeOrWrongStatesAreRejected()
    {
        var engine = new RotationEngine(new FakeClock());
        var task = NewTask("safe", 0);
        engine.ReplaceTasks(new[] { task });

        Assert.False(engine.ConfirmCurrentTask());
        Assert.False(engine.ResumeManual());
        Assert.False(engine.PauseForSystem(SystemPauseReason.Lock));

        Assert.True(engine.StartRotation());
        Assert.True(engine.CompleteCurrentTask());
        Assert.Equal(RotationState.Completed, engine.GetStatus().State);
        Assert.False(engine.PauseForSystem(SystemPauseReason.Lock));
    }

    [Fact]
    public void NullTaskFieldsAreValidatedWithoutThrowing()
    {
        Assert.False(TaskValidator.Validate(null, null, TimeSpan.FromSeconds(1)).IsValid);
        Assert.True(TaskValidator.Validate("valid", null, TimeSpan.FromSeconds(1)).IsValid);
    }

    private static TaskItem NewTask(string name, int order)
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

    private static WorkSegment Segment(string name, DateTimeOffset startedAtUtc) =>
        new(
            Guid.NewGuid(),
            Guid.NewGuid(),
            name,
            startedAtUtc,
            startedAtUtc.AddMinutes(1),
            TimeSpan.FromMinutes(1),
            WorkEndReason.ManualPause);

    private static string CreateTemporaryDirectory() =>
        Path.Combine(Path.GetTempPath(), $"TaskronomeCoverage-{Guid.NewGuid():N}");

    private static void DeleteTemporaryDirectory(string directory)
    {
        if (Directory.Exists(directory))
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
