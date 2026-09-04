using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using Taskronome.App.Services;
using Taskronome.App.ViewModels;
using Taskronome.Core;
using Forms = System.Windows.Forms;
using WpfApplication = System.Windows.Application;
using WpfMessageBox = System.Windows.MessageBox;
using WpfSaveFileDialog = Microsoft.Win32.SaveFileDialog;

namespace Taskronome.App;

public partial class MainWindow : Window, IDisposable
{
    private readonly MainWindowViewModel _viewModel;
    private readonly INotificationService _notificationService;
    private readonly DispatcherTimer _uiTimer;
    private readonly int _smokeHoldMilliseconds;
    private readonly bool _smokeTestMode;
    private readonly bool _testMode;
    private WindowsSessionMonitor? _sessionMonitor;
    private Forms.NotifyIcon? _trayIcon;
    private Forms.ContextMenuStrip? _trayMenu;
    private Forms.ToolStripMenuItem? _trayPauseItem;
    private Forms.ToolStripMenuItem? _trayTopmostItem;
    private System.Drawing.Icon? _ownedTrayIcon;
    private DispatcherTimer? _smokeCompletionTimer;
    private bool _forceClose;
    private bool _closeHintShown;
    private bool _disposed;
    private long _lastRotationInputTimestamp;

    public MainWindow(
        MainWindowViewModel viewModel,
        INotificationService notificationService,
        bool smokeTestMode = false,
        bool testMode = false,
        int smokeHoldMilliseconds = 0)
    {
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        _notificationService = notificationService ?? throw new ArgumentNullException(nameof(notificationService));
        _smokeTestMode = smokeTestMode;
        _testMode = testMode;
        _smokeHoldMilliseconds = smokeHoldMilliseconds;

        InitializeComponent();
        if (_testMode)
        {
            Title = "Taskronome · 测试模式";
        }
        DataContext = _viewModel;
        Topmost = _viewModel.AlwaysOnTop;
        WindowPlacementService.Apply(this, _viewModel.WindowPlacement);

        _viewModel.PresenceRequired += ViewModel_PresenceRequired;
        _viewModel.AlwaysOnTopChanged += ViewModel_AlwaysOnTopChanged;
        _viewModel.SettingsChanged += ViewModel_SettingsChanged;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _notificationService.ActivationRequested += NotificationService_ActivationRequested;

        _uiTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(250),
        };
        _uiTimer.Tick += UiTimer_Tick;
        _uiTimer.Start();

        if (_smokeTestMode)
        {
            ShowInTaskbar = false;
            ShowActivated = false;
            Opacity = 0;
            WindowStyle = WindowStyle.None;
            ContentRendered += SmokeTest_ContentRendered;
        }
        else
        {
            CreateTrayIcon();
        }
    }

    public void ActivateFromExternalRequest()
    {
        if (_disposed)
        {
            return;
        }

        WindowActivationService.BringToFront(this, _viewModel.CanConfirm ? ConfirmTaskButton : null);
    }

    public void ForceClose()
    {
        _forceClose = true;
        Close();
    }

    private void UiTimer_Tick(object? sender, EventArgs e)
    {
        try
        {
            _viewModel.Tick();
        }
        catch (Exception exception)
        {
            ((App)WpfApplication.Current).HandleRecoverableUiException("刷新计时状态失败。", exception);
        }
    }

    private void ViewModel_PresenceRequired(object? sender, PresenceRequiredEventArgs e)
    {
        if (_smokeTestMode)
        {
            return;
        }

        Dispatcher.Invoke(() =>
        {
            MainTabs.SelectedIndex = 1;
            WindowActivationService.BringToFront(this, ConfirmTaskButton);
            WindowActivationService.FlashTaskbar(this);

            if (_viewModel.PlaySound)
            {
                try
                {
                    SystemSounds.Exclamation.Play();
                }
                catch (InvalidOperationException)
                {
                    // A missing system sound must not interrupt the rotation.
                }
            }

            var notificationSent = !_viewModel.ShowNotification || _notificationService.ShowTaskTurn(e.TaskName);
            if (!notificationSent)
            {
                ShowTrayFallback(
                    $"轮到：{e.TaskName}",
                    "请在 10 秒内回到 Taskronome 并点击“开始任务”。");
            }
        });
    }

    private void ViewModel_AlwaysOnTopChanged(object? sender, EventArgs e)
    {
        Topmost = _viewModel.AlwaysOnTop;
        UpdateTrayMenu();
    }

    private void ViewModel_SettingsChanged(object? sender, EventArgs e)
    {
        UpdateTrayMenu();
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainWindowViewModel.State)
            or nameof(MainWindowViewModel.CanPauseResume)
            or nameof(MainWindowViewModel.PauseResumeText)
            or nameof(MainWindowViewModel.AlwaysOnTop)
            or "")
        {
            UpdateTrayMenu();
        }
    }

    private void NotificationService_ActivationRequested(object? sender, EventArgs e)
    {
        Dispatcher.InvokeAsync(ActivateFromExternalRequest);
    }

    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        _sessionMonitor = new WindowsSessionMonitor(
            this,
            reason =>
            {
                _viewModel.PauseForSystem(reason);
                UpdateTrayMenu();
            },
            () =>
            {
                _viewModel.NotifySystemReturned();
                if (_viewModel.IsSystemPaused)
                {
                    WindowActivationService.FlashTaskbar(this);
                }
            });
        _sessionMonitor.Attach();
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        _viewModel.UpdateWindowPlacement(WindowPlacementService.Capture(this));
        _viewModel.PersistNow(silent: true);

        if (_forceClose || _smokeTestMode)
        {
            return;
        }

        if (_viewModel.MinimizeToTrayOnClose)
        {
            e.Cancel = true;
            Hide();
            if (!_closeHintShown)
            {
                _closeHintShown = true;
                ShowTrayFallback("Taskronome 仍在运行", "双击托盘图标可重新显示窗口；轮转状态不会因隐藏窗口而停止。");
            }

            return;
        }

        e.Cancel = true;
        Dispatcher.InvokeAsync(() => ((App)WpfApplication.Current).RequestExit());
    }

    private void Window_Closed(object? sender, EventArgs e)
    {
        DisposeWindowResources();
    }

    private void NewTaskButton_Click(object sender, RoutedEventArgs e)
    {
        ShowTaskEditor(null, null);
    }

    private void EditTaskButton_Click(object sender, RoutedEventArgs e)
    {
        EditSelectedTask();
    }

    private void TaskGrid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (_viewModel.CanEditSelectedTask)
        {
            EditSelectedTask();
        }
    }

    private void EditSelectedTask()
    {
        var selected = _viewModel.SelectedTask;
        if (selected is null)
        {
            return;
        }

        var draft = _viewModel.GetTaskDraft(selected.Id);
        if (draft is not null)
        {
            ShowTaskEditor(draft, selected.Id);
        }
    }

    private void ShowTaskEditor(TaskDraft? draft, Guid? taskId)
    {
        if (!_viewModel.CanEditTasks)
        {
            return;
        }

        var editor = new TaskEditorWindow(draft, taskId)
        {
            Owner = this,
        };
        if (editor.ShowDialog() != true || editor.Result is null)
        {
            return;
        }

        if (taskId.HasValue)
        {
            _viewModel.UpdateTask(taskId.Value, editor.Result);
        }
        else
        {
            _viewModel.AddTask(editor.Result);
        }
    }

    private void DeleteTaskButton_Click(object sender, RoutedEventArgs e)
    {
        var selected = _viewModel.SelectedTask;
        if (selected is null)
        {
            return;
        }

        var result = WpfMessageBox.Show(
            this,
            $"确定删除任务“{selected.Name}”吗？已产生的历史统计仍会保留。",
            "删除任务",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (result == MessageBoxResult.Yes)
        {
            _viewModel.DeleteTask(selected.Id);
        }
    }

    private void MoveUpButton_Click(object sender, RoutedEventArgs e) => _viewModel.MoveSelected(-1);

    private void MoveDownButton_Click(object sender, RoutedEventArgs e) => _viewModel.MoveSelected(1);

    private void ToggleEnabledButton_Click(object sender, RoutedEventArgs e) => _viewModel.ToggleSelectedEnabled();

    private void ReopenTaskButton_Click(object sender, RoutedEventArgs e) => _viewModel.ReopenSelectedTask();

    private void ResetCompletionButton_Click(object sender, RoutedEventArgs e)
    {
        var result = WpfMessageBox.Show(
            this,
            "重置所有任务的完成状态？历史统计不会清除。",
            "重置完成状态",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question,
            MessageBoxResult.No);
        if (result == MessageBoxResult.Yes)
        {
            _viewModel.ResetAllCompleted();
        }
    }

    private void StartRotationButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.StartRotation())
        {
            MainTabs.SelectedIndex = 1;
        }
    }

    private void ConfirmTaskButton_Click(object sender, RoutedEventArgs e)
    {
        if (TryAcceptRotationInput())
        {
            _viewModel.ConfirmCurrentTask();
        }
    }

    private void PauseResumeButton_Click(object sender, RoutedEventArgs e)
    {
        if (TryAcceptRotationInput())
        {
            _viewModel.PauseOrResume();
        }
    }

    private void SkipButton_Click(object sender, RoutedEventArgs e)
    {
        if (TryAcceptRotationInput())
        {
            _viewModel.SkipCurrentSlice();
        }
    }

    private void CompleteButton_Click(object sender, RoutedEventArgs e)
    {
        if (TryAcceptRotationInput())
        {
            _viewModel.CompleteCurrentTask();
        }
    }

    private void StopButton_Click(object sender, RoutedEventArgs e)
    {
        if (!TryAcceptRotationInput())
        {
            return;
        }

        var result = WpfMessageBox.Show(
            this,
            "停止当前轮转？已经确认工作的时长会保留。",
            "停止轮转",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question,
            MessageBoxResult.No);
        if (result == MessageBoxResult.Yes)
        {
            _viewModel.StopRotation();
            MainTabs.SelectedIndex = 0;
        }
    }

    private bool TryAcceptRotationInput()
    {
        var now = Stopwatch.GetTimestamp();
        var minimumInterval = Stopwatch.Frequency / 2;
        if (_lastRotationInputTimestamp != 0 && now - _lastRotationInputTimestamp < minimumInterval)
        {
            return false;
        }

        _lastRotationInputTimestamp = now;
        return true;
    }

    private void ExportCsvButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new WpfSaveFileDialog
        {
            Title = "导出 Taskronome 统计",
            Filter = "CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*",
            DefaultExt = ".csv",
            AddExtension = true,
            FileName = $"Taskronome-statistics-{DateTime.Now:yyyyMMdd-HHmmss}.csv",
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                _viewModel.ExportSelectedStatisticsCsv(dialog.FileName);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                WpfMessageBox.Show(this, $"导出失败：{exception.Message}", "导出失败", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    private void TestNotificationButton_Click(object sender, RoutedEventArgs e)
    {
        var sent = _notificationService.ShowTestNotification();
        if (!sent)
        {
            ShowTrayFallback("Taskronome 测试通知", "Windows 通知不可用，已使用托盘气泡作为回退。应用内确认仍可正常工作。");
            WpfMessageBox.Show(
                this,
                $"Windows App SDK 通知发送失败。\n\n{_notificationService.LastError}\n\n已尝试托盘回退，轮转不会因此崩溃。",
                "通知测试",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private void OpenDataFolderButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(_viewModel.DataDirectory);
            Process.Start(new ProcessStartInfo
            {
                FileName = _viewModel.DataDirectory,
                UseShellExecute = true,
            });
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Win32Exception)
        {
            WpfMessageBox.Show(this, $"无法打开数据文件夹：{exception.Message}", "打开失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void Window_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        var modifiers = Keyboard.Modifiers;
        if (modifiers.HasFlag(ModifierKeys.Control) &&
            modifiers.HasFlag(ModifierKeys.Shift) &&
            e.Key == Key.T)
        {
            _viewModel.AlwaysOnTop = !_viewModel.AlwaysOnTop;
            e.Handled = true;
            return;
        }

        if (modifiers == ModifierKeys.Control && e.Key == Key.N && _viewModel.CanEditTasks)
        {
            ShowTaskEditor(null, null);
            e.Handled = true;
            return;
        }

        if (IsTextEntryFocused())
        {
            return;
        }

        if (e.Key == Key.Enter && _viewModel.CanConfirm)
        {
            _viewModel.ConfirmCurrentTask();
            e.Handled = true;
        }
        else if (e.Key == Key.Space && _viewModel.CanPauseResume)
        {
            _viewModel.PauseOrResume();
            e.Handled = true;
        }
    }

    private static bool IsTextEntryFocused()
    {
        return Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase
            or PasswordBox
            or System.Windows.Controls.ComboBox;
    }

    private void CreateTrayIcon()
    {
        _trayMenu = new Forms.ContextMenuStrip();
        _trayMenu.Items.Add("显示 Taskronome", null, (_, _) => Dispatcher.InvokeAsync(ActivateFromExternalRequest));
        _trayPauseItem = new Forms.ToolStripMenuItem("暂停 / 恢复", null, (_, _) => Dispatcher.InvokeAsync(() => _viewModel.PauseOrResume()));
        _trayMenu.Items.Add(_trayPauseItem);
        _trayTopmostItem = new Forms.ToolStripMenuItem("窗口始终置顶", null, (_, _) => Dispatcher.InvokeAsync(() => _viewModel.AlwaysOnTop = !_viewModel.AlwaysOnTop));
        _trayMenu.Items.Add(_trayTopmostItem);
        _trayMenu.Items.Add(new Forms.ToolStripSeparator());
        _trayMenu.Items.Add("退出", null, (_, _) => Dispatcher.InvokeAsync(() => ((App)WpfApplication.Current).RequestExit()));

        var processPath = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(processPath))
        {
            using var associatedIcon = System.Drawing.Icon.ExtractAssociatedIcon(processPath);
            _ownedTrayIcon = associatedIcon is null ? null : (System.Drawing.Icon)associatedIcon.Clone();
        }

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = _ownedTrayIcon ?? System.Drawing.SystemIcons.Application,
            Text = "Taskronome",
            Visible = true,
            ContextMenuStrip = _trayMenu,
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.InvokeAsync(ActivateFromExternalRequest);
        UpdateTrayMenu();
    }

    private void UpdateTrayMenu()
    {
        if (_trayPauseItem is not null)
        {
            _trayPauseItem.Text = _viewModel.PauseResumeText;
            _trayPauseItem.Enabled = _viewModel.CanPauseResume;
        }

        if (_trayTopmostItem is not null)
        {
            _trayTopmostItem.Checked = _viewModel.AlwaysOnTop;
        }

        if (_trayIcon is not null)
        {
            var text = _viewModel.State == RotationState.Running
                ? $"Taskronome - {_viewModel.CurrentTaskName}"
                : $"Taskronome - {_viewModel.StateText}";
            _trayIcon.Text = text.Length <= 63 ? text : text[..63];
        }
    }

    private void ShowTrayFallback(string title, string message)
    {
        if (_trayIcon is null)
        {
            return;
        }

        _trayIcon.BalloonTipTitle = title;
        _trayIcon.BalloonTipText = message;
        _trayIcon.BalloonTipIcon = Forms.ToolTipIcon.Info;
        _trayIcon.ShowBalloonTip(5000);
    }

    private void SmokeTest_ContentRendered(object? sender, EventArgs e)
    {
        ContentRendered -= SmokeTest_ContentRendered;
        try
        {
            if (!_viewModel.AddTask(new TaskDraft("UI smoke task", "temporary", TimeSpan.FromSeconds(1))))
            {
                throw new InvalidOperationException("Unable to create the smoke-test task.");
            }

            if (!_viewModel.StartRotation() || !_viewModel.ConfirmCurrentTask() || !_viewModel.PauseOrResume())
            {
                throw new InvalidOperationException("The smoke-test state transition sequence failed.");
            }

            if (_viewModel.State != RotationState.PausedManual || !_viewModel.StopRotation())
            {
                throw new InvalidOperationException("The smoke-test did not reach the expected safe state.");
            }

            if (_smokeHoldMilliseconds <= 0)
            {
                Dispatcher.InvokeAsync(() => ((App)WpfApplication.Current).CompleteSmokeTest(0));
            }
            else
            {
                _smokeCompletionTimer = new DispatcherTimer
                {
                    Interval = TimeSpan.FromMilliseconds(_smokeHoldMilliseconds),
                };
                _smokeCompletionTimer.Tick += SmokeCompletionTimer_Tick;
                _smokeCompletionTimer.Start();
            }
        }
        catch (Exception exception)
        {
            ((App)WpfApplication.Current).HandleRecoverableUiException("UI 启动烟雾测试失败。", exception);
            Dispatcher.InvokeAsync(() => ((App)WpfApplication.Current).CompleteSmokeTest(1));
        }
    }

    private void SmokeCompletionTimer_Tick(object? sender, EventArgs e)
    {
        if (_smokeCompletionTimer is null)
        {
            return;
        }

        _smokeCompletionTimer.Stop();
        _smokeCompletionTimer.Tick -= SmokeCompletionTimer_Tick;
        _smokeCompletionTimer = null;
        ((App)WpfApplication.Current).CompleteSmokeTest(0);
    }

    private void DisposeWindowResources()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _uiTimer.Stop();
        _uiTimer.Tick -= UiTimer_Tick;
        if (_smokeCompletionTimer is not null)
        {
            _smokeCompletionTimer.Stop();
            _smokeCompletionTimer.Tick -= SmokeCompletionTimer_Tick;
            _smokeCompletionTimer = null;
        }
        _sessionMonitor?.Dispose();
        _sessionMonitor = null;

        _viewModel.PresenceRequired -= ViewModel_PresenceRequired;
        _viewModel.AlwaysOnTopChanged -= ViewModel_AlwaysOnTopChanged;
        _viewModel.SettingsChanged -= ViewModel_SettingsChanged;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _notificationService.ActivationRequested -= NotificationService_ActivationRequested;

        if (_trayIcon is not null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }

        _ownedTrayIcon?.Dispose();
        _ownedTrayIcon = null;
        _trayMenu?.Dispose();
        _trayMenu = null;
    }

    public void Dispose()
    {
        DisposeWindowResources();
        GC.SuppressFinalize(this);
    }
}
