using System.Windows;
using System.Windows.Threading;
using Taskronome.App.Services;
using Taskronome.App.ViewModels;
using Taskronome.Core;

namespace Taskronome.App;

public partial class App : Application
{
    private FileLogger? _logger;
    private JsonFileDataStore? _dataStore;
    private SingleInstanceService? _singleInstance;
    private NotificationService? _notificationService;
    private MainWindowViewModel? _viewModel;
    private MainWindow? _mainWindow;
    private DispatcherTimer? _smokeTimeout;
    private bool _smokeTestMode;
    private bool _exitRequested;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _smokeTestMode = e.Args.Any(argument => string.Equals(argument, "--smoke-test", StringComparison.OrdinalIgnoreCase));

        var rootDirectory = _smokeTestMode
            ? Path.Combine(Path.GetTempPath(), $"Taskronome-Smoke-{Guid.NewGuid():N}")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Taskronome");
        _logger = new FileLogger(Path.Combine(rootDirectory, "logs"));
        _dataStore = new JsonFileDataStore(rootDirectory);

        DispatcherUnhandledException += App_DispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;
        TaskScheduler.UnobservedTaskException += TaskScheduler_UnobservedTaskException;

        try
        {
            if (!_smokeTestMode)
            {
                _singleInstance = new SingleInstanceService(_logger);
                if (!_singleInstance.IsFirstInstance)
                {
                    _ = SingleInstanceService.SignalExistingInstance();
                    Shutdown(0);
                    return;
                }
            }

            _notificationService = new NotificationService(_logger);
            _notificationService.Initialize();
            _viewModel = new MainWindowViewModel(_dataStore, _logger);
            _mainWindow = new MainWindow(_viewModel, _notificationService, _smokeTestMode);
            MainWindow = _mainWindow;

            if (_singleInstance is not null)
            {
                _singleInstance.StartListening(() =>
                {
                    Dispatcher.InvokeAsync(() => _mainWindow?.ActivateFromExternalRequest());
                });
            }

            _mainWindow.Show();

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
            _logger.Error("Application startup failed.", exception);
            if (!_smokeTestMode)
            {
                MessageBox.Show(
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
            var result = MessageBox.Show(
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

        RequestExitCore(exitCode);
    }

    public void HandleRecoverableUiException(string message, Exception exception)
    {
        _logger?.Error(message, exception);
        if (!_smokeTestMode)
        {
            MessageBox.Show(
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
        if (_mainWindow is not null)
        {
            _viewModel?.UpdateWindowPlacement(WindowPlacementService.Capture(_mainWindow));
        }

        _viewModel?.PrepareForExit();
        _mainWindow?.ForceClose();
        Shutdown(exitCode);
    }

    private void App_DispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        _logger?.Error("Unhandled UI exception.", e.Exception);
        if (_smokeTestMode)
        {
            e.Handled = true;
            CompleteSmokeTest(3);
            return;
        }

        MessageBox.Show(
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
            _logger?.Error("Unhandled process exception.", exception);
        }
    }

    private void TaskScheduler_UnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        _logger?.Error("Unobserved task exception.", e.Exception);
        e.SetObserved();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _smokeTimeout?.Stop();
        _viewModel?.PrepareForExit();
        _viewModel?.Dispose();
        _notificationService?.Dispose();
        _singleInstance?.Dispose();

        DispatcherUnhandledException -= App_DispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException -= CurrentDomain_UnhandledException;
        TaskScheduler.UnobservedTaskException -= TaskScheduler_UnobservedTaskException;

        if (_smokeTestMode && _dataStore is not null)
        {
            try
            {
                Directory.Delete(_dataStore.DirectoryPath, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                _logger?.Error("Unable to remove the temporary smoke-test directory.", exception);
            }
        }

        base.OnExit(e);
    }
}
