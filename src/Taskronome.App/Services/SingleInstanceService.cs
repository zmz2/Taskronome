using System.IO;
using System.IO.Pipes;
using System.Text;

namespace Taskronome.App.Services;

public sealed class SingleInstanceService : IDisposable
{
    private const string MutexName = "Local\\Taskronome-2C79E4E6-78DE-4E6D-B167-471906B81E50";
    private const string PipeName = "Taskronome-Activation-2C79E4E6-78DE-4E6D-B167-471906B81E50";

    private readonly FileLogger _logger;
    private readonly Mutex? _mutex;
    private readonly CancellationTokenSource _cancellation = new();
    private Task? _serverTask;
    private bool _disposed;

    public SingleInstanceService(FileLogger logger)
    {
        _logger = logger;
        try
        {
            _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
            IsFirstInstance = createdNew;
            if (!createdNew)
            {
                _mutex.Dispose();
                _mutex = null;
            }
        }
        catch (UnauthorizedAccessException exception)
        {
            _logger.LogError("Unable to create the per-user single-instance mutex.", exception);
            AcquisitionFailed = true;
            IsFirstInstance = false;
        }
    }

    public bool IsFirstInstance { get; }

    public bool AcquisitionFailed { get; }

    public void StartListening(Action activationAction)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(activationAction);
        if (!IsFirstInstance || _serverTask is not null)
        {
            return;
        }

        _serverTask = Task.Run(() => ListenAsync(activationAction, _cancellation.Token));
    }

    public static bool SignalExistingInstance()
    {
        try
        {
            using var client = new NamedPipeClientStream(
                ".",
                PipeName,
                PipeDirection.Out,
                PipeOptions.Asynchronous);
            client.Connect(timeout: 1000);
            using var writer = new StreamWriter(client, new UTF8Encoding(false), leaveOpen: false)
            {
                AutoFlush = true,
            };
            writer.WriteLine("SHOW");
            return true;
        }
        catch (Exception exception) when (exception is IOException or TimeoutException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task ListenAsync(Action activationAction, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(
                    PipeName,
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                using var reader = new StreamReader(server, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
                var command = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (TryParseCommand(command))
                {
                    activationAction();
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                _logger.LogError("Single-instance activation pipe failed; listener will retry.", exception);
                try
                {
                    await Task.Delay(250, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }

    public static bool TryParseCommand(string? command) =>
        string.Equals(command, "SHOW", StringComparison.Ordinal);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _cancellation.Cancel();
        try
        {
            _serverTask?.Wait(TimeSpan.FromSeconds(1));
        }
        catch (AggregateException)
        {
            // Cancellation-related shutdown failures are non-fatal.
        }

        _cancellation.Dispose();
        if (_mutex is not null)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // The mutex was not owned due to a startup race.
            }

            _mutex.Dispose();
        }
    }
}
