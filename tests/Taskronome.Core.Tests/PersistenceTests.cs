using System.Globalization;
using System.Text.Json;
using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class PersistenceTests
{
    [Fact]
    public void SaveAndLoad_RoundTripsAllDurableState()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var task = NewTask();
            var data = new TaskronomeData
            {
                Settings = new TaskronomeSettings
                {
                    AlwaysOnTop = false,
                    PlaySound = false,
                    ShowNotification = true,
                    MinimizeToTrayOnClose = false,
                    StatisticsScope = "SevenDays",
                },
                WindowPlacement = new WindowPlacementData
                {
                    Left = 50,
                    Top = 60,
                    Width = 900,
                    Height = 640,
                    IsMaximized = true,
                },
                Tasks = new List<TaskItem> { task },
                WorkSegments = new List<WorkSegment>
                {
                    new(
                        Guid.NewGuid(),
                        task.Id,
                        task.Name,
                        DateTimeOffset.Parse("2026-09-03T01:00:00Z", CultureInfo.InvariantCulture),
                        DateTimeOffset.Parse("2026-09-03T01:00:05Z", CultureInfo.InvariantCulture),
                        TimeSpan.FromSeconds(5),
                        WorkEndReason.ManualPause),
                },
                Events = new List<RotationEvent>
                {
                    new(
                        Guid.NewGuid(),
                        DateTimeOffset.Parse("2026-09-03T01:00:05Z", CultureInfo.InvariantCulture),
                        RotationEventType.ManualPaused,
                        task.Id,
                        task.Name,
                        "paused"),
                },
                Checkpoint = new RotationCheckpoint
                {
                    State = RotationState.PausedManual,
                    CurrentTaskId = task.Id,
                    Remaining = TimeSpan.FromMinutes(19),
                    SavedAtUtc = DateTimeOffset.Parse("2026-09-03T01:00:05Z"),
                },
            };

            var store = new JsonFileDataStore(directory);
            store.Save(data);
            var result = store.Load();

            Assert.False(result.RecoveredFromCorruption);
            Assert.Null(result.CorruptFilePath);
            Assert.Single(result.Data.Tasks);
            Assert.Equal(task.Id, result.Data.Tasks[0].Id);
            Assert.False(result.Data.Settings.AlwaysOnTop);
            Assert.Equal("SevenDays", result.Data.Settings.StatisticsScope);
            Assert.True(result.Data.WindowPlacement.IsMaximized);
            Assert.Equal(TimeSpan.FromSeconds(5), Assert.Single(result.Data.WorkSegments).Duration);
            Assert.Equal(RotationEventType.ManualPaused, Assert.Single(result.Data.Events).Type);
            Assert.Equal(RotationState.PausedManual, result.Data.Checkpoint?.State);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void SecondSave_CreatesBackupOfPreviousGoodFile()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            var first = new TaskronomeData { Tasks = new List<TaskItem> { NewTask("First") } };
            store.Save(first);
            var original = File.ReadAllText(store.DataFilePath);

            var second = new TaskronomeData { Tasks = new List<TaskItem> { NewTask("Second") } };
            store.Save(second);

            Assert.True(File.Exists(store.BackupFilePath));
            Assert.Equal(original, File.ReadAllText(store.BackupFilePath));
            Assert.Equal("Second", Assert.Single(store.Load().Data.Tasks).Name);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void CorruptJson_IsPreservedAndReturnsFreshData()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            Directory.CreateDirectory(directory);
            File.WriteAllText(store.DataFilePath, "{ definitely not valid json");

            var result = store.Load();

            Assert.True(result.RecoveredFromCorruption);
            Assert.NotNull(result.CorruptFilePath);
            Assert.True(File.Exists(result.CorruptFilePath));
            Assert.False(File.Exists(store.DataFilePath));
            Assert.Empty(result.Data.Tasks);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void UnsupportedSchema_IsHandledAsCorruption()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            Directory.CreateDirectory(directory);
            File.WriteAllText(store.DataFilePath, "{\"SchemaVersion\":999}");

            var result = store.Load();

            Assert.True(result.RecoveredFromCorruption);
            Assert.Equal(TaskronomeData.CurrentSchemaVersion, result.Data.SchemaVersion);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void InvalidTaskInJson_IsHandledAsCorruption()
    {
        var directory = CreateTemporaryDirectory();
        try
        {
            var store = new JsonFileDataStore(directory);
            Directory.CreateDirectory(directory);
            File.WriteAllText(
                store.DataFilePath,
                "{\"SchemaVersion\":1,\"Tasks\":[{\"Name\":\"\",\"SliceDuration\":\"00:00:00\"}]}");

            var result = store.Load();

            Assert.True(result.RecoveredFromCorruption);
            Assert.Empty(result.Data.Tasks);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string CreateTemporaryDirectory()
    {
        return Path.Combine(Path.GetTempPath(), $"TaskronomeTests-{Guid.NewGuid():N}");
    }

    private static TaskItem NewTask(string name = "Persisted task")
    {
        return new TaskItem
        {
            Name = name,
            Notes = "notes",
            SliceDuration = TimeSpan.FromMinutes(20),
            Order = 0,
            CreatedAtUtc = DateTimeOffset.Parse("2026-09-03T00:00:00Z", CultureInfo.InvariantCulture),
            UpdatedAtUtc = DateTimeOffset.Parse("2026-09-03T00:00:00Z", CultureInfo.InvariantCulture),
        };
    }
}
