namespace Taskronome.Core;

public static class CsvFormatter
{
    public static string Escape(string? value)
    {
        var normalized = value ?? string.Empty;
        return $"\"{normalized.Replace("\"", "\"\"", StringComparison.Ordinal)}\"";
    }

    public static string FormatRow(IEnumerable<string?> fields)
    {
        ArgumentNullException.ThrowIfNull(fields);
        return string.Join(",", fields.Select(Escape));
    }
}
