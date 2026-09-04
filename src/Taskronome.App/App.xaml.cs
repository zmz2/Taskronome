using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Windows.AppNotifications;
using Taskronome.App.Services;
using Taskronome.App.ViewModels;
using Taskronome.Core;
using WpfMessageBox = System.Windows.MessageBox;

namespace Taskronome.App;

public partial class App : System.Windows.Application, IDisposable
{
    private static readonly JsonSerializerOptions SmokeResultSerializerOptions = new() { WriteIndented = true };
    private FileLogger? _logger;
    private JsonFileDataStore? _dataStore;
    private SingleInstanceService? _singleInstance;
    private NotificationService? _notificationService;
    private MainWindowViewModel? _viewModel;
    private MainWindow? _mainWindow;
    private DispatcherTimer? _smokeTimeout;
    private DispatcherTimer? _acceptanceNotificationProbe;
    private bool _smokeTestMode;
    private bool _testMode;
    private bool _notificationDryRun;
    private bool _deleteSmokeData;
    private int _smokeHoldMilliseconds;
    private string? _smokeResultPath;
    private string? _dataDirectory;
    private string? _acceptanceReadOnlyToken;
    private string? _acceptanceReadOnlyOutputPath;
    private bool _acceptanceNotificationProbeBusy;
    private DateTimeOffset _acceptanceNotificationProbeNextAttemptUtc;
    private bool _exitRequested;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        StartupOptions startupOptions;
        try
        {
            startupOptions = StartupOptions.Parse(e.Args);
        }
        catch (ArgumentException exception)
        {
            WpfMessageBox.Show(
                $"Taskronome 启动参数无效：{exception.Message}",
                "Taskronome",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        _smokeTestMode = startupOptions.UiSmoke;
        _testMode = startupOptions.TestMode;
        _notificationDryRun = startupOptions.NotificationDryRun;
        _dataDirectory = startupOptions.DataDirectory;
        _smokeResultPath = startupOptions.SmokeResultPath;
        _smokeHoldMilliseconds = startupOptions.SmokeHoldMilliseconds;
        _deleteSmokeData = _smokeTestMode && _dataDirectory is null;
        _acceptanceReadOnlyToken = startupOptions.AcceptanceReadOnlyToken;
        _acceptanceReadOnlyOutputPath = startupOptions.AcceptanceReadOnlyOutputPath;

        if (_acceptanceReadOnlyToken is not null && (_testMode || _notificationDryRun))
        {
            throw new ArgumentException("--acceptance-read-only 只能与真实生产通知服务一起使用。", nameof(e));
        }

        var rootDirectory = _dataDirectory ?? (_smokeTestMode
            ? Path.Combine(Path.GetTempPath(), $"Taskronome-Smoke-{Guid.NewGuid():N}")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Taskronome"));
        if (_smokeTestMode && string.IsNullOrWhiteSpace(_smokeResultPath))
        {
            _smokeResultPath = Path.Combine(Path.GetTempPath(), $"Taskronome-UI-Smoke-{Guid.NewGuid():N}.json");
        }
        _logger = new FileLogger(Path.Combine(rootDirectory, "logs"));
        _dataStore = new JsonFileDataStore(rootDirectory);

        DispatcherUnhandledException += App_DispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;
        TaskScheduler.UnobservedTaskException += TaskScheduler_UnobservedTaskException;

        try
        {
            var singleInstance = new SingleInstanceService(_logger);
            _singleInstance = singleInstance;
            if (singleInstance.AcquisitionFailed)
            {
                throw new InvalidOperationException("无法安全获取 Taskronome 单实例锁；为避免产生第二套计时器，应用不会继续启动。");
            }

            if (!singleInstance.IsFirstInstance)
            {
                _ = SingleInstanceService.SignalExistingInstance();
                Shutdown(0);
                return;
            }

            _notificationService = new NotificationService(_logger, _notificationDryRun);
            _notificationService.Initialize();
            var rotationOptions = _testMode
                ? new RotationOptions
                {
                    ConfirmationTimeout = TimeSpan.FromSeconds(2),
                    HeartbeatGapThreshold = TimeSpan.FromSeconds(5),
                }
                : null;
            _viewModel = new MainWindowViewModel(_dataStore, _logger, rotationOptions: rotationOptions);
            _mainWindow = new MainWindow(
                _viewModel,
                _notificationService,
                _smokeTestMode,
                _testMode,
                _smokeHoldMilliseconds);
            MainWindow = _mainWindow;

            singleInstance.StartListening(() =>
            {
                Dispatcher.InvokeAsync(() => _mainWindow?.ActivateFromExternalRequest());
            });

            _mainWindow.Show();

            if (_acceptanceReadOnlyOutputPath is not null)
            {
                _acceptanceNotificationProbe = new DispatcherTimer
                {
                    Interval = TimeSpan.FromMilliseconds(750),
                };
                _acceptanceNotificationProbe.Tick += AcceptanceNotificationProbe_Tick;
                _acceptanceNotificationProbeNextAttemptUtc = DateTimeOffset.UtcNow.AddSeconds(2);
                _acceptanceNotificationProbe.Start();
                _ = WriteAcceptanceNotificationEvidenceAsync();
            }

            if (_smokeTestMode)
            {
                _smokeTimeout = new DispatcherTimer
                {
                    Interval = TimeSpan.FromSeconds(15),
                };
                _smokeTimeout.Tick += (_, _) =>
                {
                    _logger.Warning("UI smoke test timed out before ContentRendered completed.");
                    CompleteSmokeTest(2);
                };
                _smokeTimeout.Start();
            }
        }
        catch (Exception exception)
        {
            _logger.LogError("Application startup failed.", exception);
            if (_smokeTestMode)
            {
                WriteSmokeResult(1, exception.Message);
            }
            if (!_smokeTestMode)
            {
                WpfMessageBox.Show(
                    $"Taskronome 启动失败：{exception.Message}\n\n日志目录：{_logger.DirectoryPath}",
                    "Taskronome",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }

            Shutdown(1);
        }
    }

    public void RequestExit()
    {
        if (_exitRequested)
        {
            return;
        }

        if (!_smokeTestMode && _viewModel?.IsActiveRotation == true)
        {
            var result = WpfMessageBox.Show(
                _mainWindow,
                "当前轮转仍在进行。退出前会安全暂停并保存，离线时间不会被计入。确定退出吗？",
                "退出 Taskronome",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question,
                MessageBoxResult.No);
            if (result != MessageBoxResult.Yes)
            {
                return;
            }
        }

        RequestExitCore(0);
    }

    public void CompleteSmokeTest(int exitCode)
    {
        if (!_smokeTestMode || _exitRequested)
        {
            return;
        }

        WriteSmokeResult(exitCode, exitCode == 0 ? null : "UI smoke assertions failed.");
        RequestExitCore(exitCode);
    }

    public void HandleRecoverableUiException(string message, Exception exception)
    {
        _logger?.LogError(message, exception);
        if (!_smokeTestMode)
        {
            WpfMessageBox.Show(
                _mainWindow,
                $"{message}\n\n{exception.Message}\n\n应用已尽力保持当前数据，请查看日志。",
                "Taskronome",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void RequestExitCore(int exitCode)
    {
        if (_exitRequested)
        {
            return;
        }

        _exitRequested = true;
        _smokeTimeout?.Stop();
        _acceptanceNotificationProbe?.Stop();
        if (_acceptanceNotificationProbe is not null)
        {
            _acceptanceNotificationProbe.Tick -= AcceptanceNotificationProbe_Tick;
        }
        if (_mainWindow is not null)
        {
            _viewModel?.UpdateWindowPlacement(WindowPlacementService.Capture(_mainWindow));
        }

        _viewModel?.PrepareForExit();
        _mainWindow?.ForceClose();
        Shutdown(exitCode);
    }

    private void WriteSmokeResult(int exitCode, string? error)
    {
        if (!_smokeTestMode || string.IsNullOrWhiteSpace(_smokeResultPath))
        {
            return;
        }

        try
        {
            var result = new
            {
                result = exitCode == 0 ? "passed" : "failed",
                exitCode,
                testMode = _testMode,
                notificationDryRun = _notificationDryRun,
                dataDirectory = _dataStore?.DirectoryPath,
                error,
                generatedUtc = DateTimeOffset.UtcNow,
            };
            var parent = Path.GetDirectoryName(_smokeResultPath);
            if (!string.IsNullOrWhiteSpace(parent))
            {
                Directory.CreateDirectory(parent);
            }

            File.WriteAllText(
                _smokeResultPath,
                JsonSerializer.Serialize(result, SmokeResultSerializerOptions),
                new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _logger?.LogError("Unable to write the UI smoke result.", exception);
        }
    }

    private void App_DispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        _logger?.LogError("Unhandled UI exception.", e.Exception);
        if (_smokeTestMode)
        {
            e.Handled = true;
            CompleteSmokeTest(3);
            return;
        }

        WpfMessageBox.Show(
            _mainWindow,
            $"发生未处理错误：{e.Exception.Message}\n\n应用将保存并退出。",
            "Taskronome",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
        RequestExitCore(1);
    }

    private void CurrentDomain_UnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception exception)
        {
            _logger?.LogError("Unhandled process exception.", exception);
        }
    }

    private void TaskScheduler_UnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        _logger?.LogError("Unobserved task exception.", e.Exception);
        e.SetObserved();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _smokeTimeout?.Stop();
        _acceptanceNotificationProbe?.Stop();
        if (_acceptanceNotificationProbe is not null)
        {
            _acceptanceNotificationProbe.Tick -= AcceptanceNotificationProbe_Tick;
        }
        _viewModel?.PrepareForExit();
        _viewModel?.Dispose();
        _notificationService?.Dispose();
        _singleInstance?.Dispose();

        DispatcherUnhandledException -= App_DispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException -= CurrentDomain_UnhandledException;
        TaskScheduler.UnobservedTaskException -= TaskScheduler_UnobservedTaskException;

        if (_deleteSmokeData && _dataStore is not null)
        {
            try
            {
                Directory.Delete(_dataStore.DirectoryPath, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                _logger?.LogError("Unable to remove the temporary smoke-test directory.", exception);
            }
        }

        base.OnExit(e);
    }

    public void Dispose()
    {
        _smokeTimeout?.Stop();
        _acceptanceNotificationProbe?.Stop();
        if (_acceptanceNotificationProbe is not null)
        {
            _acceptanceNotificationProbe.Tick -= AcceptanceNotificationProbe_Tick;
        }
        _viewModel?.Dispose();
        _notificationService?.Dispose();
        _singleInstance?.Dispose();
        GC.SuppressFinalize(this);
    }

    private void AcceptanceNotificationProbe_Tick(object? sender, EventArgs e)
    {
        _ = WriteAcceptanceNotificationEvidenceAsync();
    }

    private async Task WriteAcceptanceNotificationEvidenceAsync()
    {
        if (_acceptanceNotificationProbeBusy || DateTimeOffset.UtcNow < _acceptanceNotificationProbeNextAttemptUtc || string.IsNullOrWhiteSpace(_acceptanceReadOnlyToken) ||
            string.IsNullOrWhiteSpace(_acceptanceReadOnlyOutputPath))
        {
            return;
        }

        _acceptanceNotificationProbeBusy = true;
        _acceptanceNotificationProbeNextAttemptUtc = DateTimeOffset.UtcNow.AddSeconds(20);
        try
        {
            var manager = AppNotificationManager.Default;
            var isSupported = AppNotificationManager.IsSupported();
            var setting = manager.Setting;
            WriteAcceptanceNotificationEvidence(new
            {
                SchemaVersion = 1,
                Source = "Taskronome application process",
                ReadOnly = true,
                TokenSha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_acceptanceReadOnlyToken))).ToLowerInvariant(),
                IsSupported = isSupported,
                Setting = setting.ToString(),
                GetAllAsync = new
                {
                    Succeeded = false,
                    Pending = true,
                    Count = 0,
                    Notifications = Array.Empty<object>(),
                },
                GeneratedUtc = DateTimeOffset.UtcNow,
            });
            var operation = manager.GetAllAsync();
            var notificationsTask = System.WindowsRuntimeSystemExtensions.AsTask(operation);
            var notifications = await notificationsTask;
            var notificationRecords = new List<object>();
            foreach (var notification in notifications)
            {
                notificationRecords.Add(new
                {
                    notification.Id,
                    notification.Tag,
                    notification.Group,
                    notification.Payload,
                });
            }

            var evidence = new
            {
                SchemaVersion = 1,
                Source = "Taskronome application process",
                ReadOnly = true,
                TokenSha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_acceptanceReadOnlyToken))).ToLowerInvariant(),
                IsSupported = isSupported,
                Setting = setting.ToString(),
                GetAllAsync = new
                {
                    Succeeded = true,
                    Count = notificationRecords.Count,
                    Notifications = notificationRecords,
                },
                GeneratedUtc = DateTimeOffset.UtcNow,
            };

            WriteAcceptanceNotificationEvidence(evidence);
        }
        catch (Exception exception)
        {
            var evidence = new
            {
                SchemaVersion = 1,
                Source = "Taskronome application process",
                ReadOnly = true,
                TokenSha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_acceptanceReadOnlyToken))).ToLowerInvariant(),
                IsSupported = (bool?)null,
                Setting = "Unavailable",
                GetAllAsync = new
                {
                    Succeeded = false,
                    Count = 0,
                    Notifications = Array.Empty<object>(),
                },
                Error = exception.Message,
                GeneratedUtc = DateTimeOffset.UtcNow,
            };

            WriteAcceptanceNotificationEvidence(evidence);
        }
        finally
        {
            _acceptanceNotificationProbeBusy = false;
        }
    }

    private void WriteAcceptanceNotificationEvidence(object evidence)
    {
        try
        {
            var parent = Path.GetDirectoryName(_acceptanceReadOnlyOutputPath);
            if (!string.IsNullOrWhiteSpace(parent))
            {
                Directory.CreateDirectory(parent);
            }

            File.WriteAllText(
                _acceptanceReadOnlyOutputPath!,
                JsonSerializer.Serialize(evidence, SmokeResultSerializerOptions),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _logger?.LogError("Unable to write the acceptance notification evidence.", exception);
        }
    }

    private sealed record StartupOptions(
        bool UiSmoke,
        bool TestMode,
        bool NotificationDryRun,
        string? DataDirectory,
        string? SmokeResultPath,
        int SmokeHoldMilliseconds,
        string? AcceptanceReadOnlyToken,
        string? AcceptanceReadOnlyOutputPath)
    {
        public static StartupOptions Parse(string[] args)
        {
            ArgumentNullException.ThrowIfNull(args);
            var uiSmoke = false;
            var testMode = false;
            var notificationDryRun = false;
            string? dataDirectory = null;
            string? smokeResultPath = null;
            var smokeHoldMilliseconds = 0;
            string? acceptanceReadOnlyToken = null;
            string? acceptanceReadOnlyOutputPath = null;

            for (var index = 0; index < args.Length; index++)
            {
                switch (args[index].ToLowerInvariant())
                {
                    case "--smoke-test":
                    case "--ui-smoke":
                        uiSmoke = true;
                        break;
                    case "--test-mode":
                        testMode = true;
                        break;
                    case "--notification-dry-run":
                        notificationDryRun = true;
                        break;
                    case "--data-dir":
                        dataDirectory = ReadPathArgument(args, ref index, "--data-dir");
                        break;
                    case "--smoke-result":
                        smokeResultPath = ReadPathArgument(args, ref index, "--smoke-result");
                        break;
                    case "--smoke-hold-ms":
                        smokeHoldMilliseconds = ReadIntegerArgument(args, ref index, "--smoke-hold-ms", 0, 30000);
                        break;
                    case "--acceptance-read-only":
                        acceptanceReadOnlyToken = ReadGuidArgument(args, ref index, "--acceptance-read-only");
                        acceptanceReadOnlyOutputPath = ReadPathArgument(args, ref index, "--acceptance-read-only");
                        break;
                    default:
                        throw new ArgumentException($"未知启动参数：{args[index]}", nameof(args));
                }
            }

            return new StartupOptions(
                uiSmoke,
                testMode,
                notificationDryRun,
                dataDirectory,
                smokeResultPath,
                smokeHoldMilliseconds,
                acceptanceReadOnlyToken,
                acceptanceReadOnlyOutputPath);
        }

        private static string ReadGuidArgument(string[] args, ref int index, string option)
        {
            if (index + 1 >= args.Length || !Guid.TryParse(args[++index], out var value))
            {
                throw new ArgumentException($"启动参数 {option} 需要一个 GUID 只读令牌。", nameof(args));
            }

            return value.ToString("D");
        }

        private static string ReadPathArgument(string[] args, ref int index, string option)
        {
            if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[++index]))
            {
                throw new ArgumentException($"启动参数 {option} 需要一个路径。", nameof(args));
            }

            return Path.GetFullPath(args[index]);
        }

        private static int ReadIntegerArgument(string[] args, ref int index, string option, int minimum, int maximum)
        {
            if (index + 1 >= args.Length ||
                !int.TryParse(args[++index], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var value) ||
                value < minimum ||
                value > maximum)
            {
                throw new ArgumentException($"启动参数 {option} 必须是 {minimum}–{maximum} 之间的整数。", nameof(args));
            }

            return value;
        }
    }
}
