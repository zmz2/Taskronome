using Taskronome.Core;

namespace Taskronome.Core.Tests;

public sealed class TaskValidatorTests
{
    [Fact]
    public void ValidTask_Passes()
    {
        var result = TaskValidator.Validate(" 写论文 ", "备注", TimeSpan.FromMinutes(25));
        Assert.True(result.IsValid);
        Assert.Empty(result.Errors);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void NonPositiveDuration_Fails(int seconds)
    {
        var result = TaskValidator.Validate("Task", string.Empty, TimeSpan.FromSeconds(seconds));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void NameAndNotesLimits_AreEnforced()
    {
        var result = TaskValidator.Validate(new string('a', 81), new string('b', 501), TimeSpan.FromMinutes(1));
        Assert.False(result.IsValid);
        Assert.Equal(2, result.Errors.Count);
    }

    [Fact]
    public void MaximumDuration_IsInclusive()
    {
        Assert.True(TaskValidator.Validate("Task", string.Empty, TaskValidator.MaximumDuration).IsValid);
        Assert.False(TaskValidator.Validate("Task", string.Empty, TimeSpan.FromDays(1)).IsValid);
    }
}
