using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Taskronome.Core;

public sealed class TaskronomeSettings
{
    public bool AlwaysOnTop { get; set; } = true;

    public bool PlaySound { get; set; } = true;

    public bool MinimizeToTrayOnClose { get; set; } = true;

    public bool ShowNotification { get; set; } = true;

    public string StatisticsScope { get; set; } = "Today";
}

public sealed class WindowPlacementData
{
    public double Left { get; set; } = double.NaN;

    public double Top { get; set; } = double.NaN;

    public double Width { get; set; } = 1040;

    public double Height { get; set; } = 720;

    public bool IsMaximized { get; set; }
}

public sealed class TaskronomeData
{
    public const int CurrentSchemaVersion = 1;

    public int SchemaVersion { get; set; } = CurrentSchemaVersion;

    public TaskronomeSettings Settings { get; set; } = new();

    public WindowPlacementData WindowPlacement { get; set; } = new();

    public List<TaskItem> Tasks { get; set; } = new();

    public List<WorkSegment> WorkSegments { get; set; } = new();

    public List<RotationEvent> Events { get; set; } = new();

    public RotationCheckpoint? Checkpoint { get; set; }
}

public interface IStateStore
{
    string DirectoryPath { get; }

    string DataFilePath { get; }

    string BackupFilePath { get; }

    DataLoadResult Load();

    void Save(TaskronomeData data);
}

public sealed record DataLoadResult(
    TaskronomeData Data,
    bool RecoveredFromCorruption,
    string? CorruptFilePath,
    bool RecoveredFromBackup = false,
    string? CorruptBackupFilePath = null);

public sealed class JsonFileDataStore : IStateStore
{
    private static readonly ConcurrentDictionary<string, object> Gates = new(StringComparer.OrdinalIgnoreCase);
    private readonly JsonSerializerOptions _serializerOptions;
    private readonly object _gate;

    public JsonFileDataStore(string directoryPath)
    {
        if (string.IsNullOrWhiteSpace(directoryPath))
        {
            throw new ArgumentException("A storage directory is required.", nameof(directoryPath));
        }

        DirectoryPath = Path.GetFullPath(directoryPath);
        DataFilePath = Path.Combine(DirectoryPath, "data.json");
        BackupFilePath = Path.Combine(DirectoryPath, "data.json.bak");
        _gate = Gates.GetOrAdd(DirectoryPath, static _ => new object());
        _serializerOptions = CreateSerializerOptions();
    }

    public string DirectoryPath { get; }

    public string DataFilePath { get; }

    public string BackupFilePath { get; }

    public DataLoadResult Load()
    {
        lock (_gate)
        {
            Directory.CreateDirectory(DirectoryPath);
            if (!File.Exists(DataFilePath))
            {
                if (File.Exists(BackupFilePath))
                {
                    try
                    {
                        var backupData = ReadAndNormalizeLocked(BackupFilePath);
                        RestoreBackupAsMainLocked();
                        return new DataLoadResult(backupData, true, null, true, null);
                    }
                    catch (Exception backupException) when (backupException is JsonException or InvalidDataException)
                    {
                        var corruptBackupPath = PreserveCorruptFileLocked(BackupFilePath, isBackup: true);
                        return new DataLoadResult(new TaskronomeData(), true, null, false, corruptBackupPath);
                    }
                }

                return new DataLoadResult(new TaskronomeData(), false, null);
            }

            try
            {
                return new DataLoadResult(ReadAndNormalizeLocked(DataFilePath), false, null);
            }
            catch (Exception parseException) when (parseException is JsonException or InvalidDataException)
            {
                var corruptPath = PreserveCorruptFileLocked(DataFilePath, isBackup: false);
                if (!File.Exists(BackupFilePath))
                {
                    return new DataLoadResult(new TaskronomeData(), true, corruptPath);
                }

                try
                {
                    var backupData = ReadAndNormalizeLocked(BackupFilePath);
                    RestoreBackupAsMainLocked();
                    return new DataLoadResult(backupData, true, corruptPath, true, null);
                }
                catch (Exception backupException) when (backupException is JsonException or InvalidDataException)
                {
                    var corruptBackupPath = PreserveCorruptFileLocked(BackupFilePath, isBackup: true);
                    return new DataLoadResult(new TaskronomeData(), true, corruptPath, false, corruptBackupPath);
                }
            }
        }
    }

    public void Save(TaskronomeData data)
    {
        ArgumentNullException.ThrowIfNull(data);

        lock (_gate)
        {
            Normalize(data);
            Directory.CreateDirectory(DirectoryPath);
            var temporaryPath = Path.Combine(DirectoryPath, $"data.{Guid.NewGuid():N}.tmp");

            try
            {
                var json = JsonSerializer.Serialize(data, _serializerOptions);
                using (var stream = new FileStream(
                           temporaryPath,
                           FileMode.CreateNew,
                           FileAccess.Write,
                           FileShare.None,
                           bufferSize: 16 * 1024,
                           FileOptions.WriteThrough))
                using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
                {
                    writer.Write(json);
                    writer.Flush();
                    stream.Flush(flushToDisk: true);
                }

                if (File.Exists(DataFilePath))
                {
                    // Keep the last known-good document before replacing the live file. The
                    // replacement itself is performed by the platform atomic replace API.
                    File.Copy(DataFilePath, BackupFilePath, overwrite: true);
                    File.Replace(temporaryPath, DataFilePath, destinationBackupFileName: null, ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(temporaryPath, DataFilePath, overwrite: false);
                }
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }
    }

    private TaskronomeData ReadAndNormalizeLocked(string path)
    {
        // Keep file-system failures outside the corruption handler. A permission or
        // transient I/O failure is not evidence that the user's JSON is malformed.
        var json = File.ReadAllText(path);
        var data = JsonSerializer.Deserialize<TaskronomeData>(json, _serializerOptions)
                   ?? throw new InvalidDataException("The data file contained no object.");
        Normalize(data);
        return data;
    }

    private void RestoreBackupAsMainLocked()
    {
        // The backup remains in place as the recovery source for a subsequent failure.
        // Copying is deliberately best-effort only after a valid backup has been read;
        // failure is propagated as I/O rather than being mislabeled as corruption.
        File.Copy(BackupFilePath, DataFilePath, overwrite: true);
    }

    private string PreserveCorruptFileLocked(string sourcePath, bool isBackup)
    {
        if (!File.Exists(sourcePath))
        {
            throw new FileNotFoundException("The corrupt file disappeared before it could be preserved.", sourcePath);
        }

        var timestamp = DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss-fff", System.Globalization.CultureInfo.InvariantCulture);
        var prefix = isBackup ? "data.bak.corrupt" : "data.corrupt";
        var corruptPath = Path.Combine(DirectoryPath, $"{prefix}-{timestamp}-{Guid.NewGuid():N}.json");
        try
        {
            File.Move(sourcePath, corruptPath, overwrite: false);
            return corruptPath;
        }
        catch (IOException)
        {
            // If a move is unavailable (for example, because another process has the
            // file open), preserve a forensic copy but never delete the user's source.
            File.Copy(sourcePath, corruptPath, overwrite: false);
            return corruptPath;
        }
    }

    private static void Normalize(TaskronomeData data)
    {
        if (data.SchemaVersion is < 1 or > TaskronomeData.CurrentSchemaVersion)
        {
            throw new InvalidDataException($"Unsupported data schema version: {data.SchemaVersion}.");
        }

        data.Settings ??= new TaskronomeSettings();
        data.WindowPlacement ??= new WindowPlacementData();
        data.Tasks ??= new List<TaskItem>();
        data.WorkSegments ??= new List<WorkSegment>();
        data.Events ??= new List<RotationEvent>();

        if (data.Tasks.Any(task => task is null))
        {
            throw new InvalidDataException("The data file contained a null task.");
        }

        var duplicateTask = data.Tasks.GroupBy(task => task.Id).FirstOrDefault(group => group.Count() > 1);
        if (duplicateTask is not null)
        {
            throw new InvalidDataException($"Duplicate task id in data file: {duplicateTask.Key}.");
        }

        foreach (var task in data.Tasks)
        {
            var validation = TaskValidator.Validate(task.Name, task.Notes, task.SliceDuration);
            if (!validation.IsValid)
            {
                throw new InvalidDataException($"Invalid task '{task.Id}': {string.Join(" ", validation.Errors)}");
            }

            task.Name = task.Name.Trim();
        }

        foreach (var segment in data.WorkSegments)
        {
            if (!IsValidWorkSegment(segment))
            {
                throw new InvalidDataException("The data file contained an invalid work segment.");
            }
        }

        foreach (var item in data.Events)
        {
            if (item is null || !Enum.IsDefined(item.Type))
            {
                throw new InvalidDataException("The data file contained an invalid rotation event.");
            }
        }

        if (data.Checkpoint is not null)
        {
            if (data.Checkpoint.SchemaVersion is < 1 or > 1 ||
                !Enum.IsDefined(data.Checkpoint.State) ||
                (data.Checkpoint.StateBeforeSystemPause is not null &&
                 !Enum.IsDefined(data.Checkpoint.StateBeforeSystemPause.Value)) ||
                (data.Checkpoint.SystemPauseReason is not null &&
                 !Enum.IsDefined(data.Checkpoint.SystemPauseReason.Value)) ||
                data.Checkpoint.Remaining < TimeSpan.Zero ||
                data.Checkpoint.CurrentRunAccumulated < TimeSpan.Zero)
            {
                throw new InvalidDataException("The data file contained an invalid rotation checkpoint.");
            }

            var checkpointTask = data.Tasks.FirstOrDefault(task => task.Id == data.Checkpoint.CurrentTaskId);
            if (checkpointTask is not null &&
                (data.Checkpoint.Remaining > checkpointTask.SliceDuration ||
                 data.Checkpoint.CurrentRunAccumulated > checkpointTask.SliceDuration))
            {
                throw new InvalidDataException("The data file contained a checkpoint beyond the current slice.");
            }
        }

        data.SchemaVersion = TaskronomeData.CurrentSchemaVersion;
    }

    private static bool IsValidWorkSegment(WorkSegment? segment)
    {
        if (segment is null ||
            !Enum.IsDefined(segment.EndReason) ||
            segment.Duration < TimeSpan.Zero ||
            segment.EndedAtUtc < segment.StartedAtUtc)
        {
            return false;
        }

        try
        {
            return segment.Duration <= segment.EndedAtUtc - segment.StartedAtUtc;
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }
    }

    private static JsonSerializerOptions CreateSerializerOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            WriteIndented = true,
            AllowTrailingCommas = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }
}
