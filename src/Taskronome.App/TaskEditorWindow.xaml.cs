using System.Globalization;
using System.Windows;
using Taskronome.App.ViewModels;
using Taskronome.Core;

namespace Taskronome.App;

public partial class TaskEditorWindow : Window
{
    private readonly Guid? _editingTaskId;

    public TaskEditorWindow(TaskDraft? draft = null, Guid? editingTaskId = null)
    {
        InitializeComponent();
        _editingTaskId = editingTaskId;

        var initial = draft ?? new TaskDraft(string.Empty, string.Empty, TimeSpan.FromMinutes(25));
        NameTextBox.Text = initial.Name;
        NotesTextBox.Text = initial.Notes;
        HoursTextBox.Text = ((int)initial.SliceDuration.TotalHours).ToString(CultureInfo.InvariantCulture);
        MinutesTextBox.Text = initial.SliceDuration.Minutes.ToString(CultureInfo.InvariantCulture);
        SecondsTextBox.Text = initial.SliceDuration.Seconds.ToString(CultureInfo.InvariantCulture);

        Loaded += (_, _) =>
        {
            NameTextBox.Focus();
            NameTextBox.SelectAll();
        };
    }

    public TaskDraft? Result { get; private set; }

    public Guid? EditingTaskId => _editingTaskId;

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(HoursTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var hours) ||
            !int.TryParse(MinutesTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var minutes) ||
            !int.TryParse(SecondsTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) ||
            hours is < 0 or > 23 ||
            minutes is < 0 or > 59 ||
            seconds is < 0 or > 59)
        {
            ValidationTextBlock.Text = "请输入有效的小时、分钟和秒；分钟与秒必须在 0–59 之间。";
            return;
        }

        var duration = new TimeSpan(hours, minutes, seconds);
        var validation = TaskValidator.Validate(NameTextBox.Text, NotesTextBox.Text, duration);
        if (!validation.IsValid)
        {
            ValidationTextBlock.Text = string.Join(Environment.NewLine, validation.Errors);
            return;
        }

        Result = new TaskDraft(NameTextBox.Text.Trim(), NotesTextBox.Text, duration);
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
