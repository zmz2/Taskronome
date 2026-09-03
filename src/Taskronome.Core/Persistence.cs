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

public sealed record DataLoadResult(
    TaskronomeData Data,
    bool RecoveredFromCorruption,
    string? CorruptFilePath);

public sealed class JsonFileDataStore
{
    private readonly object _gate = new();
    private readonly JsonSerializerOptions _serializerOptions;

    public JsonFileDataStore(string directoryPath)
    {
        if (string.IsNullOrWhiteSpace(directoryPath))
        {
            throw new ArgumentException("A storage directory is required.", nameof(directoryPath));
        }

        DirectoryPath = Path.GetFullPath(directoryPath);
        DataFilePath = Path.Combine(DirectoryPath, "data.json");
        BackupFilePath = Path.Combine(DirectoryPath, "data.json.bak");
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
                return new DataLoadResult(new TaskronomeData(), false, null);
            }

            try
            {
                var json = File.ReadAllText(DataFilePath);
                var data = JsonSerializer.Deserialize<TaskronomeData>(json, _serializerOptions)
                           ?? throw new InvalidDataException("The data file contained no object.");
                Normalize(data);
                return new DataLoadResult(data, false, null);
            }
            catch (Exception exception) when (exception is JsonException or IOException or InvalidDataException or UnauthorizedAccessException)
            {
                var corruptPath = PreserveCorruptFileLocked();
                return new DataLoadResult(new TaskronomeData(), true, corruptPath);
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
                    File.Copy(DataFilePath, BackupFilePath, overwrite: true);
                }

                File.Move(temporaryPath, DataFilePath, overwrite: true);
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

    private string? PreserveCorruptFileLocked()
    {
        if (!File.Exists(DataFilePath))
        {
            return null;
        }

        var timestamp = DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss-fff", System.Globalization.CultureInfo.InvariantCulture);
        var corruptPath = Path.Combine(DirectoryPath, $"data.corrupt-{timestamp}.json");
        try
        {
            File.Move(DataFilePath, corruptPath, overwrite: false);
            return corruptPath;
        }
        catch (IOException)
        {
            File.Copy(DataFilePath, corruptPath, overwrite: true);
            File.Delete(DataFilePath);
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

        data.SchemaVersion = TaskronomeData.CurrentSchemaVersion;
    }

    private static JsonSerializerOptions CreateSerializerOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            WriteIndented = true,
            AllowTrailingCommas = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }
}
