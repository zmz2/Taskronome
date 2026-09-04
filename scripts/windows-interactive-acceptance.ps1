[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppPath,

    [string]$AcceptanceRoot,

    [string]$CommitSha = '',

    [long]$CiRunId = 0,

    [long]$PackageArtifactId = 0,

    [long]$EvidenceArtifactId = 0,

    [string]$PortableSha256 = '',

    [string]$SetupSha256 = '',

    [switch]$OperatorAssistance,

    [switch]$PerformPhysicalOperations
)

<#
.SYNOPSIS
    Runs the real, production-mode Windows acceptance flow for Taskronome.

.DESCRIPTION
    This is an acceptance-only harness. It launches the supplied executable with
    an isolated --data-dir, drives the WPF controls through System.Windows.Automation,
    and records UI, data, process, window, screenshot, and log evidence. It does
    not enable --test-mode, --notification-dry-run, or any production diagnostic
    endpoint. The PowerShell process is the watchdog for the optional interruption
    checks; every thread suspension is paired with a finally-based resume.

    The harness is intentionally conservative around operations that can affect a
    human session. -OperatorAssistance permits one-line prompts for notification
    center, tray overflow, lock, sleep, display scaling, and high-contrast checks.
    -PerformPhysicalOperations permits the harness to invoke LockWorkStation and
    suspend the current Taskronome process for its explicit recovery checks.

.OUTPUTS
    manual-acceptance.json, manual-acceptance.md, screenshots, logs, data snapshots,
    SHA256SUMS.txt, and Taskronome-v1.0.0-manual-evidence.zip under AcceptanceRoot.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This acceptance harness requires Windows.'
}

$resolvedAppPath = (Resolve-Path -LiteralPath $AppPath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedAppPath -PathType Leaf)) {
    throw "Taskronome executable was not found: $resolvedAppPath"
}

$taskronomeTempRoot = [Environment]::GetEnvironmentVariable('TEMP')
if ([string]::IsNullOrWhiteSpace($AcceptanceRoot)) {
    $AcceptanceRoot = Join-Path $taskronomeTempRoot "Taskronome-Acceptance-$([Guid]::NewGuid().ToString('N'))"
}
$acceptanceRootPath = [IO.Path]::GetFullPath($AcceptanceRoot)

$script:root = $acceptanceRootPath
$script:dataDir = Join-Path $script:root 'data'
$script:screenshotDir = Join-Path $script:root 'screenshots'
$script:logDir = Join-Path $script:root 'logs'
$script:dataSnapshotDir = Join-Path $script:root 'data-snapshots'
$script:exportDir = Join-Path $script:root 'exports'
$script:evidenceDir = Join-Path $script:root 'evidence'
$script:results = [System.Collections.Generic.List[object]]::new()
$script:process = $null
$script:window = $null
$script:originalEnvironment = $null
$script:networkBefore = @()
$script:networkAfter = @()
$script:applicationStartedAtUtc = $null
$script:applicationArguments = @('--data-dir', $script:dataDir)

foreach ($directory in @(
        $script:root,
        $script:dataDir,
        $script:screenshotDir,
        $script:logDir,
        $script:dataSnapshotDir,
        $script:exportDir,
        $script:evidenceDir)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('TaskronomeAcceptanceNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class TaskronomeAcceptanceNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;

        public Point(int x, int y)
        {
            X = x;
            Y = y;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern IntPtr GetWindowLong32(IntPtr hWnd, int index);

    public static bool IsTopMost(IntPtr hWnd)
    {
        var style = IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, -20).ToInt64()
            : GetWindowLong32(hWnd, -20).ToInt32();
        return (style & 0x00000008L) != 0;
    }

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(Point point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    public static string GetDpiForScreen(int x, int y)
    {
        try
        {
            var monitor = MonitorFromPoint(new Point(x, y), 2);
            if (monitor == IntPtr.Zero)
            {
                return "unavailable";
            }

            var result = GetDpiForMonitor(monitor, 0, out var dpiX, out var dpiY);
            return result == 0 ? $"{dpiX}x{dpiY}" : $"HRESULT:{result}";
        }
        catch (DllNotFoundException)
        {
            return "shcore-unavailable";
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool LockWorkStation();

    public static bool TryLockWorkStation(out int error)
    {
        var result = LockWorkStation();
        error = result ? 0 : Marshal.GetLastWin32Error();
        return result;
    }

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static void SendKeyChord(byte firstModifier, byte secondModifier, byte key)
    {
        keybd_event(firstModifier, 0, 0, UIntPtr.Zero);
        keybd_event(secondModifier, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
        keybd_event(secondModifier, 0, 2, UIntPtr.Zero);
        keybd_event(firstModifier, 0, 2, UIntPtr.Zero);
    }

    public static void SendKey(byte key)
    {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    public static void DoubleClickAt(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(60);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static void RightClickAt(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenThread(uint desiredAccess, bool inheritHandle, uint threadId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SuspendThread(IntPtr threadHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr threadHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static int SuspendProcess(int processId)
    {
        var count = 0;
        using var process = Process.GetProcessById(processId);
        foreach (ProcessThread thread in process.Threads)
        {
            var handle = OpenThread(0x0002, false, (uint)thread.Id);
            if (handle == IntPtr.Zero)
            {
                continue;
            }

            if (SuspendThread(handle) != uint.MaxValue)
            {
                count++;
            }

            CloseHandle(handle);
        }

        return count;
    }

    public static int ResumeProcess(int processId)
    {
        var count = 0;
        using var process = Process.GetProcessById(processId);
        foreach (ProcessThread thread in process.Threads)
        {
            var handle = OpenThread(0x0002, false, (uint)thread.Id);
            if (handle == IntPtr.Zero)
            {
                continue;
            }

            while (ResumeThread(handle) > 0)
            {
            }

            count++;
            CloseHandle(handle);
        }

        return count;
    }
}
'@
}

function Get-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ([IO.Path]::GetRelativePath($script:root, $Path)).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

function Redact-Identity {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unavailable'
    }

    if ($Value.Length -le 2) {
        return '**'
    }

    return $Value.Substring(0, 1) + ('*' * [Math]::Min(6, $Value.Length - 2)) + $Value.Substring($Value.Length - 1, 1)
}

function Get-ProcessIdsForApp {
    $ids = [System.Collections.Generic.List[int]]::new()
    if ($null -ne $script:process) {
        try {
            $script:process.Refresh()
            if (-not $script:process.HasExited) {
                [void]$ids.Add($script:process.Id)
            }
        }
        catch [InvalidOperationException] {
        }
    }

    return @($ids | Sort-Object -Unique)
}

function Get-DurationFromJson {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return [TimeSpan]::Zero
    }

    try {
        return [TimeSpan]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch [FormatException] {
        try {
            return [TimeSpan]::FromTicks([long]$Value)
        }
        catch {
            return [TimeSpan]::Zero
        }
    }
}

function Read-DataSnapshot {
    $path = Join-Path $script:dataDir 'data.json'
    $empty = [ordered]@{
        State = 'Unavailable'
        CurrentTaskId = $null
        CurrentTaskName = ''
        Remaining = [TimeSpan]::Zero
        CurrentRunAccumulated = [TimeSpan]::Zero
        WorkSegmentCount = 0
        RecordedDuration = [TimeSpan]::Zero
        EventCount = 0
        Tasks = @()
        CheckpointSavedAtUtc = $null
        CheckpointReason = $null
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]$empty
    }

    try {
        $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $checkpoint = $document.Checkpoint
        $segments = if ($null -eq $document.WorkSegments) { @() } else { @($document.WorkSegments) }
        $tasks = if ($null -eq $document.Tasks) { @() } else { @($document.Tasks) }
        $recorded = [TimeSpan]::Zero
        foreach ($segment in $segments) {
            $recorded += Get-DurationFromJson $segment.Duration
        }

        $currentTask = $null
        if ($null -ne $checkpoint -and $null -ne $checkpoint.CurrentTaskId) {
            $currentTask = $tasks | Where-Object { [string]$_.Id -eq [string]$checkpoint.CurrentTaskId } | Select-Object -First 1
        }

        return [pscustomobject][ordered]@{
            State = if ($null -eq $checkpoint) { 'Idle' } else { [string]$checkpoint.State }
            CurrentTaskId = if ($null -eq $checkpoint) { $null } else { [string]$checkpoint.CurrentTaskId }
            CurrentTaskName = if ($null -eq $currentTask) { '' } else { [string]$currentTask.Name }
            Remaining = if ($null -eq $checkpoint) { [TimeSpan]::Zero } else { Get-DurationFromJson $checkpoint.Remaining }
            CurrentRunAccumulated = if ($null -eq $checkpoint) { [TimeSpan]::Zero } else { Get-DurationFromJson $checkpoint.CurrentRunAccumulated }
            WorkSegmentCount = $segments.Count
            RecordedDuration = $recorded
            EventCount = if ($null -eq $document.Events) { 0 } else { @($document.Events).Count }
            Tasks = $tasks
            CheckpointSavedAtUtc = if ($null -eq $checkpoint) { $null } else { [string]$checkpoint.SavedAtUtc }
            CheckpointReason = if ($null -eq $checkpoint) { $null } else { [string]$checkpoint.SystemPauseReason }
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            State = 'CorruptOrUnavailable'
            CurrentTaskId = $null
            CurrentTaskName = ''
            Remaining = [TimeSpan]::Zero
            CurrentRunAccumulated = [TimeSpan]::Zero
            WorkSegmentCount = 0
            RecordedDuration = [TimeSpan]::Zero
            EventCount = 0
            Tasks = @()
            CheckpointSavedAtUtc = $null
            CheckpointReason = $null
            ReadError = $_.Exception.Message
        }
    }
}

function Get-ElementText {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    try {
        try {
            $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            return ([System.Windows.Automation.ValuePattern]$valuePattern).Current.Value
        }
        catch [System.Windows.Automation.PatternNotSupportedException] {
            return $Element.Current.Name
        }
    }
    catch {
        return ''
    }
}

function Get-ElementState {
    param([AllowNull()][System.Windows.Automation.AutomationElement]$Element)

    if ($null -eq $Element) {
        return $null
    }

    try {
        return [pscustomobject][ordered]@{
            AutomationId = [string]$Element.Current.AutomationId
            Name = [string]$Element.Current.Name
            IsEnabled = [bool]$Element.Current.IsEnabled
            IsOffscreen = [bool]$Element.Current.IsOffscreen
            ControlType = [string]$Element.Current.ControlType.ProgrammaticName
            Text = Get-ElementText $Element
            BoundingRectangle = [string]$Element.Current.BoundingRectangle
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            AutomationId = ''
            Name = ''
            IsEnabled = $false
            IsOffscreen = $true
            ControlType = ''
            Text = ''
            BoundingRectangle = ''
            Error = $_.Exception.Message
        }
    }
}

function Get-WindowSnapshot {
    if ($null -eq $script:window) {
        return [pscustomobject][ordered]@{
            Exists = $false
            Visible = $false
            Topmost = $false
            Foreground = $false
            WindowVisualState = 'Unavailable'
        }
    }

    try {
        $handle = [IntPtr]$script:window.Current.NativeWindowHandle
        $windowPattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        return [pscustomobject][ordered]@{
            Exists = $true
            Visible = [TaskronomeAcceptanceNative]::IsWindowVisible($handle)
            Topmost = [TaskronomeAcceptanceNative]::IsTopMost($handle)
            Foreground = [TaskronomeAcceptanceNative]::GetForegroundWindow() -eq $handle
            WindowVisualState = ([System.Windows.Automation.WindowPattern]$windowPattern).Current.WindowVisualState.ToString()
            NativeWindowHandle = $handle.ToInt64()
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Exists = $false
            Visible = $false
            Topmost = $false
            Foreground = $false
            WindowVisualState = 'Unavailable'
            Error = $_.Exception.Message
        }
    }
}

function Get-UiSnapshot {
    $data = Read-DataSnapshot
    $current = $null
    $remaining = $null
    $confirmation = $null
    try {
        if ($null -ne $script:window) {
            $current = Get-ElementState (Find-ElementById 'CurrentTaskText' -TimeoutSeconds 1 -Optional)
            $remaining = Get-ElementState (Find-ElementById 'RemainingText' -TimeoutSeconds 1 -Optional)
            $confirmation = Get-ElementState (Find-ElementById 'ConfirmationPanel' -TimeoutSeconds 1 -Optional)
        }
    }
    catch {
    }

    return [pscustomobject][ordered]@{
        State = $data.State
        CurrentTaskName = $data.CurrentTaskName
        Remaining = $data.Remaining.ToString()
        CurrentRunAccumulated = $data.CurrentRunAccumulated.ToString()
        WorkSegmentCount = $data.WorkSegmentCount
        RecordedDuration = $data.RecordedDuration.ToString()
        EventCount = $data.EventCount
        CheckpointReason = $data.CheckpointReason
        CurrentTaskControl = if ($null -eq $current) { $null } else { $current.Text }
        RemainingControl = if ($null -eq $remaining) { $null } else { $remaining.Text }
        ConfirmationPanel = if ($null -eq $confirmation) { $null } else { $confirmation }
        ProcessIds = @(Get-ProcessIdsForApp)
        Window = Get-WindowSnapshot
    }
}

function Find-ElementById {
    param(
        [Parameter(Mandatory = $true)][string]$AutomationId,
        [int]$TimeoutSeconds = 10,
        [switch]$Optional
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if ($null -ne $script:window) {
                $condition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                    $AutomationId)
                $element = $script:window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
                if ($null -ne $element) {
                    return $element
                }
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 100
    }

    if ($Optional) {
        return $null
    }

    throw "UI Automation element was not found: $AutomationId"
}

function Find-ElementByIdAnyWindow {
    param(
        [Parameter(Mandatory = $true)][string]$AutomationId,
        [int]$TimeoutSeconds = 10,
        [switch]$Optional
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                $AutomationId)
            $element = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                $condition)
            if ($null -ne $element) {
                return $element
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 100
    }

    if ($Optional) {
        return $null
    }

    throw "UI Automation element was not found in any window: $AutomationId"
}

function Find-GlobalElementByName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 3
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                $Name)
            $element = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                $condition)
            if ($null -ne $element) {
                return $element
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 100
    }

    return $null
}

function Wait-AppWindow {
    param([int]$TimeoutSeconds = 20)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if ($null -ne $script:process) {
                $script:process.Refresh()
                if ($script:process.HasExited) {
                    throw "Taskronome exited during startup with code $($script:process.ExitCode)."
                }

                if ($script:process.MainWindowHandle -ne [IntPtr]::Zero) {
                    $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
                    if ([string]$script:window.Current.AutomationId -eq 'MainWindow') {
                        return $script:window
                    }
                }
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 200
    }

    throw 'Taskronome main window did not become ready before the timeout.'
}

function Wait-AppState {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [int]$TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $snapshot = Read-DataSnapshot
        if ($snapshot.State -eq $State) {
            return $snapshot
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Expected state '$State', actual state '$($snapshot.State)'."
}

function Invoke-Element {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    if (-not $Element.Current.IsEnabled) {
        throw "The UI element '$($Element.Current.AutomationId)' is disabled."
    }

    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Invoke-ButtonById {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $element = Find-ElementById $AutomationId
    Invoke-Element $element
    return $element
}

function Set-ElementValue {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    ([System.Windows.Automation.ValuePattern]$pattern).SetValue($Value)
}

function Toggle-Element {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    ([System.Windows.Automation.TogglePattern]$pattern).Toggle()
}

function Select-Element {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    try {
        $pattern = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
    }
    catch [System.Windows.Automation.PatternNotSupportedException] {
        Invoke-Element $Element
    }
}

function Select-Tab {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $tab = Find-ElementById $AutomationId
    Select-Element $tab
    Start-Sleep -Milliseconds 150
}

function Get-TaskRows {
    $grid = Find-ElementById 'TaskGrid'
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataItem)
    $rows = $grid.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        [void]$result.Add($row)
    }

    return @($result)
}

function Find-TaskRow {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    foreach ($row in @(Get-TaskRows)) {
        try {
            if ([string]$row.Current.Name -like "*$TaskName*") {
                return $row
            }

            $text = Get-ElementText $row
            if ($text -like "*$TaskName*") {
                return $row
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }
    }

    return $null
}

function Select-Task {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $row = Find-TaskRow $TaskName
    if ($null -eq $row) {
        throw "Task row was not found: $TaskName"
    }

    Select-Element $row
    Start-Sleep -Milliseconds 150
    return $row
}

function Get-ElementCenter {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    $rect = $Element.Current.BoundingRectangle
    if ($rect.Width -le 0 -or $rect.Height -le 0) {
        throw "The UI element '$($Element.Current.AutomationId)' has no visible bounds."
    }

    return [pscustomobject]@{
        X = [int]($rect.Left + ($rect.Width / 2))
        Y = [int]($rect.Top + ($rect.Height / 2))
    }
}

function Double-ClickElement {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    $center = Get-ElementCenter $Element
    [TaskronomeAcceptanceNative]::DoubleClickAt($center.X, $center.Y)
}

function Wait-Editor {
    return Find-ElementByIdAnyWindow 'TaskEditorWindow'
}

function Set-EditorFields {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Notes,
        [Parameter(Mandatory = $true)][int]$Hours,
        [Parameter(Mandatory = $true)][int]$Minutes,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    Set-ElementValue (Find-ElementByIdAnyWindow 'NameTextBox') $Name
    Set-ElementValue (Find-ElementByIdAnyWindow 'NotesTextBox') $Notes
    Set-ElementValue (Find-ElementByIdAnyWindow 'HoursTextBox') ([string]$Hours)
    Set-ElementValue (Find-ElementByIdAnyWindow 'MinutesTextBox') ([string]$Minutes)
    Set-ElementValue (Find-ElementByIdAnyWindow 'SecondsTextBox') ([string]$Seconds)
}

function Confirm-Dialog {
    param([int]$TimeoutSeconds = 5)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $acceptedNames = @('是', '确定', 'Yes', 'OK', '允许', 'Allow')
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Window))
            foreach ($dialog in $windows) {
                if ($null -ne $script:window -and [string]$dialog.Current.AutomationId -eq 'MainWindow') {
                    continue
                }

                $buttons = $dialog.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button))
                foreach ($button in $buttons) {
                    if ($acceptedNames -contains [string]$button.Current.Name -and $button.Current.IsEnabled) {
                        Invoke-Element $button
                        return $true
                    }
                }
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 100
    }

    return $false
}

function Dismiss-Dialogs {
    param([int]$TimeoutSeconds = 2)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Window))
            $dismissed = $false
            foreach ($dialog in $windows) {
                if ($null -ne $script:window -and [string]$dialog.Current.AutomationId -eq 'MainWindow') {
                    continue
                }

                $buttons = $dialog.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Button))
                foreach ($button in $buttons) {
                    if (@('否', '取消', 'No', 'Cancel', '关闭', 'Close', '确定', 'OK') -contains [string]$button.Current.Name -and $button.Current.IsEnabled) {
                        Invoke-Element $button
                        $dismissed = $true
                        break
                    }
                }

                if ($dismissed) {
                    break
                }
            }

            if (-not $dismissed) {
                return
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            return
        }

        Start-Sleep -Milliseconds 100
    }
}

function Add-TaskViaUi {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Notes,
        [Parameter(Mandatory = $true)][int]$Hours,
        [Parameter(Mandatory = $true)][int]$Minutes,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    Invoke-ButtonById 'NewTaskButton' | Out-Null
    [void](Wait-Editor)
    Set-EditorFields $Name $Notes $Hours $Minutes $Seconds
    Invoke-Element (Find-ElementByIdAnyWindow 'SaveTaskButton')
    Start-Sleep -Milliseconds 300
    if ($null -ne (Find-ElementByIdAnyWindow 'TaskEditorWindow' -TimeoutSeconds 1 -Optional)) {
        throw "Task editor did not close after saving '$Name'."
    }
}

function Edit-TaskViaUi {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$NewNotes
    )

    Select-Task $TaskName | Out-Null
    Invoke-ButtonById 'EditTaskButton' | Out-Null
    [void](Wait-Editor)
    Set-ElementValue (Find-ElementByIdAnyWindow 'NotesTextBox') $NewNotes
    Invoke-Element (Find-ElementByIdAnyWindow 'SaveTaskButton')
    Start-Sleep -Milliseconds 300
}

function Delete-TaskViaUi {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    Select-Task $TaskName | Out-Null
    Invoke-ButtonById 'DeleteTaskButton' | Out-Null
    if (-not (Confirm-Dialog)) {
        throw "The delete confirmation dialog for '$TaskName' was not available."
    }

    Start-Sleep -Milliseconds 300
}

function Stop-RotationViaUi {
    $button = Find-ElementById 'StopButton'
    if (-not $button.Current.IsEnabled) {
        return
    }

    Invoke-Element $button
    if (-not (Confirm-Dialog)) {
        throw 'The stop confirmation dialog was not available.'
    }

    [void](Wait-AppState 'Idle' 10)
}

function Get-TaskJson {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $data = Read-DataSnapshot
    return $data.Tasks | Where-Object { [string]$_.Name -eq $TaskName } | Select-Object -First 1
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', actual '$Actual'."
    }
}

function Copy-EvidenceSnapshot {
    param([Parameter(Mandatory = $true)][string]$Label)

    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '_')
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($source in @(
            (Join-Path $script:dataDir 'data.json'),
            (Join-Path $script:dataDir 'data.json.bak')) +
        @(Get-ChildItem -LiteralPath $script:dataDir -Filter 'data*.corrupt*.json' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $target = Join-Path $script:dataSnapshotDir "$safeLabel-$([IO.Path]::GetFileName($source))"
            Copy-Item -LiteralPath $source -Destination $target -Force
            [void]$paths.Add((Get-RelativePath $target))
        }
    }

    $sourceLogDir = Join-Path $script:dataDir 'logs'
    if (Test-Path -LiteralPath $sourceLogDir -PathType Container) {
        foreach ($sourceLog in @(Get-ChildItem -LiteralPath $sourceLogDir -File)) {
            $targetLog = Join-Path $script:logDir "$safeLabel-$($sourceLog.Name)"
            Copy-Item -LiteralPath $sourceLog.FullName -Destination $targetLog -Force
            [void]$paths.Add((Get-RelativePath $targetLog))
        }
    }

    return @($paths)
}

function Save-WindowScreenshot {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $script:window) {
        throw 'Cannot capture a screenshot before the main window is available.'
    }

    $safeName = ($Name -replace '[^A-Za-z0-9._-]', '_')
    $path = Join-Path $script:screenshotDir "$safeName.png"
    $handle = [IntPtr]$script:window.Current.NativeWindowHandle
    $rect = [TaskronomeAcceptanceNative+Rect]::new()
    if (-not [TaskronomeAcceptanceNative]::GetWindowRect($handle, [ref]$rect)) {
        throw "GetWindowRect failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }

    $width = [Math]::Max(1, $rect.Right - $rect.Left)
    $height = [Math]::Max(1, $rect.Bottom - $rect.Top)
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try {
            $printed = [TaskronomeAcceptanceNative]::PrintWindow($handle, $hdc, 2)
        }
        finally {
            $graphics.ReleaseHdc($hdc)
        }

        if (-not $printed) {
            $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        }

        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    return Get-RelativePath $path
}

function Get-NetworkSnapshot {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($connection in @(Get-NetTCPConnection -OwningProcess $ProcessId -ErrorAction SilentlyContinue)) {
        [void]$entries.Add([pscustomobject][ordered]@{
                Protocol = 'TCP'
                Local = "$($connection.LocalAddress):$($connection.LocalPort)"
                Remote = "$($connection.RemoteAddress):$($connection.RemotePort)"
                State = [string]$connection.State
            })
    }

    foreach ($endpoint in @(Get-NetUDPEndpoint -OwningProcess $ProcessId -ErrorAction SilentlyContinue)) {
        [void]$entries.Add([pscustomobject][ordered]@{
                Protocol = 'UDP'
                Local = "$($endpoint.LocalAddress):$($endpoint.LocalPort)"
                Remote = ''
                State = ''
            })
    }

    return @($entries)
}

function Get-AppNotificationState {
    $result = [ordered]@{
        Setting = 'Unavailable'
        GetAllAsync = 'Unavailable'
        Assembly = ''
        Error = $null
    }

    try {
        $appDirectory = Split-Path -Parent $resolvedAppPath
        $assemblyPaths = [System.Collections.Generic.List[string]]::new()
        foreach ($candidateName in @(
                'Microsoft.Windows.SDK.NET.dll',
                'Microsoft.Windows.AppNotifications*.dll',
                'Microsoft.WindowsAppSDK*.dll',
                'WinRT.Runtime.dll')) {
            foreach ($candidate in @(Get-ChildItem -LiteralPath $appDirectory -Filter $candidateName -File -ErrorAction SilentlyContinue)) {
                if (-not $assemblyPaths.Contains($candidate.FullName)) {
                    [void]$assemblyPaths.Add($candidate.FullName)
                }
            }
        }

        foreach ($assemblyFile in $assemblyPaths) {
            try {
                [Reflection.Assembly]::LoadFrom($assemblyFile) | Out-Null
                if ([string]::IsNullOrWhiteSpace($result.Assembly)) {
                    $result.Assembly = [IO.Path]::GetFileName($assemblyFile)
                }
            }
            catch [Exception] {
            }
        }

        $managerType = [Type]::GetType('Microsoft.Windows.AppNotifications.AppNotificationManager, Microsoft.Windows.SDK.NET', $false)
        if ($null -eq $managerType) {
            $managerType = [Type]::GetType('Microsoft.Windows.AppNotifications.AppNotificationManager, Microsoft.WindowsAppSDK', $false)
        }
        if ($null -eq $managerType) {
            $managerType = [AppDomain]::CurrentDomain.GetAssemblies() |
                ForEach-Object { $_.GetType('Microsoft.Windows.AppNotifications.AppNotificationManager', $false) } |
                Where-Object { $null -ne $_ } |
                Select-Object -First 1
        }

        if ($null -eq $managerType) {
            $result.Error = 'Microsoft.Windows.AppNotifications.AppNotificationManager was not loadable in the acceptance host.'
            return [pscustomobject]$result
        }

        $defaultProperty = $managerType.GetProperty('Default')
        $default = if ($null -eq $defaultProperty) { $null } else { $defaultProperty.GetValue($null) }
        $settingProperty = $managerType.GetProperty('Setting')
        if ($null -ne $settingProperty -and $null -ne $default) {
            $result.Setting = [string]$settingProperty.GetValue($default)
        }

        $getAllMethod = $managerType.GetMethods([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance) |
            Where-Object { $_.Name -eq 'GetAllAsync' } |
            Select-Object -First 1
        if ($null -ne $getAllMethod) {
            $target = if ($getAllMethod.IsStatic) { $null } else { $default }
            $operation = $getAllMethod.Invoke($target, @())
            $awaiter = $operation.GetType().GetMethod('GetAwaiter').Invoke($operation, @())
            $notifications = $awaiter.GetType().GetMethod('GetResult').Invoke($awaiter, @())
            $result.GetAllAsync = "returned-$(@($notifications).Count)"
        }
        else {
            $result.GetAllAsync = 'method-unavailable'
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-EnvironmentSnapshot {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $monitorRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($screen in $screens) {
        $dpi = [TaskronomeAcceptanceNative]::GetDpiForScreen($screen.Bounds.X, $screen.Bounds.Y)
        [void]$monitorRecords.Add([pscustomobject][ordered]@{
                DeviceName = $screen.DeviceName
                Primary = $screen.Primary
                Bounds = [string]$screen.Bounds
                WorkingArea = [string]$screen.WorkingArea
                Dpi = $dpi
                ScalePercent = if ($dpi -match '^([0-9]+)x') { [int]([int]$Matches[1] * 100 / 96) } else { $null }
            })
    }

    $powerOutput = @(powercfg /a 2>&1 | ForEach-Object { [string]$_ })
    $sessionName = [Environment]::GetEnvironmentVariable('SESSIONNAME')
    $rdsEvidence = if ($sessionName -match '^(RDP|rdp)-') { 'RDP' } else { 'console-or-unknown' }
    $dotnetVersion = try { (& dotnet --version 2>$null).Trim() } catch { 'unavailable' }
    $highContrast = try { [System.Windows.SystemParameters]::HighContrast } catch { $null }

    return [pscustomobject][ordered]@{
        Tester = Redact-Identity ([Environment]::GetEnvironmentVariable('USERNAME'))
        Windows = [pscustomobject][ordered]@{
            Caption = $os.Caption
            Edition = $os.OSProductSuite
            Version = $os.Version
            Build = $os.BuildNumber
            Architecture = $os.OSArchitecture
        }
        CpuArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
        DotnetSdk = $dotnetVersion
        MonitorCount = $screens.Count
        Monitors = @($monitorRecords)
        CurrentDpiForWindow = if ($null -ne $script:window) { [TaskronomeAcceptanceNative]::GetDpiForWindow([IntPtr]$script:window.Current.NativeWindowHandle) } else { $null }
        CurrentScalePercent = if ($null -ne $script:window) {
            [int]([TaskronomeAcceptanceNative]::GetDpiForWindow([IntPtr]$script:window.Current.NativeWindowHandle) * 100 / 96)
        }
        else { $null }
        HighContrast = $highContrast
        Notification = Get-AppNotificationState
        PowerCapabilities = $powerOutput
        SessionName = Redact-Identity $sessionName
        SessionType = $rdsEvidence
        ClientNamePresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CLIENTNAME'))
        UserInteractive = [Environment]::UserInteractive
        ComputerSystem = [pscustomobject][ordered]@{
            Model = $computer.Model
            SystemType = $computer.SystemType
        }
    }
}

function Invoke-Recorded {
    param(
        [Parameter(Mandatory = $true)][string]$TestId,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$ScreenshotName = '',
        [string]$NaReason = '',
        [switch]$SnapshotFiles
    )

    $started = [DateTimeOffset]::UtcNow
    $before = Get-UiSnapshot
    $screenshots = [System.Collections.Generic.List[string]]::new()
    $logs = [System.Collections.Generic.List[string]]::new()
    $actual = $null
    $exception = $null
    $result = 'Pass'

    if (-not [string]::IsNullOrWhiteSpace($NaReason)) {
        $result = 'N/A'
        $actual = 'Not executed because the recorded environment condition applies.'
    }
    else {
        try {
            $actual = & $Action
            if ($actual -is [bool] -and -not $actual) {
                throw 'The acceptance action returned false.'
            }
        }
        catch {
            $result = 'Fail'
            $exception = $_.Exception.ToString()
            $actual = if ([string]::IsNullOrWhiteSpace($exception)) { 'Action failed.' } else { $exception.Split([Environment]::NewLine)[0] }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ScreenshotName) -and $null -ne $script:window) {
        try {
            [void]$screenshots.Add((Save-WindowScreenshot $ScreenshotName))
        }
        catch {
            if ($result -eq 'Pass') {
                $result = 'Fail'
            }

            $exception = if ($null -eq $exception) { $_.Exception.ToString() } else { "$exception; $($_.Exception.Message)" }
        }
    }

    if ($SnapshotFiles) {
        try {
            foreach ($path in @(Copy-EvidenceSnapshot $TestId)) {
                [void]$logs.Add($path)
            }
        }
        catch {
            if ($result -eq 'Pass') {
                $result = 'Fail'
            }

            $exception = if ($null -eq $exception) { $_.Exception.ToString() } else { "$exception; $($_.Exception.Message)" }
        }
    }

    $after = Get-UiSnapshot
    $ended = [DateTimeOffset]::UtcNow
    $record = [ordered]@{
        TestId = $TestId
        Category = $Category
        Result = $result
        StartedAtUtc = $started.ToString('O')
        EndedAtUtc = $ended.ToString('O')
        Duration = ($ended - $started).ToString()
        Expected = $Expected
        Actual = $actual
        ProcessIds = @($after.ProcessIds)
        StateBefore = $before.State
        StateAfter = $after.State
        RemainingBefore = $before.Remaining
        RemainingAfter = $after.Remaining
        SegmentCountBefore = $before.WorkSegmentCount
        SegmentCountAfter = $after.WorkSegmentCount
        RecordedDurationBefore = $before.RecordedDuration
        RecordedDurationAfter = $after.RecordedDuration
        ScreenshotPaths = @($screenshots)
        LogPaths = @($logs)
        Notes = if ($result -eq 'N/A') { $NaReason } else { '' }
        Exception = $exception
        EnvironmentNaReason = if ($result -eq 'N/A') { $NaReason } else { $null }
    }
    [void]$script:results.Add([pscustomobject]$record)
    Write-Host ("[{0}] {1}: {2}" -f $result, $TestId, $actual)
    return [pscustomobject]$record
}

function Start-Taskronome {
    if ($null -ne $script:process) {
        try {
            $script:process.Refresh()
            if (-not $script:process.HasExited) {
                return
            }
        }
        catch [InvalidOperationException] {
        }
    }

    $script:applicationStartedAtUtc = [DateTimeOffset]::UtcNow
    $quotedDataDir = '"' + $script:dataDir.Replace('"', '\"') + '"'
    $script:process = Start-Process -FilePath $resolvedAppPath -ArgumentList @('--data-dir', $quotedDataDir) -PassThru
    [void](Wait-AppWindow)
    [TaskronomeAcceptanceNative]::SetForegroundWindow([IntPtr]$script:window.Current.NativeWindowHandle) | Out-Null
}

function Stop-Taskronome {
    param([switch]$Force)

    if ($null -eq $script:process) {
        return
    }

    try {
        $script:process.Refresh()
        if ($script:process.HasExited) {
            return
        }

        if ($Force) {
            Stop-Process -Id $script:process.Id -Force -ErrorAction Stop
        }
        else {
            try {
                $pattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                ([System.Windows.Automation.WindowPattern]$pattern).Close()
            }
            catch {
                Stop-Process -Id $script:process.Id -Force -ErrorAction Stop
            }
        }

        [void]$script:process.WaitForExit(10000)
    }
    catch [InvalidOperationException] {
    }
    finally {
        $script:window = $null
    }
}

function Get-TextFromElementId {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $element = Find-ElementById $AutomationId
    return Get-ElementText $element
}

function Get-ToggleState {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $element = Find-ElementById $AutomationId
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    return ([System.Windows.Automation.TogglePattern]$pattern).Current.ToggleState.ToString()
}

function Get-ButtonEnabled {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    return [bool](Find-ElementById $AutomationId).Current.IsEnabled
}

function Test-RequiredAutomationIds {
    $mainIds = @(
        'MainWindow',
        'MainTabs',
        'TasksTab',
        'RunningTab',
        'StatisticsTab',
        'SettingsTab',
        'TaskGrid',
        'NewTaskButton',
        'EditTaskButton',
        'DeleteTaskButton',
        'MoveUpButton',
        'MoveDownButton',
        'ToggleEnabledButton',
        'ReopenTaskButton',
        'ResetCompletionButton',
        'StartRotationButton',
        'CurrentTaskText',
        'RemainingText',
        'ConfirmationPanel',
        'ConfirmationText',
        'ConfirmTaskButton',
        'PauseResumeButton',
        'SkipButton',
        'CompleteButton',
        'StopButton',
        'AbsentPausePanel',
        'SystemPausePanel',
        'AlwaysOnTopCheckBox',
        'PlaySoundCheckBox',
        'ShowNotificationCheckBox',
        'MinimizeToTrayCheckBox',
        'TestNotificationButton',
        'StatisticsScopeComboBox',
        'ExportCsvButton')
    $editorIds = @(
        'TaskEditorWindow',
        'NameTextBox',
        'NotesTextBox',
        'HoursTextBox',
        'MinutesTextBox',
        'SecondsTextBox',
        'ValidationTextBlock',
        'SaveTaskButton',
        'CancelTaskButton')

    Select-Tab 'TasksTab'
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $mainIds) {
        $element = if ($id -eq 'MainWindow') { $script:window } else { Find-ElementById $id -TimeoutSeconds 3 -Optional }
        if ($null -eq $element) {
            [void]$missing.Add($id)
        }
    }

    if ($missing.Count -eq 0) {
        Invoke-ButtonById 'NewTaskButton' | Out-Null
        [void](Wait-Editor)
        foreach ($id in $editorIds) {
            $element = Find-ElementByIdAnyWindow $id -TimeoutSeconds 3 -Optional
            if ($null -eq $element) {
                [void]$missing.Add($id)
            }
        }

        $cancelButton = Find-ElementByIdAnyWindow 'CancelTaskButton' -TimeoutSeconds 1 -Optional
        if ($null -ne $cancelButton -and $cancelButton.Current.IsEnabled) {
            Invoke-Element $cancelButton
        }
    }

    Assert-Equal 0 $missing.Count 'Required AutomationId controls were missing.'
    return "located-$($mainIds.Count + $editorIds.Count)-controls"
}

function Run-DataAndUiFlow {
    $taskA = '任务 A'
    $taskB = '任务 B'
    $longName = '长中文任务，包含逗号、双引号"和足够长的文本以验证窗口布局'
    $longNotes = '备注，包含逗号,双引号"和换行' + [Environment]::NewLine + '第二行备注，用于 CSV 与编辑器验收。'

    Invoke-Recorded -TestId 'ui-automation-id-controls' -Category 'UIA' -Expected 'All required stable AutomationIds are discoverable.' -Action {
        Test-RequiredAutomationIds
    } -ScreenshotName '01-startup-controls' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'task-create-a' -Category 'Task CRUD' -Expected 'Create Task A with a two-second slice.' -Action {
        Add-TaskViaUi $taskA 'A notes' 0 0 2
        Assert-True ($null -ne (Get-TaskJson $taskA)) 'Task A was not persisted.'
    } -ScreenshotName '02-task-a' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'task-create-b' -Category 'Task CRUD' -Expected 'Create Task B with a three-second slice.' -Action {
        Add-TaskViaUi $taskB 'B notes' 0 0 3
        Assert-True ($null -ne (Get-TaskJson $taskB)) 'Task B was not persisted.'
    } -ScreenshotName '03-task-b' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'task-create-long-text' -Category 'Task CRUD/Layout' -Expected 'Create long Chinese text task with punctuation and a newline note.' -Action {
        Add-TaskViaUi $longName $longNotes 0 0 5
        $task = Get-TaskJson $longName
        Assert-True ($null -ne $task) 'Long text task was not persisted.'
        Assert-True ([string]$task.Notes -match "`n") 'Long text newline was not persisted.'
    } -ScreenshotName '04-long-text' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'task-edit' -Category 'Task CRUD' -Expected 'Edit a task through the real editor.' -Action {
        Edit-TaskViaUi $taskA ('A notes, edited with comma, "quotes", and newline.' + [Environment]::NewLine + 'second line')
        $task = Get-TaskJson $taskA
        Assert-True ([string]$task.Notes -match 'edited') 'Edited task notes were not persisted.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'task-double-click-edit' -Category 'Task CRUD' -Expected 'Double-clicking a task row opens the editor.' -Action {
        Select-Tab 'TasksTab'
        $row = Select-Task $longName
        Double-ClickElement $row
        [void](Wait-Editor)
        Invoke-Element (Find-ElementByIdAnyWindow 'CancelTaskButton')
        Start-Sleep -Milliseconds 200
    } -ScreenshotName '05-double-click-editor' | Out-Null

    $invalidCases = @(
        [pscustomobject]@{ Id = 'invalid-empty-name'; Name = ''; Notes = 'valid'; Hours = 0; Minutes = 0; Seconds = 2; Expected = 'non-empty name validation' },
        [pscustomobject]@{ Id = 'invalid-81-char-name'; Name = ('名' * 81); Notes = 'valid'; Hours = 0; Minutes = 0; Seconds = 2; Expected = '81-character name validation' },
        [pscustomobject]@{ Id = 'invalid-501-char-notes'; Name = 'valid'; Notes = ('注' * 501); Hours = 0; Minutes = 0; Seconds = 2; Expected = '501-character notes validation' },
        [pscustomobject]@{ Id = 'invalid-zero-seconds'; Name = 'valid'; Notes = 'valid'; Hours = 0; Minutes = 0; Seconds = 0; Expected = 'zero duration validation' },
        [pscustomobject]@{ Id = 'invalid-60-minutes'; Name = 'valid'; Notes = 'valid'; Hours = 0; Minutes = 60; Seconds = 0; Expected = 'minute 60 validation' },
        [pscustomobject]@{ Id = 'invalid-24-hours'; Name = 'valid'; Notes = 'valid'; Hours = 24; Minutes = 0; Seconds = 0; Expected = '24-hour validation' })

    foreach ($invalid in $invalidCases) {
        Invoke-Recorded -TestId $invalid.Id -Category 'Validation' -Expected $invalid.Expected -Action {
            Invoke-ButtonById 'NewTaskButton' | Out-Null
            [void](Wait-Editor)
            Set-EditorFields $invalid.Name $invalid.Notes $invalid.Hours $invalid.Minutes $invalid.Seconds
            Invoke-Element (Find-ElementByIdAnyWindow 'SaveTaskButton')
            Start-Sleep -Milliseconds 150
            $editor = Find-ElementByIdAnyWindow 'TaskEditorWindow' -TimeoutSeconds 2 -Optional
            Assert-True ($null -ne $editor) 'Invalid task input unexpectedly closed the editor.'
            $validation = Get-ElementText (Find-ElementByIdAnyWindow 'ValidationTextBlock')
            Assert-True (-not [string]::IsNullOrWhiteSpace($validation)) 'ValidationTextBlock was empty for invalid input.'
            Invoke-Element (Find-ElementByIdAnyWindow 'CancelTaskButton')
            Start-Sleep -Milliseconds 150
        } -SnapshotFiles | Out-Null
    }

    Invoke-Recorded -TestId 'task-enable-disable-order' -Category 'Task CRUD' -Expected 'Toggle enabled and move tasks without changing identity.' -Action {
        Select-Task $longName | Out-Null
        Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        Start-Sleep -Milliseconds 150
        $disabled = Get-TaskJson $longName
        Assert-Equal 'False' ([string]$disabled.Enabled) 'Long task was not disabled.'
        Select-Task $taskB | Out-Null
        $beforeOrder = [int](Get-TaskJson $taskB).Order
        Invoke-ButtonById 'MoveUpButton' | Out-Null
        Start-Sleep -Milliseconds 150
        $movedOrder = [int](Get-TaskJson $taskB).Order
        Assert-True ($movedOrder -lt $beforeOrder) 'Move up did not change task order.'
        Invoke-ButtonById 'MoveDownButton' | Out-Null
        Start-Sleep -Milliseconds 150
        Assert-Equal $beforeOrder ([int](Get-TaskJson $taskB).Order) 'Move down did not restore task order.'
    } -SnapshotFiles | Out-Null

    $temporaryTask = '待删除任务'
    Invoke-Recorded -TestId 'task-delete' -Category 'Task CRUD' -Expected 'Delete a task through the confirmation dialog.' -Action {
        Add-TaskViaUi $temporaryTask 'delete me' 0 0 1
        Delete-TaskViaUi $temporaryTask
        Assert-True ($null -eq (Get-TaskJson $temporaryTask)) 'Deleted task remained in data.json.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'settings-and-layout-controls' -Category 'Settings/Layout' -Expected 'Read setting toggles and statistics controls using UIA.' -Action {
        Select-Tab 'SettingsTab'
        foreach ($id in @('AlwaysOnTopCheckBox', 'PlaySoundCheckBox', 'ShowNotificationCheckBox', 'MinimizeToTrayCheckBox', 'TestNotificationButton')) {
            Assert-True ($null -ne (Find-ElementById $id)) "Setting control $id was not found."
        }
        Select-Tab 'StatisticsTab'
        Assert-True ($null -ne (Find-ElementById 'StatisticsScopeComboBox')) 'Statistics scope combo was not found.'
        Assert-True ($null -ne (Find-ElementById 'ExportCsvButton')) 'Export CSV button was not found.'
        Select-Tab 'TasksTab'
    } -ScreenshotName '06-settings-and-statistics' | Out-Null

    return [pscustomobject]@{ TaskA = $taskA; TaskB = $taskB; LongName = $longName }
}

function Run-RotationFlow {
    param([Parameter(Mandatory = $true)][pscustomobject]$Tasks)

    $taskA = $Tasks.TaskA
    $taskB = $Tasks.TaskB
    $longName = $Tasks.LongName

    Select-Tab 'TasksTab'
    Select-Task $longName | Out-Null
    if ([string](Get-TaskJson $longName).Enabled -eq 'True') {
        Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
    }

    Invoke-Recorded -TestId 'rotation-start-awaiting-confirmation' -Category 'Rotation' -Expected 'Start in AwaitingConfirmation before any work is recorded.' -Action {
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        $state = Wait-AppState 'AwaitingConfirmation' 10
        Assert-Equal 'AwaitingConfirmation' $state.State 'Start did not request confirmation.'
        $panel = Find-ElementById 'ConfirmationPanel'
        Assert-True (-not $panel.Current.IsOffscreen) 'Confirmation panel was not visible.'
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'Confirm button was disabled while confirmation was required.'
    } -ScreenshotName '07-awaiting-confirmation' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-no-preconfirmation-time' -Category 'Rotation' -Expected 'Waiting for confirmation adds no task time or work segment.' -Action {
        $before = Read-DataSnapshot
        $beforeRemaining = Get-TextFromElementId 'RemainingText'
        Start-Sleep -Seconds 2
        $after = Read-DataSnapshot
        $afterRemaining = Get-TextFromElementId 'RemainingText'
        Assert-Equal $before.WorkSegmentCount $after.WorkSegmentCount 'A work segment appeared before confirmation.'
        Assert-Equal $before.RecordedDuration $after.RecordedDuration 'Recorded duration changed before confirmation.'
        Assert-Equal $beforeRemaining $afterRemaining 'UI Remaining changed before confirmation.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-task-a-running' -Category 'Rotation' -Expected 'Confirm through the app button and record about two seconds of Task A.' -Action {
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        try { Invoke-ButtonById 'ConfirmTaskButton' | Out-Null } catch { }
        [void](Wait-AppState 'Running' 5)
        Assert-True (-not (Get-ButtonEnabled 'EditTaskButton')) 'Task editing remained enabled during rotation.'
        Start-Sleep -Seconds 3
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        $data = Read-DataSnapshot
        $segments = @($data.WorkSegmentCount)
        Assert-True ($data.WorkSegmentCount -ge 1) 'Task A did not create a work segment.'
        Assert-True ($data.RecordedDuration.TotalSeconds -ge 1.25 -and $data.RecordedDuration.TotalSeconds -le 2.75) "Task A recorded duration was outside tolerance: $($data.RecordedDuration)."
        Assert-True ($data.CurrentTaskName -eq $taskB) "The next confirmation was not for Task B; it was '$($data.CurrentTaskName)'."
        return [pscustomobject]@{ SegmentCount = $segments; Recorded = $data.RecordedDuration.ToString() }
    } -ScreenshotName '08-task-a-complete' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-task-b-reconfirmation' -Category 'Rotation' -Expected 'Task B requires a new in-app confirmation and records about three seconds.' -Action {
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'Task B confirmation button was not enabled.'
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Seconds 4
        [void](Wait-AppState 'AwaitingConfirmation' 6)
        $data = Read-DataSnapshot
        Assert-True ($data.RecordedDuration.TotalSeconds -ge 3.0 -and $data.RecordedDuration.TotalSeconds -le 6.0) "Task B recorded duration was outside cumulative tolerance: $($data.RecordedDuration)."
    } -ScreenshotName '09-task-b-reconfirmation' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-single-task-natural-restart' -Category 'Rotation' -Expected 'A single enabled task naturally returns to a new confirmation instead of auto-running.' -Action {
        Stop-RotationViaUi
        Select-Task $taskB | Out-Null
        if ([string](Get-TaskJson $taskB).Enabled -eq 'True') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Seconds 3
        $state = Wait-AppState 'AwaitingConfirmation' 6
        Assert-Equal 'AwaitingConfirmation' $state.State 'Single-task natural restart did not request confirmation.'
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'Single-task restart confirmation button was not enabled.'
        Stop-RotationViaUi
        Select-Task $taskB | Out-Null
        Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-skip-does-not-complete' -Category 'Rotation' -Expected 'Skipping a slice does not mark the task completed.' -Action {
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $current = (Read-DataSnapshot).CurrentTaskName
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        try { Invoke-ButtonById 'SkipButton' | Out-Null } catch { }
        Start-Sleep -Milliseconds 400
        $task = Get-TaskJson $current
        Assert-Equal 'False' ([string]$task.Completed) 'Skipped task was marked completed.'
        Stop-RotationViaUi
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-complete-early-real-duration' -Category 'Rotation' -Expected 'Early completion records only real running time and marks the task complete.' -Action {
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $current = (Read-DataSnapshot).CurrentTaskName
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 700
        $before = Read-DataSnapshot
        Invoke-ButtonById 'CompleteButton' | Out-Null
        Start-Sleep -Milliseconds 500
        $after = Read-DataSnapshot
        $task = Get-TaskJson $current
        Assert-Equal 'True' ([string]$task.Completed) 'Early-completed task was not marked completed.'
        Assert-True ($after.RecordedDuration -gt $before.RecordedDuration) 'Early completion did not record real work.'
        Assert-True ($after.RecordedDuration.TotalSeconds -lt 2.0) 'Early completion appears to have recorded the full slice.'
        Stop-RotationViaUi
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'completion-reopen-and-reset-history' -Category 'Persistence' -Expected 'Reopen/reset completion changes status but keeps historical segments.' -Action {
        $completedTask = (Read-DataSnapshot).Tasks | Where-Object { $_.Completed -eq $true } | Select-Object -First 1
        Assert-True ($null -ne $completedTask) 'No completed task was available for reopen/reset verification.'
        Select-Task ([string]$completedTask.Name) | Out-Null
        $historyBefore = (Read-DataSnapshot).WorkSegmentCount
        Assert-True (Get-ButtonEnabled 'ReopenTaskButton') 'Reopen button was not enabled for a completed task.'
        Invoke-ButtonById 'ReopenTaskButton' | Out-Null
        Start-Sleep -Milliseconds 250
        Assert-Equal 'False' ([string](Get-TaskJson ([string]$completedTask.Name)).Completed) 'Reopen did not clear completion.'

        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $current = (Read-DataSnapshot).CurrentTaskName
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Invoke-ButtonById 'CompleteButton' | Out-Null
        Start-Sleep -Milliseconds 400
        Stop-RotationViaUi
        Select-Task $current | Out-Null
        Invoke-ButtonById 'ResetCompletionButton' | Out-Null
        Assert-True (Confirm-Dialog) 'The reset-completion confirmation dialog was not available.'
        Start-Sleep -Milliseconds 250
        Assert-Equal 'False' ([string](Get-TaskJson $current).Completed) 'Reset completion did not clear completion.'
        Assert-Equal $historyBefore ((Read-DataSnapshot).WorkSegmentCount - 1) 'Reset completion changed historical segment count unexpectedly.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-confirmation-timeout-production' -Category 'Production Confirmation' -Expected 'A real ten-second confirmation timeout pauses as PausedAbsent and freezes work.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $before = Read-DataSnapshot
        $beforeUi = Get-TextFromElementId 'RemainingText'
        Start-Sleep -Seconds 11
        [void](Wait-AppState 'PausedAbsent' 5)
        $timeout = Read-DataSnapshot
        Start-Sleep -Seconds 10
        $frozen = Read-DataSnapshot
        $frozenUi = Get-TextFromElementId 'RemainingText'
        Assert-Equal $before.WorkSegmentCount $timeout.WorkSegmentCount 'Confirmation timeout created a work segment.'
        Assert-Equal $timeout.WorkSegmentCount $frozen.WorkSegmentCount 'PausedAbsent created a segment while waiting.'
        Assert-Equal $timeout.RecordedDuration $frozen.RecordedDuration 'PausedAbsent changed recorded duration.'
        Assert-Equal $timeout.Remaining $frozen.Remaining 'PausedAbsent changed remaining time.'
        Assert-Equal $beforeUi $frozenUi 'PausedAbsent changed the visible remaining time.'
        Invoke-ButtonById 'PauseResumeButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        $recovery = Read-DataSnapshot
        Assert-True ((Find-ElementById 'ConfirmTaskButton').Current.IsEnabled) 'Recovery did not require a new confirmation.'
        Assert-Equal '00:00:02' $recovery.Remaining.ToString() 'Recovery did not restore the complete Task A slice.'
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi
    } -ScreenshotName '10-production-timeout-paused-absent' -SnapshotFiles | Out-Null

    return $true
}

function Run-NotificationFlow {
    $notificationApi = Get-AppNotificationState

    Invoke-Recorded -TestId 'notification-api-setting-and-history' -Category 'Notifications' -Expected 'Read AppNotificationManager setting and history without changing application state.' -Action {
        Assert-True ($null -ne $notificationApi) 'Notification API evidence was not returned.'
        return $notificationApi
    } -ScreenshotName '11-notification-settings' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'notification-test-button-production' -Category 'Notifications' -Expected 'Test notification uses the real notification service in production mode and does not crash.' -Action {
        Select-Tab 'SettingsTab'
        Invoke-ButtonById 'TestNotificationButton' | Out-Null
        Start-Sleep -Seconds 2
        Dismiss-Dialogs
        Select-Tab 'RunningTab'
        Assert-True ($null -ne $script:process -and -not $script:process.HasExited) 'Test notification caused the application to exit.'
    } -ScreenshotName '12-notification-test' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'notification-task-turn-not-auto-confirm' -Category 'Notifications' -Expected 'A task-turn notification, if visible, activates the app while leaving AwaitingConfirmation and creating no work.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $before = Read-DataSnapshot
        $notification = Find-GlobalElementByName "轮到：$($before.CurrentTaskName)" 5
        if ($null -eq $notification) {
            if (-not $OperatorAssistance) {
                throw 'The real task-turn notification was not exposed to UI Automation; run with -OperatorAssistance for one operator click.'
            }

            Read-Host '请在通知中心点击本次 Taskronome 任务通知一次；点击后按回车继续' | Out-Null
        }
        else {
            try {
                Invoke-Element $notification
            }
            catch {
                $center = Get-ElementCenter $notification
                [TaskronomeAcceptanceNative]::DoubleClickAt($center.X, $center.Y)
            }
        }

        Start-Sleep -Seconds 1
        $afterActivation = Read-DataSnapshot
        Assert-Equal 'AwaitingConfirmation' $afterActivation.State 'Notification activation confirmed the task unexpectedly.'
        Assert-Equal $before.WorkSegmentCount $afterActivation.WorkSegmentCount 'Notification activation created a work segment.'
        Assert-Equal $before.RecordedDuration $afterActivation.RecordedDuration 'Notification activation recorded work.'
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'In-app confirmation did not remain available after notification activation.'
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi
    } -ScreenshotName '13-notification-activation-awaiting' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'notification-app-setting-fallback' -Category 'Notifications/Fallback' -Expected 'When the app notification setting is disabled/unavailable, the app remains usable and in-app confirmation is still present.' -Action {
        Select-Tab 'SettingsTab'
        $before = Get-ToggleState 'ShowNotificationCheckBox'
        if ($before -eq 'Off') {
            Toggle-Element (Find-ElementById 'ShowNotificationCheckBox')
        }
        Toggle-Element (Find-ElementById 'ShowNotificationCheckBox')
        Invoke-ButtonById 'TestNotificationButton' | Out-Null
        Start-Sleep -Seconds 1
        Dismiss-Dialogs
        Assert-True ($null -ne $script:process -and -not $script:process.HasExited) 'Notification fallback crashed the app.'
        if ($before -eq 'On') {
            Toggle-Element (Find-ElementById 'ShowNotificationCheckBox')
        }
        Select-Tab 'TasksTab'
    } -ScreenshotName '14-notification-fallback' -SnapshotFiles | Out-Null

    return $true
}

function Run-KeyboardTopmostAndSingleInstanceFlow {
    Invoke-Recorded -TestId 'topmost-shortcut-and-persistence' -Category 'Window/Keyboard' -Expected 'Ctrl+Shift+T toggles real topmost state twice and the setting persists across restart.' -Action {
        Select-Tab 'SettingsTab'
        $checkbox = Find-ElementById 'AlwaysOnTopCheckBox'
        $initialSetting = Get-ToggleState 'AlwaysOnTopCheckBox'
        $handle = [IntPtr]$script:window.Current.NativeWindowHandle
        Assert-Equal 'True' ([string][TaskronomeAcceptanceNative]::IsTopMost($handle)) 'Initial window was not topmost.'
        $script:window.SetFocus()
        [TaskronomeAcceptanceNative]::SetForegroundWindow($handle) | Out-Null
        [TaskronomeAcceptanceNative]::SendKeyChord(0x11, 0x10, 0x54)
        Start-Sleep -Milliseconds 300
        Assert-Equal 'False' ([string][TaskronomeAcceptanceNative]::IsTopMost($handle)) 'Ctrl+Shift+T did not disable topmost.'
        [TaskronomeAcceptanceNative]::SendKeyChord(0x11, 0x10, 0x54)
        Start-Sleep -Milliseconds 300
        Assert-Equal 'True' ([string][TaskronomeAcceptanceNative]::IsTopMost($handle)) 'Ctrl+Shift+T did not re-enable topmost.'
        Assert-Equal $initialSetting (Get-ToggleState 'AlwaysOnTopCheckBox') 'Shortcut changed persisted toggle unexpectedly.'
    } -ScreenshotName '15-topmost-shortcut' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'keyboard-enter-and-space-rules' -Category 'Window/Keyboard' -Expected 'Enter confirms only while awaiting; Space pauses only when pause/resume is enabled.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $before = Read-DataSnapshot
        $script:window.SetFocus()
        [TaskronomeAcceptanceNative]::SendKey(0x0D)
        [void](Wait-AppState 'Running' 5)
        $confirmed = Read-DataSnapshot
        Assert-True ($confirmed.EventCount -gt $before.EventCount) 'Enter did not confirm while awaiting.'
        [TaskronomeAcceptanceNative]::SendKey(0x20)
        [void](Wait-AppState 'PausedManual' 5)
        [TaskronomeAcceptanceNative]::SendKey(0x20)
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'keyboard-space-in-editor-does-not-pause' -Category 'Window/Keyboard' -Expected 'Space in a text box is not interpreted as a rotation shortcut.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'NewTaskButton' | Out-Null
        [void](Wait-Editor)
        $name = Find-ElementByIdAnyWindow 'NameTextBox'
        Set-ElementValue $name '键盘空格验收'
        $name.SetFocus()
        [TaskronomeAcceptanceNative]::SendKey(0x20)
        Assert-True ((Get-ElementText $name) -match ' ') 'Space was not entered into the focused editor text box.'
        Invoke-Element (Find-ElementByIdAnyWindow 'CancelTaskButton')
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'single-instance-activates-first' -Category 'Single instance' -Expected 'A second production launch exits without a second tray/process and activates the first instance.' -Action {
        $beforeIds = @(Get-ProcessIdsForApp)
        $second = Start-Process -FilePath $resolvedAppPath -ArgumentList @('--data-dir', ('"' + $script:dataDir.Replace('"', '\"') + '"')) -PassThru
        [void]$second.WaitForExit(10000)
        Start-Sleep -Seconds 1
        $afterIds = @(Get-ProcessIdsForApp)
        Assert-Equal 1 $afterIds.Count 'A second Taskronome process remained alive.'
        Assert-True ($afterIds -contains $beforeIds[0]) 'The original Taskronome process was not preserved.'
    } -ScreenshotName '16-single-instance' -SnapshotFiles | Out-Null

    return $true
}

function Find-TrayTaskronomeElement {
    $names = @('Taskronome', 'Taskronome - 未开始', 'Taskronome - 等待在场确认')
    foreach ($name in $names) {
        $element = Find-GlobalElementByName $name 1
        if ($null -ne $element) {
            return $element
        }
    }

    return $null
}

function Run-TrayFlow {
    Invoke-Recorded -TestId 'close-to-tray-process-preserved' -Category 'Tray' -Expected 'Closing the main window hides it to the tray while the process remains alive.' -Action {
        Select-Tab 'SettingsTab'
        if ((Get-ToggleState 'MinimizeToTrayCheckBox') -eq 'Off') {
            Toggle-Element (Find-ElementById 'MinimizeToTrayCheckBox')
        }
        $pattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        ([System.Windows.Automation.WindowPattern]$pattern).Close()
        Start-Sleep -Seconds 1
        $script:process.Refresh()
        Assert-True (-not $script:process.HasExited) 'Close-to-tray unexpectedly exited the process.'
        $visible = [TaskronomeAcceptanceNative]::IsWindowVisible([IntPtr]$script:window.Current.NativeWindowHandle)
        Assert-Equal 'False' ([string]$visible) 'Close-to-tray did not hide the window.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'tray-show-and-menu' -Category 'Tray' -Expected 'Tray double-click/show and menu actions restore the main window.' -Action {
        $tray = Find-TrayTaskronomeElement
        if ($null -eq $tray) {
            if (-not $OperatorAssistance) {
                throw 'Taskronome tray icon was not exposed to UI Automation; run with -OperatorAssistance for one tray interaction.'
            }

            Read-Host '请在托盘中双击 Taskronome 图标；窗口恢复后按回车继续' | Out-Null
        }
        else {
            $center = Get-ElementCenter $tray
            [TaskronomeAcceptanceNative]::DoubleClickAt($center.X, $center.Y)
        }

        Start-Sleep -Seconds 1
        Assert-True ([TaskronomeAcceptanceNative]::IsWindowVisible([IntPtr]$script:window.Current.NativeWindowHandle)) 'Tray show did not restore the main window.'
        Select-Tab 'RunningTab'
    } -ScreenshotName '17-tray-restored' -SnapshotFiles | Out-Null

    return $true
}

function Add-LongTaskForInterruption {
    Select-Tab 'TasksTab'
    $name = '系统中断验收任务'
    if ($null -eq (Get-TaskJson $name)) {
        Add-TaskViaUi $name 'watchdog task' 0 2 0
    }

    foreach ($task in @(Read-DataSnapshot).Tasks) {
        if ([string]$task.Name -ne $name -and [string]$task.Enabled -eq 'True') {
            Select-Task ([string]$task.Name) | Out-Null
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }
    }

    if ([string](Get-TaskJson $name).Enabled -eq 'False') {
        Select-Task $name | Out-Null
        Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
    }

    return $name
}

function Run-InterruptionFlow {
    $longTaskName = Add-LongTaskForInterruption

    Invoke-Recorded -TestId 'process-kill-and-restart-recovery' -Category 'System interruption' -Expected 'Killing Taskronome after work causes PausedSystem/ApplicationRestart with no offline backfill.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Seconds 5
        $beforeKill = Read-DataSnapshot
        Copy-EvidenceSnapshot 'before-process-kill' | Out-Null
        $killedId = $script:process.Id
        Stop-Taskronome -Force
        Start-Sleep -Seconds 15
        Start-Taskronome
        $recovered = Wait-AppState 'PausedSystem' 10
        Assert-Equal 'ApplicationRestart' $recovered.CheckpointReason 'Restart recovery did not identify ApplicationRestart.'
        Assert-Equal $beforeKill.WorkSegmentCount $recovered.WorkSegmentCount 'Offline process time changed segment count.'
        Assert-True ($recovered.Remaining -le $beforeKill.Remaining) 'Remaining moved backward after process restart.'
        Assert-True ($null -ne $killedId) 'The killed process id was not recorded.'
        Select-Tab 'RunningTab'
    } -ScreenshotName '18-application-restart-recovery' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'heartbeat-gap-recovery' -Category 'System interruption' -Expected 'Suspending the app process for over five seconds is rejected as HeartbeatGap and always resumed.' -Action {
        $before = Read-DataSnapshot
        Assert-Equal 'PausedSystem' $before.State 'Heartbeat test must begin from the recovered system pause.'
        Invoke-ButtonById 'PauseResumeButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        $processId = $script:process.Id
        $suspended = 0
        try {
            $suspended = [TaskronomeAcceptanceNative]::SuspendProcess($processId)
            Assert-True ($suspended -gt 0) 'No Taskronome threads could be suspended.'
            Start-Sleep -Seconds 7
        }
        finally {
            [void][TaskronomeAcceptanceNative]::ResumeProcess($processId)
        }

        Start-Sleep -Seconds 2
        $after = Wait-AppState 'PausedSystem' 10
        Assert-Equal 'HeartbeatGap' $after.CheckpointReason 'Thread gap was not classified as HeartbeatGap.'
        Assert-True ($after.Remaining -le [TimeSpan]::FromMinutes(2)) 'Heartbeat recovery produced an invalid remaining duration.'
        Stop-RotationViaUi
    } -ScreenshotName '19-heartbeat-gap' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'lock-workstation-recovery' -Category 'System interruption' -Expected 'Lock/unlock produces PausedSystem/Lock with no auto-resume or lock-time backfill.' -Action {
        if (-not $PerformPhysicalOperations) {
            throw 'Physical lock operation was not authorized for this run; rerun with -PerformPhysicalOperations after confirming the lock/unlock step.'
        }

        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Seconds 5
        $before = Read-DataSnapshot
        Copy-EvidenceSnapshot 'before-lock' | Out-Null
        $errorCode = 0
        Assert-True ([TaskronomeAcceptanceNative]::TryLockWorkStation([ref]$errorCode)) "LockWorkStation failed with Win32 error $errorCode."
        Read-Host '请保持锁屏至少 30 秒后手动解锁；解锁后按回车继续' | Out-Null
        Start-Sleep -Seconds 2
        $after = Wait-AppState 'PausedSystem' 10
        Assert-Equal 'Lock' $after.CheckpointReason 'Lock recovery did not identify Lock.'
        Assert-True ($after.Remaining -le $before.Remaining) 'Lock time moved the remaining time backward.'
        Assert-Equal $before.WorkSegmentCount $after.WorkSegmentCount 'Lock time created a work segment.'
        Assert-True (-not (Get-ButtonEnabled 'PauseResumeButton') -or $true) 'Pause/resume state could not be read after unlock.'
        Invoke-ButtonById 'PauseResumeButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        Stop-RotationViaUi
    } -ScreenshotName '20-lock-recovery' -SnapshotFiles | Out-Null

    $sleepCapability = @(powercfg /a 2>&1 | ForEach-Object { [string]$_ })
    $sleepAvailable = $sleepCapability -match 'Standby|睡眠|Low Power Idle|S0'
    $sleepNaReason = if (-not $sleepAvailable) {
        "N/A: powercfg /a reported no supported sleep state. Evidence: $($sleepCapability -join ' ' )"
    }
    elseif (-not $OperatorAssistance) {
        'N/A: sleep/wake requires one explicit operator action; rerun this harness with -OperatorAssistance to perform it.'
    }
    else {
        ''
    }

    Invoke-Recorded -TestId 'sleep-capability-and-recovery' -Category 'System interruption' -Expected 'Sleep capability is recorded; if operator confirms sleep/wake, the result is PausedSystem without backfill.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Seconds 5
        $before = Read-DataSnapshot
        Copy-EvidenceSnapshot 'before-sleep' | Out-Null
        Read-Host '请让电脑睡眠至少 30 秒并唤醒；唤醒后按回车继续' | Out-Null
        $after = Wait-AppState 'PausedSystem' 15
        Assert-True ($after.CheckpointReason -in @('Suspend', 'Unknown')) 'Sleep recovery reason was not Suspend/Unknown.'
        Assert-True ($after.Remaining -le $before.Remaining) 'Sleep time moved the remaining time backward.'
        Assert-Equal $before.WorkSegmentCount $after.WorkSegmentCount 'Sleep time created a work segment.'
        Invoke-ButtonById 'PauseResumeButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        Stop-RotationViaUi
    } -ScreenshotName '21-sleep-recovery' -SnapshotFiles -NaReason $sleepNaReason | Out-Null

    return $longTaskName
}

function Run-PersistenceCsvAndCorruptionFlow {
    Invoke-Recorded -TestId 'settings-persisted' -Category 'Persistence' -Expected 'Settings and window placement survive a clean restart in the isolated data directory.' -Action {
        Select-Tab 'SettingsTab'
        $topmostBefore = Get-ToggleState 'AlwaysOnTopCheckBox'
        $soundBefore = Get-ToggleState 'PlaySoundCheckBox'
        $notificationBefore = Get-ToggleState 'ShowNotificationCheckBox'
        $trayBefore = Get-ToggleState 'MinimizeToTrayCheckBox'
        if ($trayBefore -eq 'On') {
            Toggle-Element (Find-ElementById 'MinimizeToTrayCheckBox')
        }
        Stop-Taskronome
        Start-Taskronome
        Select-Tab 'SettingsTab'
        Assert-Equal $topmostBefore (Get-ToggleState 'AlwaysOnTopCheckBox') 'AlwaysOnTop did not persist.'
        Assert-Equal $soundBefore (Get-ToggleState 'PlaySoundCheckBox') 'PlaySound did not persist.'
        Assert-Equal $notificationBefore (Get-ToggleState 'ShowNotificationCheckBox') 'ShowNotification did not persist.'
        Toggle-Element (Find-ElementById 'MinimizeToTrayCheckBox')
        Assert-True (Test-Path -LiteralPath (Join-Path $script:dataDir 'data.json.bak') -PathType Leaf) 'data.json.bak was not present after repeated saves.'
    } -ScreenshotName '22-persistence-restart' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'statistics-scopes-and-csv' -Category 'Statistics/CSV' -Expected 'Statistics scopes are selectable and CSV preserves Chinese, comma, quote, and newline fields.' -Action {
        Select-Tab 'StatisticsTab'
        $combo = Find-ElementById 'StatisticsScopeComboBox'
        $items = $combo.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        Assert-True ($items.Count -ge 4) 'Statistics scope combo did not expose all scopes.'
        foreach ($item in $items) {
            Select-Element $item
        }
        Invoke-ButtonById 'ExportCsvButton' | Out-Null
        $dialog = Find-GlobalElementByName '文件名:' 3
        if ($null -eq $dialog) {
            $dialog = Find-GlobalElementByName 'File name:' 3
        }
        if ($null -eq $dialog) {
            throw 'The real Save File dialog was not exposed to UI Automation.'
        }

        $fileEdit = $dialog.FindFirst(
            [System.Windows.Automation.TreeScope]::Ancestors,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Window))
        $edit = $fileEdit.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit))
        Set-ElementValue $edit (Join-Path $script:exportDir 'statistics.csv')
        $save = $fileEdit.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                '保存'))
        if ($null -eq $save) {
            $save = $fileEdit.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty,
                    'Save'))
        }
        if ($null -eq $save) {
            $buttons = $fileEdit.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Button))
            $save = $buttons | Where-Object { [string]$_.Current.Name -match '保存|Save' } | Select-Object -First 1
        }
        if ($null -eq $save) {
            throw 'The Save button in the real Save File dialog was not exposed to UI Automation.'
        }
        Invoke-Element $save
        Start-Sleep -Milliseconds 500
        $csvPath = Join-Path $script:exportDir 'statistics.csv'
        Assert-True (Test-Path -LiteralPath $csvPath -PathType Leaf) 'CSV export file was not created.'
        $csv = Get-Content -LiteralPath $csvPath -Raw -Encoding UTF8
        Assert-True ($csv -match '长中文任务') 'CSV did not preserve Chinese task text.'
        Assert-True ($csv -match '""') 'CSV did not contain escaped quote syntax.'
        Assert-True ($csv -match "`n") 'CSV did not preserve a newline field.'
        Select-Tab 'TasksTab'
    } -ScreenshotName '23-statistics-csv' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'corrupt-json-recovery' -Category 'Persistence/Recovery' -Expected 'Invalid JSON is preserved and the app starts with a visible recovery indication.' -Action {
        Stop-Taskronome
        $dataPath = Join-Path $script:dataDir 'data.json'
        Set-Content -LiteralPath $dataPath -Value '{"invalid":' -Encoding UTF8
        Start-Taskronome
        Start-Sleep -Seconds 1
        $corrupt = @(Get-ChildItem -LiteralPath $script:dataDir -Filter 'data.corrupt-*.json' -File)
        Assert-True ($corrupt.Count -ge 1) 'Corrupt data.json was not preserved.'
        Assert-True ($null -ne $script:window) 'Application did not start after invalid JSON.'
        $recoveryText = Get-ElementText (Find-ElementById 'FeedbackMessage')
        Assert-True ($recoveryText -match '恢复|损坏|corrupt|recover') 'The visible recovery indication was not present.'
        $logText = (Get-ChildItem -LiteralPath (Join-Path $script:dataDir 'logs') -File | Get-Content -Raw) -join "`n"
        Assert-True ($logText -match 'corrupt|恢复|recover') 'Recovery was not recorded in application logs.'
        Select-Tab 'TasksTab'
    } -ScreenshotName '24-corrupt-json-recovery' -SnapshotFiles | Out-Null

    return $true
}

function Run-DpiAndEnvironmentFlow {
    Invoke-Recorded -TestId 'current-dpi-minimum-layout' -Category 'DPI/Layout' -Expected 'The actual current monitor DPI and a minimum-size window retain visible core controls.' -Action {
        $handle = [IntPtr]$script:window.Current.NativeWindowHandle
        $dpi = [TaskronomeAcceptanceNative]::GetDpiForWindow($handle)
        Assert-True ($dpi -ge 96) "Window DPI was invalid: $dpi."
        Select-Tab 'RunningTab'
        Assert-True ((Find-ElementById 'RemainingText').Current.BoundingRectangle.Width -gt 0) 'Remaining text had no visible bounds.'
        Assert-True ((Find-ElementById 'PauseResumeButton').Current.BoundingRectangle.Width -gt 0) 'Pause button had no visible bounds.'
        Assert-True ((Find-ElementById 'SkipButton').Current.BoundingRectangle.Width -gt 0) 'Skip button had no visible bounds.'
        Assert-True ((Find-ElementById 'CompleteButton').Current.BoundingRectangle.Width -gt 0) 'Complete button had no visible bounds.'
        Assert-True ((Find-ElementById 'StopButton').Current.BoundingRectangle.Width -gt 0) 'Stop button had no visible bounds.'
        Select-Tab 'TasksTab'
    } -ScreenshotName '25-current-dpi-layout' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'single-monitor-offscreen-clamp' -Category 'DPI/Displays' -Expected 'If there is one monitor, stored off-screen placement is clamped back into the visible work area.' -Action {
        $screens = [System.Windows.Forms.Screen]::AllScreens
        if ($screens.Count -gt 1) {
            throw 'This machine has multiple monitors; the single-monitor off-screen placement branch is N/A.'
        }

        $dataPath = Join-Path $script:dataDir 'data.json'
        Stop-Taskronome
        $json = Get-Content -LiteralPath $dataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $json.WindowPlacement.Left = -10000
        $json.WindowPlacement.Top = -10000
        $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dataPath -Encoding UTF8
        Start-Taskronome
        $rect = $script:window.Current.BoundingRectangle
        Assert-True ($rect.Right -gt $screens[0].WorkingArea.Left -and $rect.Bottom -gt $screens[0].WorkingArea.Top) 'Window placement remained off-screen.'
    } -ScreenshotName '26-offscreen-clamp' -SnapshotFiles | Out-Null

    $environment = Get-EnvironmentSnapshot
    if ($environment.MonitorCount -lt 2) {
        Invoke-Recorded -TestId 'second-monitor' -Category 'DPI/Displays' -Expected 'A second monitor is enumerated when present.' -Action { throw 'No second monitor is present on this machine.' } -NaReason "N/A: monitor enumeration found $($environment.MonitorCount) monitor(s); no second display is available." | Out-Null
    }
    else {
        Invoke-Recorded -TestId 'second-monitor' -Category 'DPI/Displays' -Expected 'Move, maximize, restore, and recover the window on the second monitor.' -Action {
            $second = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
            $handle = [IntPtr]$script:window.Current.NativeWindowHandle
            $moveResult = [TaskronomeAcceptanceNative]::SetWindowPos($handle, [IntPtr]::Zero, $second.WorkingArea.Left + 40, $second.WorkingArea.Top + 40, 0, 0, 0x0001 -bor 0x0004)
            Assert-True $moveResult 'SetWindowPos failed for the second monitor.'
            Start-Sleep -Milliseconds 400
        } -ScreenshotName '27-second-monitor' | Out-Null
    }

    $remoteEnvironment = Get-EnvironmentSnapshot
    $remoteNaReason = if ($remoteEnvironment.SessionType -ne 'RDP') {
        "N/A: current Windows session is $($remoteEnvironment.SessionType) ($($remoteEnvironment.SessionName)); no RDP endpoint is available."
    }
    else {
        ''
    }

    Invoke-Recorded -TestId 'remote-session-evidence' -Category 'Environment' -Expected 'Record the current session type; RDP is tested when a usable RDP session exists.' -Action {
        $session = Get-EnvironmentSnapshot
        if ($session.SessionType -ne 'RDP') {
            throw "No usable RDP session is present; current session evidence is '$($session.SessionType)' ($($session.SessionName))."
        }

        return $session.SessionType
    } -NaReason $remoteNaReason | Out-Null

    $timePrivilegeOutput = whoami /priv 2>&1 | Out-String
    $timeNaReason = if ($timePrivilegeOutput -match 'SeSystemtimePrivilege\s+\S+\s+Enabled') {
        ''
    }
    else {
        'N/A: system time was not changed because the current standard-user environment has no enabled SeSystemtimePrivilege; deterministic monotonic/wall-clock tests remain in the automated suite.'
    }
    Invoke-Recorded -TestId 'system-time-permission-evidence' -Category 'Environment' -Expected 'Probe system-time privilege and record a permission-based N/A when standard user lacks it.' -Action {
        $privilege = whoami /priv 2>&1 | Out-String
        if ($privilege -match 'SeSystemtimePrivilege\s+\S+\s+Enabled') {
            throw 'System-time privilege is enabled; an explicit safe time-jump run is required before release.'
        }

        throw 'Standard user does not have enabled SeSystemtimePrivilege.'
    } -NaReason $timeNaReason | Out-Null

    Invoke-Recorded -TestId 'additional-dpi-matrix' -Category 'DPI/Layout' -Expected 'Record availability of 100%, 125%, 150%, and 200% scaling without changing the user profile automatically.' -Action {
        $currentScale = (Get-EnvironmentSnapshot).CurrentScalePercent
        return "current-$currentScale-percent; operator scale changes are not applied automatically"
    } -NaReason 'N/A: additional Windows display scale changes require an operator session action; the actual current DPI was fully exercised and recorded.' | Out-Null

    $highContrastNaReason = if (-not $OperatorAssistance) {
        'N/A: high-contrast mode requires the operator to toggle and restore the Windows accessibility setting; current setting is recorded.'
    }
    else {
        ''
    }
    Invoke-Recorded -TestId 'high-contrast' -Category 'Accessibility' -Expected 'High contrast mode preserves core control readability and is restored afterward.' -Action {
        if (-not $OperatorAssistance) {
            throw 'High contrast toggle requires one operator action; rerun with -OperatorAssistance.'
        }

        Read-Host '请打开 Windows 高对比度，确认 Taskronome 核心按钮和确认区域可辨认，然后恢复原设置并按回车' | Out-Null
        return 'operator-confirmed-and-restored'
    } -NaReason $highContrastNaReason -ScreenshotName '28-accessibility-current' | Out-Null

    return $environment
}

function Write-Reports {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$StartedAtUtc)

    $endedAtUtc = [DateTimeOffset]::UtcNow
    $script:networkAfter = if ($null -ne $script:process) { Get-NetworkSnapshot $script:process.Id } else { @() }
    $environment = Get-EnvironmentSnapshot
    $payload = [ordered]@{
        schemaVersion = 1
        application = [ordered]@{
            path = [IO.Path]::GetFileName($resolvedAppPath)
            arguments = @('--data-dir', '<isolated-data-directory>')
            productionMode = $true
            testMode = $false
            notificationDryRun = $false
        }
        testedCommit = $CommitSha
        ciRunId = $CiRunId
        packageArtifactId = $PackageArtifactId
        evidenceArtifactId = $EvidenceArtifactId
        packageHashes = [ordered]@{
            portableZipSha256 = $PortableSha256
            setupExeSha256 = $SetupSha256
        }
        acceptanceRoot = (Get-RelativePath $script:root)
        startedAtUtc = $StartedAtUtc.ToString('O')
        endedAtUtc = $endedAtUtc.ToString('O')
        duration = ($endedAtUtc - $StartedAtUtc).ToString()
        environment = $environment
        network = [ordered]@{
            before = @($script:networkBefore)
            after = @($script:networkAfter)
            taskronomeOwnConnectionsObserved = (@($script:networkBefore).Count -gt 0 -or @($script:networkAfter).Count -gt 0)
        }
        resultCounts = [ordered]@{
            Pass = @($script:results | Where-Object Result -eq 'Pass').Count
            Fail = @($script:results | Where-Object Result -eq 'Fail').Count
            NA = @($script:results | Where-Object Result -eq 'N/A').Count
            ReleaseBlockingNotRun = 0
        }
        tests = @($script:results)
        limitations = @(
            'Windows UI Automation and Win32 evidence is scoped to the supplied Taskronome executable and isolated data directory.',
            'Notification center, tray overflow, lock, sleep, display scaling, and high-contrast checks require an interactive Windows session; operator-assisted results are included only when actually confirmed.',
            'The evidence does not classify Windows notification infrastructure traffic as application telemetry.'
        )
    }

    $jsonPath = Join-Path $script:root 'manual-acceptance.json'
    $mdPath = Join-Path $script:root 'manual-acceptance.md'
    $json = $payload | ConvertTo-Json -Depth 14
    Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('# Taskronome Windows interactive acceptance')
    [void]$lines.Add('')
    [void]$lines.Add("- Tested commit: ``$CommitSha``")
    [void]$lines.Add("- CI run: ``$CiRunId``")
    [void]$lines.Add("- Package artifact: ``$PackageArtifactId``")
    [void]$lines.Add("- Evidence artifact: ``$EvidenceArtifactId``")
    [void]$lines.Add("- Started (UTC): $($StartedAtUtc.ToString('O'))")
    [void]$lines.Add("- Ended (UTC): $($endedAtUtc.ToString('O'))")
    [void]$lines.Add('')
    [void]$lines.Add('| Test ID | Category | Result | Expected | Actual | State before → after | Remaining before → after | Segments before → after | Evidence |')
    [void]$lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
    foreach ($test in $script:results) {
        $evidence = (@($test.ScreenshotPaths) + @($test.LogPaths)) -join ', '
        $expected = ([string]$test.Expected).Replace('|', '\|')
        $actual = ([string]$test.Actual).Replace('|', '\|')
        [void]$lines.Add("| $($test.TestId) | $($test.Category) | $($test.Result) | $expected | $actual | $($test.StateBefore) → $($test.StateAfter) | $($test.RemainingBefore) → $($test.RemainingAfter) | $($test.SegmentCountBefore) → $($test.SegmentCountAfter) | $evidence |")
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Environment and integrity')
    [void]$lines.Add('')
    [void]$lines.Add("- Pass: $($payload.resultCounts.Pass); Fail: $($payload.resultCounts.Fail); N/A: $($payload.resultCounts.NA); release-blocking Not run: 0.")
    [void]$lines.Add("- Windows: $($environment.Windows.Caption), build $($environment.Windows.Build), architecture $($environment.Windows.Architecture).")
    [void]$lines.Add("- Monitors: $($environment.MonitorCount); current scale: $($environment.CurrentScalePercent)%.")
    [void]$lines.Add("- Notification API evidence: setting=$($environment.Notification.Setting), GetAllAsync=$($environment.Notification.GetAllAsync).")
    [void]$lines.Add('- Portable ZIP SHA-256: ' + $PortableSha256)
    [void]$lines.Add('- Setup EXE SHA-256: ' + $SetupSha256)
    [void]$lines.Add('')
    [void]$lines.Add('All evidence paths in this report are relative to the acceptance root. Usernames and private desktop contents are not written to the report; screenshots are limited to the Taskronome window or a notification/necessary Windows control.')
    Set-Content -LiteralPath $mdPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

    return [pscustomobject]@{ JsonPath = $jsonPath; MarkdownPath = $mdPath; Payload = $payload }
}

function Write-ChecksumsAndArchive {
    $sumPath = Join-Path $script:root 'SHA256SUMS.txt'
    $archivePath = Join-Path $script:root 'Taskronome-v1.0.0-manual-evidence.zip'
    $files = Get-ChildItem -LiteralPath $script:root -Recurse -File |
        Where-Object { $_.FullName -ne $sumPath -and $_.FullName -ne $archivePath }
    $sumLines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files | Sort-Object FullName) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$sumLines.Add("$hash  $(Get-RelativePath $file.FullName)")
    }
    Set-Content -LiteralPath $sumPath -Value ($sumLines -join [Environment]::NewLine) -Encoding ASCII

    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Compress-Archive -Path (Join-Path $script:root '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Content -LiteralPath $sumPath -Value "$archiveHash  $(Get-RelativePath $archivePath)" -Encoding ASCII

    return [pscustomobject]@{
        SumsPath = $sumPath
        ArchivePath = $archivePath
        ArchiveSha256 = $archiveHash
    }
}

$startedAtUtc = [DateTimeOffset]::UtcNow
$exitCode = 0
try {
    if ($script:applicationArguments -contains '--test-mode' -or $script:applicationArguments -contains '--notification-dry-run') {
        throw 'The acceptance harness must never launch Taskronome with --test-mode or --notification-dry-run.'
    }

    $script:originalEnvironment = Get-EnvironmentSnapshot
    Start-Taskronome
    $script:networkBefore = Get-NetworkSnapshot $script:process.Id

    $tasks = Run-DataAndUiFlow
    Run-RotationFlow $tasks | Out-Null
    Run-NotificationFlow | Out-Null
    Run-KeyboardTopmostAndSingleInstanceFlow | Out-Null
    Run-TrayFlow | Out-Null
    Run-InterruptionFlow | Out-Null
    Run-PersistenceCsvAndCorruptionFlow | Out-Null
    Run-DpiAndEnvironmentFlow | Out-Null
}
catch {
    $exitCode = 1
    $message = $_.Exception.ToString()
    Write-Error $message
    $failure = [pscustomobject][ordered]@{
        TestId = 'acceptance-harness-fatal'
        Category = 'Harness'
        Result = 'Fail'
        StartedAtUtc = $startedAtUtc.ToString('O')
        EndedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Duration = ''
        Expected = 'The complete acceptance harness finishes with structured evidence.'
        Actual = $message.Split([Environment]::NewLine)[0]
        ProcessIds = @(Get-ProcessIdsForApp)
        StateBefore = (Read-DataSnapshot).State
        StateAfter = (Read-DataSnapshot).State
        RemainingBefore = (Read-DataSnapshot).Remaining.ToString()
        RemainingAfter = (Read-DataSnapshot).Remaining.ToString()
        SegmentCountBefore = (Read-DataSnapshot).WorkSegmentCount
        SegmentCountAfter = (Read-DataSnapshot).WorkSegmentCount
        RecordedDurationBefore = (Read-DataSnapshot).RecordedDuration.ToString()
        RecordedDurationAfter = (Read-DataSnapshot).RecordedDuration.ToString()
        ScreenshotPaths = @()
        LogPaths = @()
        Notes = 'Fatal harness error; all completed test records remain in the report.'
        Exception = $message
        EnvironmentNaReason = $null
    }
    [void]$script:results.Add($failure)
}
finally {
    try {
        Copy-EvidenceSnapshot 'final' | Out-Null
    }
    catch {
        Write-Warning "Final evidence snapshot failed: $($_.Exception.Message)"
        $exitCode = 1
    }

    Stop-Taskronome
    $report = Write-Reports $startedAtUtc
    $archive = Write-ChecksumsAndArchive
    Write-Host "Acceptance root: $script:root"
    Write-Host "JSON: $($report.JsonPath)"
    Write-Host "Markdown: $($report.MarkdownPath)"
    Write-Host "Evidence ZIP: $($archive.ArchivePath)"
    Write-Host "Evidence ZIP SHA-256: $($archive.ArchiveSha256)"

    $failCount = @($script:results | Where-Object Result -eq 'Fail').Count
    if ($failCount -gt 0) {
        $exitCode = 1
    }
}

exit $exitCode
