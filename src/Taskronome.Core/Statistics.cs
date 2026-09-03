namespace Taskronome.Core;

public static class StatisticsCalculator
{
    public static IReadOnlyList<WorkSegment> Filter(
        IEnumerable<WorkSegment> segments,
        string? scope,
        DateTimeOffset localNow)
    {
        ArgumentNullException.ThrowIfNull(segments);

        var normalizedScope = scope is "SevenDays" or "ThirtyDays" or "All" ? scope : "Today";
        if (normalizedScope == "All")
        {
            return segments.ToArray();
        }

        var localDate = localNow.Date;
        var startDate = normalizedScope switch
        {
            "SevenDays" => localDate.AddDays(-6),
            "ThirtyDays" => localDate.AddDays(-29),
            _ => localDate,
        };
        var start = new DateTimeOffset(startDate, localNow.Offset);

        return segments
            .Where(segment => segment.StartedAtUtc.ToOffset(localNow.Offset) >= start)
            .ToArray();
    }

    public static TimeSpan Total(IEnumerable<WorkSegment> segments)
    {
        ArgumentNullException.ThrowIfNull(segments);
        return segments.Aggregate(TimeSpan.Zero, (total, segment) => total + segment.Duration);
    }
}
