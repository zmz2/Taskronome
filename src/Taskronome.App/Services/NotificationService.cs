using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Taskronome.App.Services;

public interface INotificationService : IDisposable
{
    event EventHandler? ActivationRequested;

    bool IsAvailable { get; }

    string LastError { get; }

    bool Initialize();

    bool ShowTaskTurn(string taskName);

    bool ShowTestNotification();
}

public sealed class NotificationService : INotificationService
{
    private readonly FileLogger _logger;
    private readonly bool _dryRun;
    private bool _registered;
    private bool _disposed;

    public NotificationService(FileLogger logger, bool dryRun = false)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _dryRun = dryRun;
    }

    public event EventHandler? ActivationRequested;

    public bool IsAvailable => _registered;

    public string LastError { get; private set; } = string.Empty;

    public bool Initialize()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_registered)
        {
            return true;
        }

        if (_dryRun)
        {
            _registered = true;
            LastError = string.Empty;
            _logger.Info("Windows App SDK notification service dry-run initialized.");
            return true;
        }

        try
        {
            AppNotificationManager.Default.NotificationInvoked += OnNotificationInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
            LastError = string.Empty;
            _logger.Info("Windows App SDK notification service registered.");
            return true;
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
            _logger.LogError("Windows App SDK notification registration failed; in-app and tray fallbacks remain active.", exception);
            try
            {
                AppNotificationManager.Default.NotificationInvoked -= OnNotificationInvoked;
            }
            catch (Exception unsubscribeException)
            {
                _logger.LogError("Notification event cleanup failed after registration error.", unsubscribeException);
            }

            return false;
        }
    }

    public bool ShowTaskTurn(string taskName)
    {
        return Show(
            $"轮到：{taskName}",
            "请在 10 秒内回到 Taskronome 并点击“开始任务”，否则轮转将暂停。",
            "task-turn");
    }

    public bool ShowTestNotification()
    {
        return Show(
            "Taskronome 测试通知",
            "系统通知通道工作正常。点击通知只会激活应用，不会确认任务。",
            "test");
    }

    private bool Show(string title, string body, string kind)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!_registered)
        {
            LastError = "通知服务尚未注册。";
            return false;
        }

        try
        {
            var setting = AppNotificationManager.Default.Setting;
            if (setting != AppNotificationSetting.Enabled)
            {
                LastError = $"Windows App SDK notification setting is {setting}.";
                _logger.Warning($"Windows app notification unavailable ({setting}); in-app and tray fallbacks remain active.");
                return false;
            }

            var notification = new AppNotificationBuilder()
                .AddArgument("action", "activate")
                .AddArgument("kind", kind)
                .AddText(title)
                .AddText(body)
                .BuildNotification();

            if (_dryRun)
            {
                LastError = string.Empty;
                _logger.Info($"Notification dry-run payload built: {title}");
                return true;
            }

            AppNotificationManager.Default.Show(notification);
            LastError = string.Empty;
            return true;
        }
        catch (Exception exception)
        {
            LastError = exception.Message;
            _logger.LogError("Sending a Windows app notification failed.", exception);
            return false;
        }
    }

    private void OnNotificationInvoked(
        AppNotificationManager sender,
        AppNotificationActivatedEventArgs args)
    {
        _logger.Info($"Notification activated with arguments: {args.Argument}");
        ActivationRequested?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_registered && !_dryRun)
        {
            try
            {
                AppNotificationManager.Default.NotificationInvoked -= OnNotificationInvoked;
                AppNotificationManager.Default.Unregister();
                _logger.Info("Windows App SDK notification service unregistered.");
            }
            catch (Exception exception)
            {
                _logger.LogError("Windows App SDK notification cleanup failed.", exception);
            }
        }

        _registered = false;
    }
}
