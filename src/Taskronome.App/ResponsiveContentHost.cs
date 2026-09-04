using System.Windows;
using System.Windows.Controls;
using WpfSize = System.Windows.Size;

namespace Taskronome.App;

/// <summary>
/// Keeps vertically scrollable page content from imposing an oversized window
/// minimum when a parent ScrollViewer measures it with infinite width.
/// </summary>
public sealed class ResponsiveContentHost : Decorator
{
    public double FallbackMeasureWidth { get; set; } = 320;

    protected override WpfSize MeasureOverride(WpfSize constraint)
    {
        if (Child is null)
        {
            return new WpfSize();
        }

        var width = double.IsInfinity(constraint.Width)
            ? Math.Max(0, FallbackMeasureWidth)
            : Math.Max(0, constraint.Width);
        Child.Measure(new WpfSize(width, constraint.Height));
        return new WpfSize(width, Child.DesiredSize.Height);
    }

    protected override WpfSize ArrangeOverride(WpfSize arrangeSize)
    {
        Child?.Arrange(new Rect(new System.Windows.Point(), arrangeSize));
        return arrangeSize;
    }
}
