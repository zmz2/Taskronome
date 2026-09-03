using System.Globalization;

namespace Taskronome.App.Services;

public sealed class FileLogger
{
    private readonly object _gate = new();
    private readonly string _directoryPath;

    public FileLogger(string directoryPath)
    {
        _directoryPath = Path.GetFullPath(directoryPath);
    }

    public string DirectoryPath => _directoryPath;

    public void Info(string message) => Write("INFO", message, null);

    public void Warning(string message) => Write("WARN", message, null);

    public void Error(string message, Exception exception) => Write("ERROR", message, exception);

    private void Write(string level, string message, Exception? exception)
    {
        try
        {
            lock (_gate)
            {
                Directory.CreateDirectory(_directoryPath);
                var path = Path.Combine(
                    _directoryPath,
                    $"taskronome-{DateTimeOffset.Now:yyyyMMdd}.log");
                var line = string.Create(
                    CultureInfo.InvariantCulture,
                    $"{DateTimeOffset.Now:O} [{level}] {message}");
                if (exception is not null)
                {
                    line = $"{line}{Environment.NewLine}{exception}";
                }

                File.AppendAllText(path, $"{line}{Environment.NewLine}", new System.Text.UTF8Encoding(false));
            }
        }
        catch
        {
            // Logging must never terminate the desktop application.
        }
    }
}
