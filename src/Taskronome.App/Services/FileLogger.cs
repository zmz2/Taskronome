using System.Globalization;

using System.IO;

namespace Taskronome.App.Services;

public interface IAppLogger
{
    void Info(string message);

    void Warning(string message);

    void LogError(string message, Exception exception);
}

public sealed class FileLogger : IAppLogger
{
    private const long MaximumLogBytes = 1024 * 1024;
    private const int MaximumRolledFiles = 3;
    private readonly object _gate = new();
    private readonly string _directoryPath;

    public FileLogger(string directoryPath)
    {
        _directoryPath = Path.GetFullPath(directoryPath);
    }

    public string DirectoryPath => _directoryPath;

    public void Info(string message) => Write("INFO", message, null);

    public void Warning(string message) => Write("WARN", message, null);

    public void LogError(string message, Exception exception) => Write("ERROR", message, exception);

    private void Write(string level, string message, Exception? exception)
    {
        try
        {
            lock (_gate)
            {
                Directory.CreateDirectory(_directoryPath);
                var path = Path.Combine(
                    _directoryPath,
                    $"taskronome-{DateTimeOffset.UtcNow:yyyyMMdd}.log");
                var line = string.Create(
                    CultureInfo.InvariantCulture,
                    $"{DateTimeOffset.UtcNow:O} [{level}] {Sanitize(message)}");
                if (exception is not null)
                {
                    line = $"{line} exception={Sanitize(exception.ToString())}";
                }

                RollIfNeeded(path);
                File.AppendAllText(path, $"{line}{Environment.NewLine}", new System.Text.UTF8Encoding(false));
            }
        }
        catch
        {
            // Logging must never terminate the desktop application.
        }
    }

    private static string Sanitize(string value)
    {
        return value
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal);
    }

    private static void RollIfNeeded(string path)
    {
        if (!File.Exists(path) || new FileInfo(path).Length < MaximumLogBytes)
        {
            return;
        }

        for (var index = MaximumRolledFiles - 1; index >= 1; index--)
        {
            var source = $"{path}.{index}";
            var destination = $"{path}.{index + 1}";
            if (File.Exists(source))
            {
                File.Move(source, destination, overwrite: true);
            }
        }

        File.Move(path, $"{path}.1", overwrite: true);
    }
}
