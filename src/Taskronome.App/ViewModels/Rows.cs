namespace Taskronome.App.ViewModels;

public sealed record TaskDraft(string Name, string Notes, TimeSpan SliceDuration);

public sealed record TaskDisplayRow(
    Guid Id,
    int Order,
    string Name,
    string Notes,
    string SliceText,
    bool Enabled,
    string CompletionText,
    string TodayText);

public sealed record TaskStatisticRow(
    string TaskName,
    int SegmentCount,
    string DurationText,
    string ShareText);

public sealed record EventDisplayRow(
    string OccurredAtText,
    string TaskName,
    string TypeText,
    string Detail);

public sealed record StatisticsScopeOption(string Key, string DisplayName);

public sealed class PresenceRequiredEventArgs : EventArgs
{
    public PresenceRequiredEventArgs(string taskName)
    {
        TaskName = taskName;
    }

    public string TaskName { get; }
}
