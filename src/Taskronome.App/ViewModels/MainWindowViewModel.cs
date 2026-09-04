using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Text;
using Taskronome.App.Services;
using Taskronome.Core;

namespace Taskronome.App.ViewModels;

public sealed class MainWindowViewModel : ObservableObject, IDisposable
{
    private static readonly TimeSpan CheckpointInterval = TimeSpan.FromSeconds(2);

    private readonly RotationEngine _engine;
    private readonly IMonotonicClock _clock;
    private readonly IStateStore _dataStore;
    private readonly IAppLogger _logger;
    private TaskronomeData _data;
    private RotationStatus _status;
    private RotationState _lastObservedState;
    private Guid? _lastObservedTaskId;
    private long _lastCheckpointTimestamp;
    private int _lastSegmentCount = -1;
    private int _lastEventCount = -1;
    private TaskDisplayRow? _selectedTask;
    private string _currentTaskName = string.Empty;
    private string _nextTaskName = string.Empty;
    private string _remainingText = "00:00:00";
    private string _confirmationText = string.Empty;
    private string _stateText = string.Empty;
    private string _systemPauseText = string.Empty;
    private string _cycleDurationText = "00:00:00";
    private string _statisticsTotalText = "00:00:00";
    private double _progressPercent;
    private bool _isAwaitingConfirmation;
    private bool _isAbsentPaused;
    private bool _isSystemPaused;
    private bool _canStart;
    private bool _canConfirm;
    private bool _canPauseResume;
    private bool _canSkip;
    private bool _canComplete;
    private bool _canStop;
    private bool _canEditTasks;
    private string _pauseResumeText = "暂停";
    private string _feedbackMessage = string.Empty;
    private bool _feedbackIsError;
    private string _selectedStatisticsScope;
    private bool _disposed;

    public MainWindowViewModel(
        IStateStore dataStore,
        IAppLogger logger,
        IMonotonicClock? clock = null,
        RotationOptions? rotationOptions = null)
    {
        _dataStore = dataStore ?? throw new ArgumentNullException(nameof(dataStore));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _clock = clock ?? new SystemMonotonicClock();

        var loadResult = _dataStore.Load();
        _data = loadResult.Data;
        _engine = new RotationEngine(
            _clock,
            rotationOptions ?? new RotationOptions
            {
                ConfirmationTimeout = TimeSpan.FromSeconds(10),
                HeartbeatGapThreshold = TimeSpan.FromSeconds(5),
            });
        _engine.Load(_data.Tasks, _data.WorkSegments, _data.Checkpoint, _data.Events);
        _status = _engine.GetStatus();
        _lastObservedState = _status.State;
        _lastObservedTaskId = _status.CurrentTaskId;
        _selectedStatisticsScope = NormalizeStatisticsScope(_data.Settings.StatisticsScope);
        _lastCheckpointTimestamp = _clock.GetTimestamp();

        StatisticsScopes = new ReadOnlyCollection<StatisticsScopeOption>(new[]
        {
            new StatisticsScopeOption("Today", "今天"),
            new StatisticsScopeOption("SevenDays", "最近 7 天"),
            new StatisticsScopeOption("ThirtyDays", "最近 30 天"),
            new StatisticsScopeOption("All", "全部"),
        });

        if (loadResult.RecoveredFromCorruption)
        {
            var recoverySource = loadResult.RecoveredFromBackup
                ? "应用已从上一次成功保存的备份恢复。"
                : "应用已使用安全的空白数据启动。";
            var corruptFiles = string.Join(
                "；",
                new[] { loadResult.CorruptFilePath, loadResult.CorruptBackupFilePath }
                    .Where(path => !string.IsNullOrWhiteSpace(path)));
            FeedbackMessage = string.IsNullOrWhiteSpace(corruptFiles)
                ? $"数据文件无法读取，{recoverySource}"
                : $"数据文件无法读取，{recoverySource} 损坏文件已保留：{corruptFiles}";
            FeedbackIsError = true;
            _logger.Warning(FeedbackMessage);
        }
        else if (_status.State == RotationState.PausedSystem &&
                 _status.SystemPauseReason == SystemPauseReason.ApplicationRestart)
        {
            FeedbackMessage = "检测到上次运行被中断。离线时间未计入，请手动恢复。";
        }

        RefreshAll(forceCollections: true, allowPresenceEvent: false);
    }

    public event EventHandler<PresenceRequiredEventArgs>? PresenceRequired;

    public event EventHandler? AlwaysOnTopChanged;

    public event EventHandler? SettingsChanged;

    public ObservableCollection<TaskDisplayRow> TaskRows { get; } = new();

    public ObservableCollection<TaskStatisticRow> StatisticRows { get; } = new();

    public ObservableCollection<EventDisplayRow> EventRows { get; } = new();

    public IReadOnlyList<StatisticsScopeOption> StatisticsScopes { get; }

    public string DataDirectory => _dataStore.DirectoryPath;

    public TaskDisplayRow? SelectedTask
    {
        get => _selectedTask;
        set
        {
            if (SetProperty(ref _selectedTask, value))
            {
                OnPropertyChanged(nameof(HasSelectedTask));
                OnPropertyChanged(nameof(CanEditSelectedTask));
            }
        }
    }

    public bool HasSelectedTask => SelectedTask is not null;

    public bool CanEditSelectedTask => CanEditTasks && HasSelectedTask;

    public string CurrentTaskName
    {
        get => _currentTaskName;
        private set => SetProperty(ref _currentTaskName, value);
    }

    public string NextTaskName
    {
        get => _nextTaskName;
        private set => SetProperty(ref _nextTaskName, value);
    }

    public string RemainingText
    {
        get => _remainingText;
        private set => SetProperty(ref _remainingText, value);
    }

    public string ConfirmationText
    {
        get => _confirmationText;
        private set => SetProperty(ref _confirmationText, value);
    }

    public string StateText
    {
        get => _stateText;
        private set => SetProperty(ref _stateText, value);
    }

    public string SystemPauseText
    {
        get => _systemPauseText;
        private set => SetProperty(ref _systemPauseText, value);
    }

    public string CycleDurationText
    {
        get => _cycleDurationText;
        private set => SetProperty(ref _cycleDurationText, value);
    }

    public string StatisticsTotalText
    {
        get => _statisticsTotalText;
        private set => SetProperty(ref _statisticsTotalText, value);
    }

    public double ProgressPercent
    {
        get => _progressPercent;
        private set => SetProperty(ref _progressPercent, value);
    }

    public bool IsAwaitingConfirmation
    {
        get => _isAwaitingConfirmation;
        private set => SetProperty(ref _isAwaitingConfirmation, value);
    }

    public bool IsAbsentPaused
    {
        get => _isAbsentPaused;
        private set => SetProperty(ref _isAbsentPaused, value);
    }

    public bool IsSystemPaused
    {
        get => _isSystemPaused;
        private set => SetProperty(ref _isSystemPaused, value);
    }

    public bool CanStart
    {
        get => _canStart;
        private set => SetProperty(ref _canStart, value);
    }

    public bool CanConfirm
    {
        get => _canConfirm;
        private set => SetProperty(ref _canConfirm, value);
    }

    public bool CanPauseResume
    {
        get => _canPauseResume;
        private set => SetProperty(ref _canPauseResume, value);
    }

    public bool CanSkip
    {
        get => _canSkip;
        private set => SetProperty(ref _canSkip, value);
    }

    public bool CanComplete
    {
        get => _canComplete;
        private set => SetProperty(ref _canComplete, value);
    }

    public bool CanStop
    {
        get => _canStop;
        private set => SetProperty(ref _canStop, value);
    }

    public bool CanEditTasks
    {
        get => _canEditTasks;
        private set
        {
            if (SetProperty(ref _canEditTasks, value))
            {
                OnPropertyChanged(nameof(CanEditSelectedTask));
            }
        }
    }

    public string PauseResumeText
    {
        get => _pauseResumeText;
        private set => SetProperty(ref _pauseResumeText, value);
    }

    public string FeedbackMessage
    {
        get => _feedbackMessage;
        private set => SetProperty(ref _feedbackMessage, value);
    }

    public bool FeedbackIsError
    {
        get => _feedbackIsError;
        private set => SetProperty(ref _feedbackIsError, value);
    }

    public bool AlwaysOnTop
    {
        get => _data.Settings.AlwaysOnTop;
        set
        {
            if (_data.Settings.AlwaysOnTop == value)
            {
                return;
            }

            _data.Settings.AlwaysOnTop = value;
            OnPropertyChanged();
            PersistNow(silent: true);
            AlwaysOnTopChanged?.Invoke(this, EventArgs.Empty);
            SettingsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public bool PlaySound
    {
        get => _data.Settings.PlaySound;
        set => SetSetting(
            _data.Settings.PlaySound,
            value,
            newValue => _data.Settings.PlaySound = newValue);
    }

    public bool ShowNotification
    {
        get => _data.Settings.ShowNotification;
        set => SetSetting(
            _data.Settings.ShowNotification,
            value,
            newValue => _data.Settings.ShowNotification = newValue);
    }

    public bool MinimizeToTrayOnClose
    {
        get => _data.Settings.MinimizeToTrayOnClose;
        set => SetSetting(
            _data.Settings.MinimizeToTrayOnClose,
            value,
            newValue => _data.Settings.MinimizeToTrayOnClose = newValue);
    }

    public string SelectedStatisticsScope
    {
        get => _selectedStatisticsScope;
        set
        {
            var normalized = NormalizeStatisticsScope(value);
            if (!SetProperty(ref _selectedStatisticsScope, normalized))
            {
                return;
            }

            _data.Settings.StatisticsScope = normalized;
            RefreshStatistics();
            PersistNow(silent: true);
        }
    }

    public RotationState State => _status.State;

    public bool IsActiveRotation => _status.State is not (RotationState.Idle or RotationState.Completed);

    public WindowPlacementData WindowPlacement => _data.WindowPlacement;

    public void Tick()
    {
        ThrowIfDisposed();
        _engine.Pulse();
        RefreshAll(forceCollections: false, allowPresenceEvent: true);

        var nowTimestamp = _clock.GetTimestamp();
        if (_clock.GetElapsedTime(_lastCheckpointTimestamp, nowTimestamp) >= CheckpointInterval)
        {
            PersistNow(silent: true);
            _lastCheckpointTimestamp = nowTimestamp;
        }
    }

    public bool AddTask(TaskDraft draft)
    {
        ThrowIfDisposed();
        if (!CanEditTasks)
        {
            SetFeedback("轮转期间不能修改任务。", true);
            return false;
        }

        if (!ValidateDraft(draft, out var error))
        {
            SetFeedback(error ?? "任务输入无效。", true);
            return false;
        }

        var tasks = _engine.GetTasks().ToList();
        var now = _clock.GetUtcNow();
        tasks.Add(new TaskItem
        {
            Name = draft.Name.Trim(),
            Notes = draft.Notes,
            SliceDuration = draft.SliceDuration,
            Order = tasks.Count,
            Enabled = true,
            Completed = false,
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
        });
        CommitTasks(tasks, "任务已创建。");
        return true;
    }

    public bool UpdateTask(Guid taskId, TaskDraft draft)
    {
        ThrowIfDisposed();
        if (!CanEditTasks)
        {
            SetFeedback("轮转期间不能修改任务。", true);
            return false;
        }

        if (!ValidateDraft(draft, out var error))
        {
            SetFeedback(error ?? "任务输入无效。", true);
            return false;
        }

        var tasks = _engine.GetTasks().ToList();
        var task = tasks.FirstOrDefault(item => item.Id == taskId);
        if (task is null)
        {
            SetFeedback("未找到要编辑的任务。", true);
            return false;
        }

        task.Name = draft.Name.Trim();
        task.Notes = draft.Notes;
        task.SliceDuration = draft.SliceDuration;
        task.UpdatedAtUtc = _clock.GetUtcNow();
        CommitTasks(tasks, "任务已更新。");
        return true;
    }

    public TaskDraft? GetTaskDraft(Guid taskId)
    {
        var task = _engine.GetTasks().FirstOrDefault(item => item.Id == taskId);
        return task is null ? null : new TaskDraft(task.Name, task.Notes, task.SliceDuration);
    }

    public bool DeleteTask(Guid taskId)
    {
        if (!CanEditTasks)
        {
            SetFeedback("轮转期间不能删除任务。", true);
            return false;
        }

        var tasks = _engine.GetTasks().Where(task => task.Id != taskId).ToList();
        if (tasks.Count == _engine.GetTasks().Count)
        {
            return false;
        }

        CommitTasks(tasks, "任务已删除。");
        return true;
    }

    public bool ToggleSelectedEnabled()
    {
        if (SelectedTask is null || !CanEditTasks)
        {
            return false;
        }

        var tasks = _engine.GetTasks().ToList();
        var task = tasks.First(item => item.Id == SelectedTask.Id);
        task.Enabled = !task.Enabled;
        task.UpdatedAtUtc = _clock.GetUtcNow();
        CommitTasks(tasks, task.Enabled ? "任务已启用。" : "任务已停用。");
        return true;
    }

    public bool ReopenSelectedTask()
    {
        if (SelectedTask is null || !CanEditTasks)
        {
            return false;
        }

        var tasks = _engine.GetTasks().ToList();
        var task = tasks.First(item => item.Id == SelectedTask.Id);
        if (!task.Completed)
        {
            SetFeedback("所选任务尚未完成。", false);
            return false;
        }

        task.Completed = false;
        task.Enabled = true;
        task.UpdatedAtUtc = _clock.GetUtcNow();
        CommitTasks(tasks, "任务已重新启用。");
        return true;
    }

    public bool ResetAllCompleted()
    {
        if (!CanEditTasks)
        {
            return false;
        }

        var tasks = _engine.GetTasks().ToList();
        var changed = false;
        foreach (var task in tasks.Where(task => task.Completed))
        {
            task.Completed = false;
            task.UpdatedAtUtc = _clock.GetUtcNow();
            changed = true;
        }

        if (!changed)
        {
            SetFeedback("没有需要重置的已完成任务。", false);
            return false;
        }

        CommitTasks(tasks, "全部任务的完成状态已重置；历史统计未清除。");
        return true;
    }

    public bool MoveSelected(int direction)
    {
        if (SelectedTask is null || !CanEditTasks || direction is not (-1 or 1))
        {
            return false;
        }

        var tasks = _engine.GetTasks().OrderBy(task => task.Order).ToList();
        var index = tasks.FindIndex(task => task.Id == SelectedTask.Id);
        var target = index + direction;
        if (index < 0 || target < 0 || target >= tasks.Count)
        {
            return false;
        }

        (tasks[index], tasks[target]) = (tasks[target], tasks[index]);
        CommitTasks(tasks, "任务顺序已调整。", SelectedTask.Id);
        return true;
    }

    public bool StartRotation()
    {
        if (!_engine.StartRotation())
        {
            SetFeedback("没有可轮转的任务，请先创建并启用至少一项未完成任务。", true);
            RefreshAll(forceCollections: true, allowPresenceEvent: false);
            return false;
        }

        SetFeedback("轮转已开始，请确认第一项任务。", false);
        RefreshAll(forceCollections: true, allowPresenceEvent: true);
        PersistNow(silent: true);
        return true;
    }

    public bool ConfirmCurrentTask()
    {
        var result = _engine.ConfirmCurrentTask();
        SetFeedback(
            result ? "已确认在场，时间片开始计时。" : "确认已超时或当前状态不允许确认。",
            !result);
        RefreshAll(forceCollections: false, allowPresenceEvent: false);
        PersistNow(silent: true);
        return result;
    }

    public bool PauseOrResume()
    {
        bool result;
        string successMessage;
        switch (_status.State)
        {
            case RotationState.Running:
                result = _engine.PauseManual();
                successMessage = "已暂停；暂停期间不计时。";
                break;
            case RotationState.PausedManual:
                result = _engine.ResumeManual();
                successMessage = "已恢复当前任务。";
                break;
            case RotationState.PausedAbsent:
                result = _engine.ResumeAfterAbsence();
                successMessage = "请在新的 10 秒倒计时内确认任务。";
                break;
            case RotationState.PausedSystem:
                result = _engine.ResumeAfterSystemPause();
                successMessage = "系统暂停已处理；请继续当前任务。";
                break;
            default:
                result = false;
                successMessage = string.Empty;
                break;
        }

        SetFeedback(result ? successMessage : "当前状态不能暂停或恢复。", !result);
        RefreshAll(forceCollections: true, allowPresenceEvent: true);
        PersistNow(silent: true);
        return result;
    }

    public bool SkipCurrentSlice()
    {
        var result = _engine.SkipCurrentSlice();
        SetFeedback(result ? "本轮已跳过；任务将在后续轮次再次出现。" : "当前状态不能跳过。", !result);
        RefreshAll(forceCollections: true, allowPresenceEvent: true);
        PersistNow(silent: true);
        return result;
    }

    public bool CompleteCurrentTask()
    {
        var result = _engine.CompleteCurrentTask();
        SetFeedback(result ? "当前任务已标记为完成，并从后续轮转中排除。" : "当前状态不能完成任务。", !result);
        RefreshAll(forceCollections: true, allowPresenceEvent: true);
        PersistNow(silent: true);
        return result;
    }

    public bool StopRotation()
    {
        var result = _engine.StopRotation();
        SetFeedback(result ? "轮转已停止，已工作时长已保存。" : "当前没有正在进行的轮转。", !result);
        RefreshAll(forceCollections: true, allowPresenceEvent: false);
        PersistNow(silent: true);
        return result;
    }

    public bool PauseForSystem(SystemPauseReason reason)
    {
        var result = _engine.PauseForSystem(reason);
        if (result)
        {
            SetFeedback("检测到系统中断，轮转已安全暂停；中断时间不会计入。", false);
            RefreshAll(forceCollections: true, allowPresenceEvent: false);
            PersistNow(silent: true);
        }

        return result;
    }

    public void NotifySystemReturned()
    {
        if (_status.State == RotationState.PausedSystem)
        {
            SetFeedback("系统已恢复。请点击“恢复并确认”后继续。", false);
        }
    }

    public int ExportSelectedStatisticsCsv(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("An export path is required.", nameof(path));
        }

        var segments = GetFilteredSegments().OrderBy(segment => segment.StartedAtUtc).ToArray();
        using var writer = new StreamWriter(path, append: false, encoding: new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        writer.WriteLine("开始时间,结束时间,任务,实际秒数,实际时长,结束原因");
        foreach (var segment in segments)
        {
            writer.WriteLine(string.Join(",", new[]
            {
                CsvFormatter.Escape(segment.StartedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.CurrentCulture)),
                CsvFormatter.Escape(segment.EndedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.CurrentCulture)),
                CsvFormatter.Escape(segment.TaskName),
                segment.Duration.TotalSeconds.ToString("0.###", CultureInfo.InvariantCulture),
                CsvFormatter.Escape(FormatDuration(segment.Duration)),
                CsvFormatter.Escape(GetEndReasonText(segment.EndReason)),
            }));
        }

        SetFeedback($"已导出 {segments.Length} 条工作记录。", false);
        return segments.Length;
    }

    public void UpdateWindowPlacement(WindowPlacementData placement)
    {
        _data.WindowPlacement = placement ?? throw new ArgumentNullException(nameof(placement));
    }

    public void PrepareForExit()
    {
        if (_disposed)
        {
            return;
        }

        _engine.PauseForSystem(SystemPauseReason.ApplicationExit);
        RefreshAll(forceCollections: true, allowPresenceEvent: false);
        PersistNow(silent: true);
    }

    public void PersistNow(bool silent)
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            _data.Tasks = _engine.GetTasks().ToList();
            _data.WorkSegments = _engine.GetSegments().ToList();
            _data.Events = _engine.GetEvents().ToList();
            _data.Checkpoint = _engine.CreateCheckpoint();
            _data.Settings.StatisticsScope = SelectedStatisticsScope;
            _dataStore.Save(_data);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _logger.LogError("Saving application data failed.", exception);
            if (!silent)
            {
                SetFeedback($"保存失败：{exception.Message}", true);
            }
        }
    }

    private void CommitTasks(List<TaskItem> tasks, string message, Guid? preserveSelection = null)
    {
        for (var index = 0; index < tasks.Count; index++)
        {
            tasks[index].Order = index;
        }

        var selectedId = preserveSelection ?? SelectedTask?.Id;
        _engine.ReplaceTasks(tasks);
        RefreshAll(forceCollections: true, allowPresenceEvent: false);
        if (selectedId.HasValue)
        {
            SelectedTask = TaskRows.FirstOrDefault(row => row.Id == selectedId.Value);
        }

        SetFeedback(message, false);
        PersistNow(silent: false);
    }

    private void RefreshAll(bool forceCollections, bool allowPresenceEvent)
    {
        var previousState = _lastObservedState;
        var previousTaskId = _lastObservedTaskId;
        _status = _engine.GetStatus();

        CurrentTaskName = string.IsNullOrWhiteSpace(_status.CurrentTaskName)
            ? "尚未开始轮转"
            : _status.CurrentTaskName;
        NextTaskName = string.IsNullOrWhiteSpace(_status.NextTaskName) ? "—" : _status.NextTaskName;
        RemainingText = FormatCountdown(_status.Remaining);
        ConfirmationText = _status.State == RotationState.AwaitingConfirmation
            ? $"请在 {Math.Max(0, _status.ConfirmationRemaining.TotalSeconds):0.0} 秒内点击“开始任务”。超时将暂停且不计时。"
            : string.Empty;
        StateText = GetStateText(_status.State);
        SystemPauseText = GetSystemPauseText(_status.SystemPauseReason);
        CycleDurationText = FormatDuration(_status.ActiveCycleDuration);
        ProgressPercent = _status.Progress * 100d;
        IsAwaitingConfirmation = _status.State == RotationState.AwaitingConfirmation;
        IsAbsentPaused = _status.State == RotationState.PausedAbsent;
        IsSystemPaused = _status.State == RotationState.PausedSystem;
        CanEditTasks = _status.CanEditTasks;

        var activeTasks = _engine.GetTasks().Count(task => task.Enabled && !task.Completed);
        CanStart = _status.State is RotationState.Idle or RotationState.Completed && activeTasks > 0;
        CanConfirm = _status.State == RotationState.AwaitingConfirmation;
        CanPauseResume = _status.State is RotationState.Running
            or RotationState.PausedManual
            or RotationState.PausedAbsent
            or RotationState.PausedSystem;
        CanSkip = _status.CurrentTaskId.HasValue && _status.State is not (RotationState.Idle or RotationState.Completed);
        CanComplete = CanSkip;
        CanStop = _status.State is not (RotationState.Idle or RotationState.Completed);
        PauseResumeText = _status.State switch
        {
            RotationState.Running => "暂停",
            RotationState.PausedAbsent => "恢复轮转",
            RotationState.PausedSystem => "恢复并确认",
            _ => "恢复",
        };
        OnPropertyChanged(nameof(State));
        OnPropertyChanged(nameof(IsActiveRotation));

        var segmentCount = _engine.GetSegments().Count;
        var eventCount = _engine.GetEvents().Count;
        if (forceCollections || segmentCount != _lastSegmentCount)
        {
            RefreshTaskRows();
            RefreshStatistics();
            _lastSegmentCount = segmentCount;
        }

        if (forceCollections || eventCount != _lastEventCount)
        {
            RefreshEvents();
            _lastEventCount = eventCount;
        }

        _lastObservedState = _status.State;
        _lastObservedTaskId = _status.CurrentTaskId;

        if (allowPresenceEvent &&
            _status.State == RotationState.AwaitingConfirmation &&
            (previousState != RotationState.AwaitingConfirmation || previousTaskId != _status.CurrentTaskId))
        {
            PresenceRequired?.Invoke(this, new PresenceRequiredEventArgs(_status.CurrentTaskName));
        }
    }

    private void RefreshTaskRows()
    {
        var selectedId = SelectedTask?.Id;
        var todayNow = _clock.GetUtcNow().ToLocalTime();
        var todayDurations = StatisticsCalculator.Filter(_engine.GetSegments(), "Today", todayNow)
            .GroupBy(segment => segment.TaskId)
            .ToDictionary(group => group.Key, group => group.Aggregate(TimeSpan.Zero, (sum, segment) => sum + segment.Duration));

        TaskRows.Clear();
        foreach (var task in _engine.GetTasks())
        {
            todayDurations.TryGetValue(task.Id, out var today);
            TaskRows.Add(new TaskDisplayRow(
                task.Id,
                task.Order + 1,
                task.Name,
                task.Notes,
                FormatDuration(task.SliceDuration),
                task.Enabled,
                task.Completed ? "已完成" : "未完成",
                FormatDuration(today)));
        }

        SelectedTask = selectedId.HasValue
            ? TaskRows.FirstOrDefault(row => row.Id == selectedId.Value)
            : null;
        OnPropertyChanged(nameof(CanEditSelectedTask));
    }

    private void RefreshStatistics()
    {
        var segments = GetFilteredSegments().ToArray();
        var total = StatisticsCalculator.Total(segments);
        StatisticsTotalText = FormatDuration(total);

        StatisticRows.Clear();
        foreach (var group in segments
                     .GroupBy(segment => new { segment.TaskId, segment.TaskName })
                     .Select(group => new
                     {
                         group.Key.TaskName,
                         Count = group.Count(),
                         Duration = StatisticsCalculator.Total(group),
                     })
                     .OrderByDescending(item => item.Duration))
        {
            var share = total <= TimeSpan.Zero ? 0d : group.Duration.TotalMilliseconds / total.TotalMilliseconds;
            StatisticRows.Add(new TaskStatisticRow(
                group.TaskName,
                group.Count,
                FormatDuration(group.Duration),
                share.ToString("P1", CultureInfo.CurrentCulture)));
        }
    }

    private void RefreshEvents()
    {
        EventRows.Clear();
        foreach (var item in _engine.GetEvents().OrderByDescending(item => item.OccurredAtUtc).Take(100))
        {
            EventRows.Add(new EventDisplayRow(
                item.OccurredAtUtc.ToLocalTime().ToString("MM-dd HH:mm:ss", CultureInfo.CurrentCulture),
                string.IsNullOrWhiteSpace(item.TaskName) ? "—" : item.TaskName,
                GetEventTypeText(item.Type),
                item.Detail));
        }
    }

    private IEnumerable<WorkSegment> GetFilteredSegments()
    {
        return StatisticsCalculator.Filter(
            _engine.GetSegments(),
            SelectedStatisticsScope,
            _clock.GetUtcNow().ToLocalTime());
    }

    private static bool ValidateDraft(TaskDraft draft, out string? error)
    {
        var validation = TaskValidator.Validate(draft.Name, draft.Notes, draft.SliceDuration);
        error = validation.IsValid ? null : string.Join(Environment.NewLine, validation.Errors);
        return validation.IsValid;
    }

    private void SetSetting(bool oldValue, bool newValue, Action<bool> setter)
    {
        if (oldValue == newValue)
        {
            return;
        }

        setter(newValue);
        OnPropertyChanged(string.Empty);
        PersistNow(silent: true);
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void SetFeedback(string message, bool isError)
    {
        FeedbackMessage = message;
        FeedbackIsError = isError;
    }

    private static string FormatDuration(TimeSpan duration)
    {
        if (duration < TimeSpan.Zero)
        {
            duration = TimeSpan.Zero;
        }

        var totalHours = (long)Math.Floor(duration.TotalHours);
        return $"{totalHours:00}:{duration.Minutes:00}:{duration.Seconds:00}";
    }

    private static string FormatCountdown(TimeSpan duration)
    {
        if (duration <= TimeSpan.Zero)
        {
            return "00:00:00";
        }

        var totalSeconds = (long)Math.Ceiling(duration.TotalSeconds);
        var hours = totalSeconds / 3600;
        var minutes = totalSeconds % 3600 / 60;
        var seconds = totalSeconds % 60;
        return $"{hours:00}:{minutes:00}:{seconds:00}";
    }

    private static string NormalizeStatisticsScope(string? scope)
    {
        return scope is "Today" or "SevenDays" or "ThirtyDays" or "All" ? scope : "Today";
    }

    private static string GetStateText(RotationState state)
    {
        return state switch
        {
            RotationState.Idle => "未开始",
            RotationState.AwaitingConfirmation => "等待在场确认",
            RotationState.Running => "计时中",
            RotationState.PausedManual => "已手动暂停",
            RotationState.PausedAbsent => "未确认在场，已暂停",
            RotationState.PausedSystem => "系统中断，已暂停",
            RotationState.Completed => "全部任务已完成",
            _ => state.ToString(),
        };
    }

    private static string GetSystemPauseText(SystemPauseReason? reason)
    {
        return reason switch
        {
            SystemPauseReason.Lock => "Windows 已锁屏。",
            SystemPauseReason.Suspend => "电脑进入睡眠或挂起。",
            SystemPauseReason.SessionDisconnected => "用户会话已断开。",
            SystemPauseReason.HeartbeatGap => "检测到不可信的计时空档。",
            SystemPauseReason.ApplicationExit => "应用退出前已安全暂停。",
            SystemPauseReason.ApplicationRestart => "上次运行被中断。",
            SystemPauseReason.Unknown => "发生未知系统中断。",
            _ => string.Empty,
        };
    }

    private static string GetEventTypeText(RotationEventType type)
    {
        return type switch
        {
            RotationEventType.RotationStarted => "开始轮转",
            RotationEventType.TaskConfirmationRequested => "等待确认",
            RotationEventType.TaskConfirmed => "确认任务",
            RotationEventType.ConfirmationTimedOut => "确认超时",
            RotationEventType.ManualPaused => "手动暂停",
            RotationEventType.ManualResumed => "手动恢复",
            RotationEventType.SliceSkipped => "跳过本轮",
            RotationEventType.TaskCompletedEarly => "提前完成",
            RotationEventType.SliceExpired => "时间片结束",
            RotationEventType.SystemPaused => "系统暂停",
            RotationEventType.SystemResumed => "系统恢复",
            RotationEventType.RotationStopped => "停止轮转",
            RotationEventType.RotationCompleted => "全部完成",
            RotationEventType.ApplicationRecovered => "中断恢复",
            _ => type.ToString(),
        };
    }

    private static string GetEndReasonText(WorkEndReason reason)
    {
        return reason switch
        {
            WorkEndReason.SliceExpired => "时间片自然结束",
            WorkEndReason.ManualPause => "手动暂停",
            WorkEndReason.Skipped => "跳过本轮",
            WorkEndReason.CompletedEarly => "提前完成",
            WorkEndReason.Stopped => "停止轮转",
            WorkEndReason.SystemPause => "系统暂停",
            WorkEndReason.ApplicationInterrupted => "应用中断",
            _ => reason.ToString(),
        };
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        PrepareForExit();
        _disposed = true;
    }
}
