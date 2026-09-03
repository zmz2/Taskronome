using Taskronome.Core;

namespace Taskronome.Core.Tests;

internal sealed class FakeClock : IMonotonicClock
{
    private long _timestampTicks;
    private DateTimeOffset _utcNow = new(2026, 9, 3, 0, 0, 0, TimeSpan.Zero);

    public long GetTimestamp() => _timestampTicks;

    public TimeSpan GetElapsedTime(long startTimestamp, long endTimestamp) =>
        TimeSpan.FromTicks(endTimestamp - startTimestamp);

    public DateTimeOffset GetUtcNow() => _utcNow;

    public void Advance(TimeSpan duration)
    {
        _timestampTicks += duration.Ticks;
        _utcNow += duration;
    }

    public void AdvanceMonotonicOnly(TimeSpan duration) => _timestampTicks += duration.Ticks;

    public void RewindMonotonicOnly(TimeSpan duration) => _timestampTicks -= duration.Ticks;

    public void SetUtcNow(DateTimeOffset utcNow) => _utcNow = utcNow;
}
