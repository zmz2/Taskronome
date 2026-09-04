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
    not enable --test-mode or --notification-dry-run. It uses only the explicit,
    read-only --acceptance-read-only endpoint to collect AppNotificationManager
    API evidence from inside the application process. The PowerShell process is the watchdog for the optional interruption
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
$script:notificationApiProbePath = Join-Path $script:evidenceDir 'app-notification-api.json'
$script:notificationApiToken = [Guid]::NewGuid().ToString('D')
$script:results = [System.Collections.Generic.List[object]]::new()
$script:process = $null
$script:window = $null
$script:originalEnvironment = $null
$script:networkBefore = @()
$script:networkAfter = @()
$script:applicationStartedAtUtc = $null
$quotedDataDir = '"' + $script:dataDir.Replace('"', '\"') + '"'
$quotedNotificationProbePath = '"' + $script:notificationApiProbePath.Replace('"', '\"') + '"'
$script:applicationArguments = @(
    '--data-dir', $quotedDataDir,
    '--acceptance-read-only', $script:notificationApiToken, $quotedNotificationProbePath)

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
using System.Collections.Generic;
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

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static IntPtr[] GetTopLevelWindowHandles(int processId)
    {
        var handles = new List<IntPtr>();
        EnumWindows((hWnd, _) =>
        {
            GetWindowThreadProcessId(hWnd, out var ownerProcessId);
            if (ownerProcessId == processId)
            {
                handles.Add(hWnd);
            }

            return true;
        }, IntPtr.Zero);
        return handles.ToArray();
    }

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

    public static void SendCtrlKey(byte key)
    {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    private static extern bool ScreenToClient(IntPtr hWnd, ref Point point);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    private static IntPtr MakeLParam(int x, int y) => new((y << 16) | (x & 0xffff));

    public static bool ClickNativeButton(IntPtr hWnd)
    {
        return hWnd != IntPtr.Zero && SendMessage(hWnd, 0x00F5, IntPtr.Zero, IntPtr.Zero) == IntPtr.Zero;
    }

    public static void DoubleClickAt(int x, int y)
    {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(60);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static bool DoubleClickWindow(IntPtr hWnd, int screenX, int screenY)
    {
        var point = new Point(screenX, screenY);
        if (!ScreenToClient(hWnd, ref point))
        {
            return false;
        }

        var lParam = MakeLParam(point.X, point.Y);
        var first = PostMessage(hWnd, 0x0200, IntPtr.Zero, lParam)
            && PostMessage(hWnd, 0x0201, new IntPtr(1), lParam)
            && PostMessage(hWnd, 0x0202, IntPtr.Zero, lParam);
        Thread.Sleep(60);
        var second = PostMessage(hWnd, 0x0200, IntPtr.Zero, lParam)
            && PostMessage(hWnd, 0x0203, new IntPtr(1), lParam)
            && PostMessage(hWnd, 0x0202, IntPtr.Zero, lParam);
        return first && second;
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

function ConvertTo-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
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

    $lastError = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Start-Sleep -Milliseconds 50
            continue
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
                WorkSegmentCount = @($segments).Count
                RecordedDuration = $recorded
                EventCount = if ($null -eq $document.Events) { 0 } else { @($document.Events).Count }
                Tasks = $tasks
                CheckpointSavedAtUtc = if ($null -eq $checkpoint) { $null } else { [string]$checkpoint.SavedAtUtc }
                CheckpointReason = if ($null -eq $checkpoint) { $null } else { [string]$checkpoint.SystemPauseReason }
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 50
        }
    }

    if ($null -eq $lastError) {
        return [pscustomobject]$empty
    }

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
        ReadError = $lastError
    }
}

function Get-ElementText {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    $value = ''
    try {
        try {
            $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $value = ([System.Windows.Automation.ValuePattern]$valuePattern).Current.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
        catch {
        }

        $name = [string]$Element.Current.Name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }

        return $value
    }
    catch {
        return ''
    }
}

function Get-ElementValue {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    try {
        $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $value = ([System.Windows.Automation.ValuePattern]$valuePattern).Current.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        return [string]$Element.Current.Name
    }
    catch {
        return $Element.Current.Name
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

function Get-LiveMainWindowElement {
    if ($null -eq $script:process) {
        return $null
    }

    try {
        $script:process.Refresh()
        $handle = $script:process.MainWindowHandle
        if ($handle -eq [IntPtr]::Zero) {
            return $null
        }

        $candidate = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        if ($candidate.Current.ProcessId -ne $script:process.Id) {
            return $null
        }

        $script:window = $candidate
        return $candidate
    }
    catch {
        return $null
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
            $liveWindow = Get-LiveMainWindowElement
            if ($null -ne $liveWindow) {
                $condition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                    $AutomationId)
                $element = $liveWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
                if ($null -ne $element) {
                    return $element
                }
            }

            if ($null -ne $script:process) {
                $processCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                    [int]$script:process.Id)
                $globalCondition = [System.Windows.Automation.AndCondition]::new(
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                        $AutomationId),
                    $processCondition)
                $element = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $globalCondition)
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
            $liveWindow = Get-LiveMainWindowElement
            if ($null -ne $liveWindow) {
                $idCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                    $AutomationId)
                $element = $liveWindow.FindFirst(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $idCondition)
                if ($null -ne $element) {
                    return $element
                }
            }

            $idCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                $AutomationId)
            $condition = $idCondition
            if ($null -ne $script:process) {
                $processCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                    [int]$script:process.Id)
                $condition = [System.Windows.Automation.AndCondition]::new($idCondition, $processCondition)
            }
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

    $element = Find-ElementByIdAnyWindow $AutomationId
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
    catch {
        Invoke-Element $Element
    }
}

function Select-Tab {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        try {
            $tab = Find-ElementByIdAnyWindow $AutomationId -TimeoutSeconds 1
            $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if (-not ([System.Windows.Automation.SelectionItemPattern]$pattern).Current.IsSelected) {
                ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
            }

            $selected = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if (([System.Windows.Automation.SelectionItemPattern]$selected).Current.IsSelected) {
                Start-Sleep -Milliseconds 250
                return
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "UI Automation tab did not become selected: $AutomationId"
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

    if ($null -ne $script:window) {
        $handle = [IntPtr]$script:window.Current.NativeWindowHandle
        $script:window.SetFocus()
        [TaskronomeAcceptanceNative]::SetForegroundWindow($handle) | Out-Null
    }
    else {
        throw 'Cannot double-click because the main window is unavailable.'
    }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $center = Get-ElementCenter $Element
        if ($attempt -eq 0) {
            [TaskronomeAcceptanceNative]::DoubleClickAt($center.X, $center.Y)
        }
        else {
            Assert-True ([TaskronomeAcceptanceNative]::DoubleClickWindow($handle, $center.X, $center.Y)) 'Posting the task-row double-click messages failed.'
        }
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(2)
        while ([DateTime]::UtcNow -lt $readyDeadline) {
            if (@(Get-EditorWindows).Count -gt 0) {
                return
            }

            Start-Sleep -Milliseconds 100
        }

        if ($attempt -eq 0) {
            $script:window.SetFocus()
            [TaskronomeAcceptanceNative]::SetForegroundWindow($handle) | Out-Null
        }
    }

    throw 'Task editor window did not open after two posted double-click attempts.'
}

function Double-ClickButtonById {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $button = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $button = Find-ElementById $AutomationId -TimeoutSeconds 1
        if ($button.Current.IsEnabled) {
            break
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $button -or -not $button.Current.IsEnabled) {
        throw "The UI element '$AutomationId' is disabled."
    }

    $handle = [IntPtr]$script:window.Current.NativeWindowHandle
    $script:window.SetFocus()
    [TaskronomeAcceptanceNative]::SetForegroundWindow($handle) | Out-Null
    $center = Get-ElementCenter $button
    [TaskronomeAcceptanceNative]::DoubleClickAt($center.X, $center.Y)
}

function Wait-Editor {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $editor = @(Get-EditorWindows) | Select-Object -First 1
        if ($null -ne $editor) {
            return $editor
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw 'Task editor window did not become ready before the timeout.'
}

function Get-EditorWindows {
    if ($null -eq $script:process) {
        return @()
    }

    try {
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($handle in [TaskronomeAcceptanceNative]::GetTopLevelWindowHandles($script:process.Id)) {
            if ($handle -eq [IntPtr]::Zero -or -not [TaskronomeAcceptanceNative]::IsWindowVisible($handle)) {
                continue
            }

            try {
                $window = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
                if ([string]$window.Current.AutomationId -eq 'TaskEditorWindow') {
                    [void]$result.Add($window)
                }
            }
            catch [System.Windows.Automation.ElementNotAvailableException] {
            }
        }

        return @($result)
    }
    catch {
        return @()
    }
}

function Wait-EditorClosed {
    param([int]$TimeoutSeconds = 5)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-EditorWindows).Count -eq 0) {
            return $true
        }

        Start-Sleep -Milliseconds 150
    }

    return $false
}

function Get-TextByIdEventually {
    param(
        [Parameter(Mandatory = $true)][string]$AutomationId,
        [int]$TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $element = Find-ElementByIdAnyWindow $AutomationId -TimeoutSeconds 1 -Optional
        if ($null -ne $element) {
            $text = Get-ElementText $element
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    return ''
}

function Set-EditorFields {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Notes,
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
                if ($null -ne $script:process -and [int]$dialog.Current.ProcessId -ne $script:process.Id) {
                    continue
                }

                if ($null -ne $script:window -and [string]$dialog.Current.AutomationId -eq 'MainWindow') {
                    continue
                }

                $buttons = $dialog.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($button in $buttons) {
                    $name = [string]$button.Current.Name
                    $isButton = [string]$button.Current.ClassName -eq 'Button' -or
                        $button.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button
                    $isAccepted = @($acceptedNames | Where-Object { $name -like "$_*" }).Count -gt 0
                    if ($isButton -and $isAccepted -and $button.Current.IsEnabled) {
                        Invoke-DialogButton $button
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

function Invoke-DialogButton {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    try {
        Invoke-Element $Element
    }
    catch {
        $handle = [IntPtr]$Element.Current.NativeWindowHandle
        Assert-True ($handle -ne [IntPtr]::Zero) "Dialog button '$($Element.Current.Name)' had no native window handle."
        Assert-True ([TaskronomeAcceptanceNative]::ClickNativeButton($handle)) "Native click failed for dialog button '$($Element.Current.Name)'."
    }
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
                if ($null -ne $script:process -and [int]$dialog.Current.ProcessId -ne $script:process.Id) {
                    continue
                }

                if ($null -ne $script:window -and [string]$dialog.Current.AutomationId -eq 'MainWindow') {
                    continue
                }

                $buttons = $dialog.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($button in $buttons) {
                    $name = [string]$button.Current.Name
                    $isButton = [string]$button.Current.ClassName -eq 'Button' -or
                        $button.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button
                    $isDismissed = @(@('否', '取消', 'No', 'Cancel', '关闭', 'Close', '确定', 'OK') |
                        Where-Object { $name -like "$_*" })
                    if ($isButton -and $isDismissed.Count -gt 0 -and $button.Current.IsEnabled) {
                        Invoke-DialogButton $button
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
    if ($null -eq (Wait-ForTask $Name)) {
        $validation = Get-ElementText (Find-ElementByIdAnyWindow 'ValidationTextBlock' -TimeoutSeconds 1 -Optional)
        throw "Task '$Name' was not persisted after saving. Validation: $validation"
    }

    if (-not (Wait-EditorClosed)) {
        $validation = Get-ElementText (Find-ElementByIdAnyWindow 'ValidationTextBlock' -TimeoutSeconds 1 -Optional)
        throw "Task editor did not close after saving '$Name'. Validation: $validation"
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
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $task = Get-TaskJson $TaskName
        if ($null -ne $task -and [string]$task.Notes -eq $NewNotes) {
            break
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not (Wait-EditorClosed)) {
        $validation = Get-ElementText (Find-ElementByIdAnyWindow 'ValidationTextBlock' -TimeoutSeconds 1 -Optional)
        throw "Task editor did not close after editing '$TaskName'. Validation: $validation"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $task = Get-TaskJson $TaskName
        if ($null -ne $task -and [string]$task.Notes -eq $NewNotes) {
            return
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Task '$TaskName' was not updated after the editor closed."
}

function Delete-TaskViaUi {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    Select-Task $TaskName | Out-Null
    Invoke-ButtonById 'DeleteTaskButton' | Out-Null
    if (-not (Confirm-Dialog)) {
        throw "The delete confirmation dialog for '$TaskName' was not available."
    }

    Start-Sleep -Milliseconds 300
    if (-not (Wait-ForTaskAbsent $TaskName)) {
        throw "Task '$TaskName' remained in data.json after deletion."
    }
}

function Stop-RotationViaUi {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $button = Find-ElementById 'StopButton'
        if (-not $button.Current.IsEnabled) {
            return
        }

        Invoke-Element $button
        if (Confirm-Dialog) {
            try {
                [void](Wait-AppState 'Idle' 10)
                return
            }
            catch {
                if ($attempt -eq 1) {
                    throw
                }
            }
        }

        if ($attempt -eq 1) {
            throw 'The stop confirmation dialog was not available.'
        }

        Start-Sleep -Milliseconds 600
    }
}

function Stop-RotationSafely {
    try {
        $state = Read-DataSnapshot
        if ($state.State -notin @('Idle', 'Completed', 'Unavailable', 'CorruptOrUnavailable')) {
            Stop-RotationViaUi
        }
    }
    catch {
    }
}

function Get-TaskJson {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $data = Read-DataSnapshot
    return $data.Tasks | Where-Object { [string]$_.Name -eq $TaskName } | Select-Object -First 1
}

function Read-DataDocument {
    $path = Join-Path $script:dataDir 'data.json'
    $lastException = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $lastException = $_.Exception
            Start-Sleep -Milliseconds 50
        }
    }

    throw $lastException
}

function Get-AppLogText {
    $logPath = Join-Path $script:dataDir 'logs'
    if (-not (Test-Path -LiteralPath $logPath -PathType Container)) {
        return ''
    }

    return ((Get-ChildItem -LiteralPath $logPath -File | Sort-Object Name | Get-Content -Raw) -join [Environment]::NewLine)
}

function Wait-ForTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [int]$TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $task = Get-TaskJson $TaskName
        if ($null -ne $task) {
            return $task
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    return $null
}

function Wait-ForTaskAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [int]$TimeoutSeconds = 5
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ($null -eq (Get-TaskJson $TaskName)) {
            return $true
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
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
            Copy-FileForEvidence $source $target
            [void]$paths.Add((Get-RelativePath $target))
        }
    }

    $sourceLogDir = Join-Path $script:dataDir 'logs'
    if (Test-Path -LiteralPath $sourceLogDir -PathType Container) {
        foreach ($sourceLog in @(Get-ChildItem -LiteralPath $sourceLogDir -File)) {
            $targetLog = Join-Path $script:logDir "$safeLabel-$($sourceLog.Name)"
            Copy-FileForEvidence $sourceLog.FullName $targetLog
            [void]$paths.Add((Get-RelativePath $targetLog))
        }
    }

    return @($paths)
}

function Copy-FileForEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $lastException = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $sourceStream = $null
        $destinationStream = $null
        try {
            $sourceStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            $destinationStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $sourceStream.CopyTo($destinationStream)
            return
        }
        catch [IO.IOException] {
            $lastException = $_.Exception
            Start-Sleep -Milliseconds 100
        }
        finally {
            if ($null -ne $destinationStream) {
                $destinationStream.Dispose()
            }
            if ($null -ne $sourceStream) {
                $sourceStream.Dispose()
            }
        }
    }

    throw $lastException
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
    param([switch]$WaitForSuccess)

    $expectedTokenHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$script:notificationApiToken))).ToLowerInvariant()
    $probeDeadline = [DateTime]::UtcNow.AddSeconds($(if ($WaitForSuccess) { 600 } else { 3 }))
    while ([DateTime]::UtcNow -lt $probeDeadline) {
        if (Test-Path -LiteralPath $script:notificationApiProbePath -PathType Leaf) {
            try {
                $probe = Get-Content -LiteralPath $script:notificationApiProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$probe.Source -eq 'Taskronome application process' -and
                    [bool]$probe.ReadOnly -and
                    ((-not $WaitForSuccess) -or [bool]$probe.GetAllAsync.Succeeded)) {
                    return [pscustomobject][ordered]@{
                        Source = [string]$probe.Source
                        ReadOnly = [bool]$probe.ReadOnly
                        TokenMatched = ([string]$probe.TokenSha256 -eq $expectedTokenHash)
                        Setting = [string]$probe.Setting
                        IsSupported = $probe.IsSupported
                        GetAllAsync = $probe.GetAllAsync
                        Error = if ($probe.PSObject.Properties.Name -contains 'Error') { [string]$probe.Error } else { $null }
                    }
                }
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds 100
    }

    $applicationProcessAlive = $false
    if ($null -ne $script:process) {
        try {
            $script:process.Refresh()
            $applicationProcessAlive = -not $script:process.HasExited
        }
        catch [InvalidOperationException] {
        }
    }

    if ($applicationProcessAlive) {
        return [pscustomobject][ordered]@{
            Source = 'application-process-probe-unavailable'
            ReadOnly = $true
            TokenMatched = $false
            Setting = 'Unavailable'
            IsSupported = $null
            GetAllAsync = 'Unavailable'
            Assembly = ''
            Error = 'The in-process AppNotificationManager probe did not produce a successful record before the acceptance timeout.'
        }
    }

    $result = [ordered]@{
        Source = 'external-reflection-fallback'
        TokenMatched = $false
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

        $result.GetAllAsync = 'not-queried-outside-application-process'
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-AppNotificationRecords {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$NotificationState)

    if ($null -eq $NotificationState -or $null -eq $NotificationState.GetAllAsync) {
        return @()
    }

    try {
        if ($null -eq $NotificationState.GetAllAsync.Notifications) {
            return @()
        }

        return @($NotificationState.GetAllAsync.Notifications)
    }
    catch {
        return @()
    }
}

function Wait-AppNotificationPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$BodyFragment,
        [int]$TimeoutSeconds = 180
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Get-AppNotificationState
        if ([string]$state.Source -eq 'Taskronome application process' -and
            [bool]$state.TokenMatched -and
            $null -ne $state.GetAllAsync -and
            [bool]$state.GetAllAsync.Succeeded) {
            $matching = @(Get-AppNotificationRecords $state | Where-Object {
                    [string]$_.Payload -like "*$Title*" -and [string]$_.Payload -like "*$BodyFragment*"
                })
            if ($matching.Count -gt 0) {
                return $state
            }
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "The in-process notification history did not expose title '$Title' and body fragment '$BodyFragment' before the timeout."
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

function Assert-CoreLayout {
    Select-Tab 'TasksTab'
    foreach ($id in @('TaskGrid', 'NewTaskButton', 'StartRotationButton')) {
        $element = Find-ElementById $id
        $bounds = $element.Current.BoundingRectangle
        Assert-True ($bounds.Width -gt 0 -and $bounds.Height -gt 0) "$id had no visible bounds."
        Assert-True (-not [string]::IsNullOrWhiteSpace((Get-ElementText $element))) "$id had no accessible text."
    }

    Select-Tab 'RunningTab'
    foreach ($id in @('CurrentTaskText', 'RemainingText', 'PauseResumeButton', 'SkipButton', 'CompleteButton', 'StopButton')) {
        $element = Find-ElementById $id
        $bounds = $element.Current.BoundingRectangle
        Assert-True ($bounds.Width -gt 0 -and $bounds.Height -gt 0) "$id had no visible bounds."
        Assert-True (-not [string]::IsNullOrWhiteSpace((Get-ElementText $element))) "$id had no accessible text."
    }

    Select-Tab 'TasksTab'
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
        $actual = 'N/A; recorded environment condition applies.'
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
            Stop-RotationSafely
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
    $script:process = Start-Process -FilePath $resolvedAppPath -ArgumentList $script:applicationArguments -PassThru
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

        if (-not $script:process.WaitForExit(3000)) {
            Stop-Process -Id $script:process.Id -Force -ErrorAction Stop
            [void]$script:process.WaitForExit(5000)
        }
    }
    catch [InvalidOperationException] {
    }
    finally {
        $script:window = $null
    }
}

function Wait-WindowVisibility {
    param(
        [Parameter(Mandatory = $true)][bool]$Visible,
        [int]$TimeoutSeconds = 5
    )

    if ($null -eq $script:window) {
        return $false
    }

    $handle = [IntPtr]$script:window.Current.NativeWindowHandle
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ([TaskronomeAcceptanceNative]::IsWindowVisible($handle) -eq $Visible) {
            return $true
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Activate-AppWindow {
    if ($null -eq $script:window) {
        throw 'The Taskronome main window is not available for activation.'
    }

    $handle = [IntPtr]$script:window.Current.NativeWindowHandle
    [TaskronomeAcceptanceNative]::SetForegroundWindow($handle) | Out-Null
    $script:window.SetFocus()
    Start-Sleep -Milliseconds 200
}

function Get-TextFromElementId {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $element = Find-ElementByIdAnyWindow $AutomationId
    return Get-ElementText $element
}

function Get-ToggleState {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    $element = Find-ElementByIdAnyWindow $AutomationId
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    return ([System.Windows.Automation.TogglePattern]$pattern).Current.ToggleState.ToString()
}

function Get-ButtonEnabled {
    param([Parameter(Mandatory = $true)][string]$AutomationId)

    return [bool](Find-ElementByIdAnyWindow $AutomationId).Current.IsEnabled
}

function Test-RequiredAutomationIds {
    $tabIds = [ordered]@{
        TasksTab = @(
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
            'StartRotationButton')
        RunningTab = @(
            'CurrentTaskText',
            'RemainingText',
            'PauseResumeButton',
            'SkipButton',
            'CompleteButton',
            'StopButton')
        StatisticsTab = @(
            'StatisticsScopeComboBox',
            'ExportCsvButton')
        SettingsTab = @(
            'AlwaysOnTopCheckBox',
            'PlaySoundCheckBox',
            'ShowNotificationCheckBox',
            'MinimizeToTrayCheckBox',
            'TestNotificationButton')
    }
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

    $missing = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $script:window) {
        [void]$missing.Add('MainWindow')
    }

    foreach ($tab in $tabIds.GetEnumerator()) {
        Select-Tab $tab.Key
        foreach ($id in $tab.Value) {
            if ($null -eq (Find-ElementById $id -TimeoutSeconds 3 -Optional)) {
                [void]$missing.Add($id)
            }
        }
    }

    if ($missing.Count -eq 0) {
        Select-Tab 'TasksTab'
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
        if (-not (Wait-EditorClosed)) {
            foreach ($editorWindow in @(Get-EditorWindows)) {
                try {
                    $windowPattern = $editorWindow.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                    ([System.Windows.Automation.WindowPattern]$windowPattern).Close()
                }
                catch {
                }
            }
            Assert-True (Wait-EditorClosed) 'The AutomationId probe left a task editor open.'
        }
    }

    Assert-Equal 0 $missing.Count 'Required AutomationId controls were missing.'
    $tabControlCount = ($tabIds.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    return "located-$($tabControlCount + $editorIds.Count)-controls"
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
        [void](Find-ElementByIdAnyWindow 'TaskEditorWindow' -TimeoutSeconds 10)
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
            try {
                Set-EditorFields $invalid.Name $invalid.Notes $invalid.Hours $invalid.Minutes $invalid.Seconds
                Invoke-Element (Find-ElementByIdAnyWindow 'SaveTaskButton')
                Start-Sleep -Milliseconds 150
                $editor = Find-ElementByIdAnyWindow 'TaskEditorWindow' -TimeoutSeconds 2 -Optional
                Assert-True ($null -ne $editor) 'Invalid task input unexpectedly closed the editor.'
                $validation = Get-TextByIdEventually 'ValidationTextBlock' 5
                Assert-True (-not [string]::IsNullOrWhiteSpace($validation)) 'ValidationTextBlock was empty for invalid input.'
                return $validation
            }
            finally {
                $cancel = Find-ElementByIdAnyWindow 'CancelTaskButton' -TimeoutSeconds 1 -Optional
                if ($null -ne $cancel -and $cancel.Current.IsEnabled) {
                    Invoke-Element $cancel
                }
                [void](Wait-EditorClosed)
            }
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
        $confirmationText = Find-ElementById 'ConfirmationText'
        Assert-True (-not [string]::IsNullOrWhiteSpace((Get-ElementText $confirmationText))) 'Confirmation text control was not visible.'
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
        $before = Read-DataSnapshot
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Select-Tab 'TasksTab'
        Assert-True (-not (Get-ButtonEnabled 'EditTaskButton')) 'Task editing remained enabled during rotation.'
        Select-Tab 'RunningTab'
        Start-Sleep -Seconds 3
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        $data = Read-DataSnapshot
        $segments = @($data.WorkSegmentCount)
        $delta = $data.RecordedDuration - $before.RecordedDuration
        Assert-True ($data.WorkSegmentCount -ge 1) 'Task A did not create a work segment.'
        Assert-Equal ($before.WorkSegmentCount + 1) $data.WorkSegmentCount 'Task A did not create exactly one work segment.'
        Assert-True ($delta.TotalSeconds -ge 1.25 -and $delta.TotalSeconds -le 2.75) "Task A recorded duration delta was outside tolerance: $delta."
        Assert-True ($data.CurrentTaskName -eq $taskB) "The next confirmation was not for Task B; it was '$($data.CurrentTaskName)'."
        return [pscustomobject]@{ SegmentCount = $segments; Recorded = $delta.ToString() }
    } -ScreenshotName '08-task-a-complete' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-task-b-reconfirmation' -Category 'Rotation' -Expected 'Task B requires a new in-app confirmation and records about three seconds.' -Action {
        $before = Read-DataSnapshot
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'Task B confirmation button was not enabled.'
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Seconds 4
        [void](Wait-AppState 'AwaitingConfirmation' 6)
        $data = Read-DataSnapshot
        $delta = $data.RecordedDuration - $before.RecordedDuration
        Assert-Equal ($before.WorkSegmentCount + 1) $data.WorkSegmentCount 'Task B did not create exactly one work segment.'
        Assert-True ($delta.TotalSeconds -ge 2.25 -and $delta.TotalSeconds -le 4.25) "Task B recorded duration delta was outside tolerance: $delta."
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
        Start-Sleep -Milliseconds 600
        try { Invoke-ButtonById 'SkipButton' | Out-Null } catch { }
        Start-Sleep -Milliseconds 600
        $task = Get-TaskJson $current
        Assert-Equal 'False' ([string]$task.Completed) 'Skipped task was marked completed.'
        Stop-RotationViaUi
    } -SnapshotFiles | Out-Null

    $earlyTaskName = '提前完成验收任务'
    Invoke-Recorded -TestId 'rotation-complete-early-real-duration' -Category 'Rotation' -Expected 'Early completion records only real running time and marks a dedicated task complete.' -Action {
        Select-Tab 'TasksTab'
        if ($null -eq (Get-TaskJson $earlyTaskName)) {
            Add-TaskViaUi $earlyTaskName 'complete early' 0 0 5
        }

        foreach ($task in @(Read-DataSnapshot).Tasks) {
            if ([string]$task.Name -ne $earlyTaskName -and [string]$task.Enabled -eq 'True') {
                Select-Task ([string]$task.Name) | Out-Null
                Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
            }
        }

        Select-Task $earlyTaskName | Out-Null
        $earlyTask = Get-TaskJson $earlyTaskName
        if ([string]$earlyTask.Completed -eq 'True') {
            Invoke-ButtonById 'ResetCompletionButton' | Out-Null
            Assert-True (Confirm-Dialog) 'The reset dialog for the reusable early-completion task was not available.'
            Start-Sleep -Milliseconds 250
        }
        if ([string](Get-TaskJson $earlyTaskName).Enabled -eq 'False') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }

        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $current = (Read-DataSnapshot).CurrentTaskName
        Assert-Equal $earlyTaskName $current 'The dedicated early-completion task was not selected.'
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 700
        $before = Read-DataSnapshot
        Invoke-ButtonById 'CompleteButton' | Out-Null
        [void](Wait-AppState 'Completed' 5)
        $after = Read-DataSnapshot
        $task = Get-TaskJson $earlyTaskName
        $delta = $after.RecordedDuration - $before.RecordedDuration
        Assert-Equal 'True' ([string]$task.Completed) 'Early-completed task was not marked completed.'
        Assert-True ($delta.TotalSeconds -ge 0.35 -and $delta.TotalSeconds -lt 2.0) "Early completion recorded an unexpected duration: $delta."
        Assert-Equal ($before.WorkSegmentCount + 1) $after.WorkSegmentCount 'Early completion did not create exactly one work segment.'
        $document = Get-Content -LiteralPath (Join-Path $script:dataDir 'data.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $lastEarlySegment = @($document.WorkSegments | Where-Object { [string]$_.TaskName -eq $earlyTaskName } | Select-Object -Last 1)
        Assert-True ($lastEarlySegment.Count -eq 1) 'Early completion did not persist a segment for the dedicated task.'
        Assert-Equal 'CompletedEarly' ([string]$lastEarlySegment[0].EndReason) 'Early completion was not persisted with the CompletedEarly end reason.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'completion-reopen-and-reset-history' -Category 'Persistence' -Expected 'Reopen/reset completion changes status but keeps historical segments.' -Action {
        $completedTask = (Read-DataSnapshot).Tasks | Where-Object { $_.Completed -eq $true } | Select-Object -First 1
        Assert-True ($null -ne $completedTask) 'No completed task was available for reopen/reset verification.'
        Select-Tab 'TasksTab'
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
        Start-Sleep -Milliseconds 600
        Invoke-ButtonById 'CompleteButton' | Out-Null
        [void](Wait-AppState 'Completed' 5)
        Select-Tab 'TasksTab'
        Select-Task $current | Out-Null
        Invoke-ButtonById 'ResetCompletionButton' | Out-Null
        Assert-True (Confirm-Dialog) 'The reset-completion confirmation dialog was not available.'
        Start-Sleep -Milliseconds 250
        Assert-Equal 'False' ([string](Get-TaskJson $current).Completed) 'Reset completion did not clear completion.'
        Assert-Equal ($historyBefore + 1) (Read-DataSnapshot).WorkSegmentCount 'Reset completion changed historical segment count unexpectedly.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-rapid-controls-no-duplicate' -Category 'Rotation/Idempotency' -Expected 'Rapid double-click confirmation, pause, skip, complete, and stop controls produce only valid state transitions and accounting.' -Action {
        $rapidTaskName = '快速控件验收任务'
        $rapidStopTaskName = '快速停止验收任务'
        Select-Tab 'TasksTab'
        if ($null -eq (Get-TaskJson $rapidTaskName)) {
            Add-TaskViaUi $rapidTaskName 'rapid control idempotency' 0 0 8
        }
        if ($null -eq (Get-TaskJson $rapidStopTaskName)) {
            Add-TaskViaUi $rapidStopTaskName 'rapid stop idempotency' 0 2 0
        }

        foreach ($task in @(Read-DataSnapshot).Tasks) {
            if ([string]$task.Name -ne $rapidTaskName -and [string]$task.Enabled -eq 'True') {
                Select-Task ([string]$task.Name) | Out-Null
                Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
            }
        }

        Select-Task $rapidTaskName | Out-Null
        $rapidTask = Get-TaskJson $rapidTaskName
        if ([string]$rapidTask.Completed -eq 'True') {
            Invoke-ButtonById 'ResetCompletionButton' | Out-Null
            Assert-True (Confirm-Dialog) 'The rapid-control reset dialog was not available.'
            Start-Sleep -Milliseconds 250
        }
        if ([string](Get-TaskJson $rapidTaskName).Enabled -eq 'False') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }

        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $confirmEventsBefore = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'TaskConfirmed' }).Count
        Double-ClickButtonById 'ConfirmTaskButton'
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 500
        $confirmEventsAfter = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'TaskConfirmed' }).Count
        Assert-Equal ($confirmEventsBefore + 1) $confirmEventsAfter 'Rapid confirmation produced duplicate TaskConfirmed events.'
        Start-Sleep -Milliseconds 600

        $pauseEventsBefore = Read-DataDocument
        Double-ClickButtonById 'PauseResumeButton'
        [void](Wait-AppState 'PausedManual' 5)
        $pauseEventsAfter = Read-DataDocument
        Assert-Equal ((@($pauseEventsBefore.Events | Where-Object { [string]$_.Type -eq 'ManualPaused' }).Count) + 1) (@($pauseEventsAfter.Events | Where-Object { [string]$_.Type -eq 'ManualPaused' }).Count) 'Rapid pause did not create exactly one ManualPaused event.'
        Assert-Equal (@($pauseEventsBefore.Events | Where-Object { [string]$_.Type -eq 'ManualResumed' }).Count) (@($pauseEventsAfter.Events | Where-Object { [string]$_.Type -eq 'ManualResumed' }).Count) 'Rapid pause generated an unexpected second action.'
        Start-Sleep -Milliseconds 600
        Invoke-ButtonById 'PauseResumeButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 600

        $beforeSkip = Read-DataSnapshot
        $skipEventsBefore = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'SliceSkipped' }).Count
        Double-ClickButtonById 'SkipButton'
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        Start-Sleep -Milliseconds 600
        $afterSkip = Read-DataSnapshot
        $skipEventsAfter = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'SliceSkipped' }).Count
        $skipRecordedDelta = $afterSkip.RecordedDuration - $beforeSkip.RecordedDuration
        Assert-Equal ($beforeSkip.WorkSegmentCount + 1) $afterSkip.WorkSegmentCount 'Rapid skip did not create exactly one real-running work segment.'
        Assert-True ($skipRecordedDelta.TotalSeconds -ge 0.35 -and $skipRecordedDelta.TotalSeconds -le 1.5) "Rapid skip recorded duration was outside the real-running tolerance: $skipRecordedDelta."
        Assert-Equal ($skipEventsBefore + 1) $skipEventsAfter 'Rapid skip produced duplicate SliceSkipped events.'
        Assert-Equal 'False' ([string](Get-TaskJson $rapidTaskName).Completed) 'Rapid skip marked the task completed.'

        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 600
        $beforeComplete = Read-DataSnapshot
        $completeEventsBefore = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'TaskCompletedEarly' }).Count
        Double-ClickButtonById 'CompleteButton'
        [void](Wait-AppState 'Completed' 5)
        Start-Sleep -Milliseconds 300
        $afterComplete = Read-DataSnapshot
        $completeEventsAfter = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'TaskCompletedEarly' }).Count
        Assert-Equal ($beforeComplete.WorkSegmentCount + 1) $afterComplete.WorkSegmentCount 'Rapid complete created duplicate work segments.'
        Assert-Equal ($completeEventsBefore + 1) $completeEventsAfter 'Rapid complete produced duplicate completion events.'
        Assert-Equal 'True' ([string](Get-TaskJson $rapidTaskName).Completed) 'Rapid complete did not mark the task completed.'

        Select-Tab 'TasksTab'
        Select-Task $rapidStopTaskName | Out-Null
        if ([string](Get-TaskJson $rapidStopTaskName).Enabled -eq 'False') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 600
        $stopEventsBefore = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'RotationStopped' }).Count
        Double-ClickButtonById 'StopButton'
        Assert-True (Confirm-Dialog) 'The rapid-stop confirmation dialog was not available.'
        [void](Wait-AppState 'Idle' 10)
        $stopEventsAfter = @((Read-DataDocument).Events | Where-Object { [string]$_.Type -eq 'RotationStopped' }).Count
        Assert-Equal ($stopEventsBefore + 1) $stopEventsAfter 'Rapid stop produced duplicate RotationStopped events.'
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'rotation-confirmation-timeout-production' -Category 'Production Confirmation' -Expected 'A real ten-second confirmation timeout pauses as PausedAbsent and freezes work.' -Action {
        Select-Tab 'TasksTab'
        $timeoutTaskName = '确认超时验收任务'
        if ($null -eq (Get-TaskJson $timeoutTaskName)) {
            Add-TaskViaUi $timeoutTaskName 'production confirmation timeout' 0 2 0
        }
        foreach ($task in @(Read-DataSnapshot).Tasks) {
            if ([string]$task.Name -ne $timeoutTaskName -and [string]$task.Enabled -eq 'True') {
                Select-Task ([string]$task.Name) | Out-Null
                Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
            }
        }
        Select-Task $timeoutTaskName | Out-Null
        $timeoutTask = Get-TaskJson $timeoutTaskName
        if ([string]$timeoutTask.Completed -eq 'True') {
            Invoke-ButtonById 'ResetCompletionButton' | Out-Null
            Assert-True (Confirm-Dialog) 'The timeout-task reset dialog was not available.'
            Start-Sleep -Milliseconds 250
        }
        if ([string](Get-TaskJson $timeoutTaskName).Enabled -eq 'False') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $before = Read-DataSnapshot
        $beforeUi = Get-TextFromElementId 'RemainingText'
        Start-Sleep -Seconds 11
        [void](Wait-AppState 'PausedAbsent' 5)
        $absentPanel = Find-ElementById 'AbsentPausePanel'
        Assert-True (-not $absentPanel.Current.IsOffscreen) 'Absent-pause panel was not visible.'
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
        Assert-Equal $before.Remaining $recovery.Remaining 'Recovery did not restore the complete task slice.'
        Start-Sleep -Milliseconds 600
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi
    } -ScreenshotName '10-production-timeout-paused-absent' -SnapshotFiles | Out-Null

    return $true
}

function Run-NotificationFlow {
    Invoke-Recorded -TestId 'notification-api-setting-and-history' -Category 'Notifications' -Expected 'Read AppNotificationManager setting and history without changing application state.' -Action {
        $notificationApi = Get-AppNotificationState -WaitForSuccess
        Assert-True ($null -ne $notificationApi) 'Notification API evidence was not returned.'
        Assert-Equal 'Taskronome application process' $notificationApi.Source 'Notification API evidence did not come from the application process.'
        Assert-True $notificationApi.ReadOnly 'Notification API probe was not read-only.'
        Assert-True $notificationApi.TokenMatched 'Notification API probe token did not match the acceptance-run token.'
        Assert-True ($null -ne $notificationApi.IsSupported) 'AppNotificationManager.IsSupported() was not recorded.'
        Assert-True ($null -ne $notificationApi.GetAllAsync -and $notificationApi.GetAllAsync.Succeeded) 'AppNotificationManager.GetAllAsync() did not succeed.'
        return $notificationApi
    } -ScreenshotName '11-notification-settings' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'notification-test-button-production' -Category 'Notifications' -Expected 'Test notification uses the real notification service in production mode and does not crash.' -Action {
        $before = Get-AppNotificationState -WaitForSuccess
        Select-Tab 'SettingsTab'
        Invoke-ButtonById 'TestNotificationButton' | Out-Null
        Start-Sleep -Seconds 3
        Dismiss-Dialogs
        $after = Wait-AppNotificationPayload 'Taskronome 测试通知' '系统通知通道工作正常' 180
        $testNotifications = @(Get-AppNotificationRecords $after | Where-Object { [string]$_.Payload -match 'Taskronome.*测试通知|系统通知通道工作正常' })
        $beforeCount = @(Get-AppNotificationRecords $before).Count
        $afterCount = @(Get-AppNotificationRecords $after).Count
        Assert-True ($testNotifications.Count -gt 0 -or $afterCount -gt $beforeCount) 'The production test notification was not recorded by GetAllAsync().'
        Select-Tab 'RunningTab'
        Assert-True ($null -ne $script:process -and -not $script:process.HasExited) 'Test notification caused the application to exit.'
    } -ScreenshotName '12-notification-test' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'notification-task-turn-not-auto-confirm' -Category 'Notifications' -Expected 'A task-turn notification, if visible, activates the app while leaving AwaitingConfirmation and creating no work.' -Action {
        Select-Tab 'TasksTab'
        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $before = Read-DataSnapshot
        Start-Sleep -Milliseconds 1000
        $expectedTitle = "轮到：$($before.CurrentTaskName)"
        $expectedBodyFragment = '10 秒'
        $apiAfterRequest = Wait-AppNotificationPayload $expectedTitle $expectedBodyFragment 180
        $matchingPayloads = @(Get-AppNotificationRecords $apiAfterRequest | Where-Object {
                [string]$_.Payload -like "*$expectedTitle*" -and [string]$_.Payload -like "*$expectedBodyFragment*"
            })
        Assert-True ($matchingPayloads.Count -gt 0) 'GetAllAsync did not expose the task-turn notification title/body payload.'
        $notification = Find-GlobalElementByName "轮到：$($before.CurrentTaskName)" 5
        $body = Find-GlobalElementByName '请在 10 秒内回到 Taskronome 并点击“开始任务”，否则轮转将暂停。' 2
        if ($null -eq $notification) {
            if (-not $OperatorAssistance) {
                throw 'The real task-turn notification was not exposed to UI Automation; run with -OperatorAssistance for one operator click.'
            }

            Read-Host '请确认通知标题和正文包含当前任务名及“10 秒”，再在通知中心点击本次 Taskronome 任务通知一次；完成后按回车继续' | Out-Null
        }
        else {
            Assert-Equal $expectedTitle ([string]$notification.Current.Name) 'The notification title was not exposed as expected.'
            Assert-True ($null -ne $body) 'The notification body was not exposed to UI Automation.'
            try {
                Invoke-Element $notification
            }
            catch {
                $center = Get-ElementCenter $notification
                [TaskronomeAcceptanceNative]::DoubleClickAt($center.X, $center.Y)
            }
        }

        Start-Sleep -Seconds 1
        Assert-True ([TaskronomeAcceptanceNative]::IsWindowVisible([IntPtr]$script:window.Current.NativeWindowHandle)) 'Notification activation did not return to the main window.'
        $afterActivation = Read-DataSnapshot
        Assert-Equal 'AwaitingConfirmation' $afterActivation.State 'Notification activation confirmed the task unexpectedly.'
        Assert-Equal $before.EventCount $afterActivation.EventCount 'Notification activation unexpectedly added an application event.'
        Assert-Equal $before.WorkSegmentCount $afterActivation.WorkSegmentCount 'Notification activation created a work segment.'
        Assert-Equal $before.RecordedDuration $afterActivation.RecordedDuration 'Notification activation recorded work.'
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'In-app confirmation did not remain available after notification activation.'
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi
    } -ScreenshotName '13-notification-activation-awaiting' -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'notification-app-setting-fallback' -Category 'Notifications/Fallback' -Expected 'When Windows notification permission is disabled, the real task reminder falls back without crashing, keeps in-app confirmation, and the original permission is restored.' -Action {
        if (-not $OperatorAssistance) {
            throw 'Disabling and restoring Windows notification permission requires one operator action; rerun with -OperatorAssistance.'
        }

        $initialApi = Get-AppNotificationState -WaitForSuccess
        Assert-Equal 'Enabled' ([string]$initialApi.Setting) 'The notification permission was not enabled before the fallback test.'
        Select-Tab 'SettingsTab'
        if ((Get-ToggleState 'ShowNotificationCheckBox') -eq 'Off') {
            Toggle-Element (Find-ElementById 'ShowNotificationCheckBox')
        }

        $fallbackTaskName = '通知回退验收任务'
        Select-Tab 'TasksTab'
        if ($null -eq (Get-TaskJson $fallbackTaskName)) {
            Add-TaskViaUi $fallbackTaskName 'notification fallback' 0 2 0
        }
        foreach ($task in @(Read-DataSnapshot).Tasks) {
            if ([string]$task.Name -ne $fallbackTaskName -and [string]$task.Enabled -eq 'True') {
                Select-Task ([string]$task.Name) | Out-Null
                Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
            }
        }
        Select-Task $fallbackTaskName | Out-Null
        if ([string](Get-TaskJson $fallbackTaskName).Enabled -eq 'False') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }

        Start-Process 'ms-settings:notifications' | Out-Null
        Read-Host '请在 Windows 通知设置中关闭 Taskronome 的通知权限，回到 Taskronome 后按回车继续' | Out-Null
        Activate-AppWindow
        $disabledApi = Get-AppNotificationState -WaitForSuccess
        Assert-True ([string]$disabledApi.Setting -ne 'Enabled') "Windows notification permission still reports Enabled after the operator disabled it: $($disabledApi.Setting)."

        Invoke-ButtonById 'StartRotationButton' | Out-Null
        $awaiting = Wait-AppState 'AwaitingConfirmation' 10
        Assert-True ((Find-ElementById 'ConfirmationPanel').Current.IsOffscreen -eq $false) 'In-app confirmation was not visible during notification fallback.'
        Assert-True (Get-ButtonEnabled 'ConfirmTaskButton') 'In-app confirmation was not available during notification fallback.'
        Start-Sleep -Seconds 2
        Dismiss-Dialogs
        Assert-True ($null -ne $script:process -and -not $script:process.HasExited) 'Notification fallback crashed the app.'
        $fallbackLog = Get-AppLogText
        Assert-True ($fallbackLog -match 'Sending a Windows app notification failed|notification.*failed|回退') 'Notification fallback did not record the expected failure/fallback evidence.'
        $fallbackUi = Find-GlobalElementByName "轮到：$fallbackTaskName" 2
        if ($null -eq $fallbackUi) {
            Read-Host '请确认托盘气泡、系统声音、任务栏闪烁或明确的通知失败提示已出现；确认后按回车继续' | Out-Null
        }

        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi

        Start-Process 'ms-settings:notifications' | Out-Null
        Read-Host '请在 Windows 通知设置中恢复 Taskronome 的原始通知权限，回到 Taskronome 后按回车继续' | Out-Null
        Activate-AppWindow
        $restoredApi = Get-AppNotificationState -WaitForSuccess
        Assert-Equal ([string]$initialApi.Setting) ([string]$restoredApi.Setting) 'The original Windows notification permission was not restored.'
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
        $beforeRunningEnter = Read-DataSnapshot
        [TaskronomeAcceptanceNative]::SendKey(0x0D)
        Start-Sleep -Milliseconds 300
        $afterRunningEnter = Read-DataSnapshot
        Assert-Equal 'Running' $afterRunningEnter.State 'Enter changed the state while the task was already running.'
        Assert-Equal $beforeRunningEnter.EventCount $afterRunningEnter.EventCount 'Enter generated an event while confirmation was not available.'
        [TaskronomeAcceptanceNative]::SendKey(0x20)
        [void](Wait-AppState 'PausedManual' 5)
        [TaskronomeAcceptanceNative]::SendKey(0x20)
        [void](Wait-AppState 'Running' 5)
        Stop-RotationViaUi
    } -SnapshotFiles | Out-Null

    Invoke-Recorded -TestId 'keyboard-ctrl-n-and-tab-focus' -Category 'Window/Keyboard' -Expected 'Ctrl+N opens an editor only when editing is allowed, and Tab navigation exposes visible focus.' -Action {
        Select-Tab 'TasksTab'
        $script:window.SetFocus()
        $mainHandle = [IntPtr]$script:window.Current.NativeWindowHandle
        [TaskronomeAcceptanceNative]::SetForegroundWindow($mainHandle) | Out-Null
        [TaskronomeAcceptanceNative]::SendCtrlKey(0x4E)
        [void](Wait-Editor)
        Assert-True ($null -ne (Find-ElementByIdAnyWindow 'NameTextBox')) 'Ctrl+N did not open the task editor while idle.'
        Invoke-Element (Find-ElementByIdAnyWindow 'CancelTaskButton')
        [void](Wait-EditorClosed)

        $script:window.SetFocus()
        [TaskronomeAcceptanceNative]::SetForegroundWindow($mainHandle) | Out-Null
        [TaskronomeAcceptanceNative]::SendKey(0x09)
        Start-Sleep -Milliseconds 200
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        Assert-True ($null -ne $focused) 'Tab navigation did not expose a focused element.'
        Assert-Equal $script:process.Id $focused.Current.ProcessId 'Tab focus moved outside the Taskronome process.'
        Assert-True $focused.Current.HasKeyboardFocus 'The focused element did not report keyboard focus.'
        Assert-True ($focused.Current.BoundingRectangle.Width -gt 0 -and $focused.Current.BoundingRectangle.Height -gt 0) 'Tab focus had no visible bounds.'

        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        $beforeAwaitingCtrlN = Read-DataSnapshot
        $script:window.SetFocus()
        [TaskronomeAcceptanceNative]::SetForegroundWindow($mainHandle) | Out-Null
        [TaskronomeAcceptanceNative]::SendCtrlKey(0x4E)
        Start-Sleep -Milliseconds 500
        Assert-Equal 0 (@(Get-EditorWindows).Count) 'Ctrl+N opened an editor while confirmation was required.'
        Assert-Equal 'AwaitingConfirmation' (Read-DataSnapshot).State 'Ctrl+N changed state while confirmation was required.'
        Assert-Equal $beforeAwaitingCtrlN.EventCount (Read-DataSnapshot).EventCount 'Ctrl+N changed rotation events while confirmation was required.'

        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        [TaskronomeAcceptanceNative]::SendCtrlKey(0x4E)
        Start-Sleep -Milliseconds 500
        Assert-Equal 0 (@(Get-EditorWindows).Count) 'Ctrl+N opened an editor while the task was running.'
        Stop-RotationViaUi
    } -ScreenshotName '16-keyboard-focus-and-ctrl-n' -SnapshotFiles | Out-Null

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
        $second = Start-Process -FilePath $resolvedAppPath -ArgumentList $script:applicationArguments -PassThru
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

function Find-TrayMenuItem {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [int]$TimeoutSeconds = 3
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $elements = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($element in $elements) {
                try {
                    $isMenuItem = $element.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuItem
                    $name = [string]$element.Current.Name
                    if ($isMenuItem -and @($Names | Where-Object { $name -eq $_ -or $name -like "*$_*" }).Count -gt 0) {
                        return $element
                    }
                }
                catch [System.Windows.Automation.ElementNotAvailableException] {
                }
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
        }

        Start-Sleep -Milliseconds 100
    }

    return $null
}

function Invoke-TrayMenuAction {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$OperatorPrompt
    )

    $tray = Find-TrayTaskronomeElement
    if ($null -ne $tray) {
        $center = Get-ElementCenter $tray
        [TaskronomeAcceptanceNative]::RightClickAt($center.X, $center.Y)
        $item = Find-TrayMenuItem $Names 3
        if ($null -ne $item) {
            Invoke-Element $item
            Start-Sleep -Milliseconds 300
            return 'uia'
        }
    }

    if (-not $OperatorAssistance) {
        throw ("Tray menu item '{0}' was not exposed to UI Automation." -f ($Names -join '/'))
    }

    Read-Host $OperatorPrompt | Out-Null
    return 'operator'
}

function Restore-MainWindowViaSingleInstance {
    if (Wait-WindowVisibility $true 1) {
        return $true
    }

    if ($null -eq $script:process) {
        return $false
    }

    try {
        $script:process.Refresh()
        if ($script:process.HasExited) {
            return $false
        }

        $second = Start-Process -FilePath $resolvedAppPath -ArgumentList $script:applicationArguments -PassThru
        [void]$second.WaitForExit(10000)
        return (Wait-WindowVisibility $true 5)
    }
    catch {
        return $false
    }
}

function Run-TrayFlow {
    Invoke-Recorded -TestId 'close-to-tray-process-preserved' -Category 'Tray' -Expected 'Closing the main window hides it to the tray while the process remains alive.' -Action {
        Select-Tab 'SettingsTab'
        if ((Get-ToggleState 'MinimizeToTrayCheckBox') -eq 'Off') {
            Toggle-Element (Find-ElementById 'MinimizeToTrayCheckBox')
        }
        $pattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        ([System.Windows.Automation.WindowPattern]$pattern).Close()
        Assert-True (Wait-WindowVisibility $false 5) 'Close-to-tray did not hide the window before timeout.'
        $script:process.Refresh()
        Assert-True (-not $script:process.HasExited) 'Close-to-tray unexpectedly exited the process.'
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

    if (-not (Restore-MainWindowViaSingleInstance)) {
        Stop-Taskronome -Force
        Start-Taskronome
    }

    Invoke-Recorded -TestId 'tray-menu-actions' -Category 'Tray' -Expected 'Tray Show, Pause/Resume, Always-on-top, and Exit menu actions change real application state and save before exit.' -Action {
        $trayTaskName = '托盘菜单验收任务'
        Select-Tab 'TasksTab'
        if ($null -eq (Get-TaskJson $trayTaskName)) {
            Add-TaskViaUi $trayTaskName 'tray menu actions' 0 2 0
        }

        foreach ($task in @(Read-DataSnapshot).Tasks) {
            if ([string]$task.Name -ne $trayTaskName -and [string]$task.Enabled -eq 'True') {
                Select-Task ([string]$task.Name) | Out-Null
                Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
            }
        }

        Select-Task $trayTaskName | Out-Null
        if ([string](Get-TaskJson $trayTaskName).Enabled -eq 'False') {
            Invoke-ButtonById 'ToggleEnabledButton' | Out-Null
        }

        Invoke-ButtonById 'StartRotationButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 10)
        Invoke-ButtonById 'ConfirmTaskButton' | Out-Null
        [void](Wait-AppState 'Running' 5)
        Start-Sleep -Milliseconds 700

        $closePattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        ([System.Windows.Automation.WindowPattern]$closePattern).Close()
        Assert-True (Wait-WindowVisibility $false 5) 'The tray menu scenario did not hide the window.'
        [void](Invoke-TrayMenuAction @('显示 Taskronome') '请右键 Taskronome 托盘图标并点击“显示 Taskronome”；窗口显示后按回车继续')
        Assert-True (Wait-WindowVisibility $true 5) 'Tray Show menu did not restore the main window.'

        $beforePause = Read-DataSnapshot
        $closePattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        ([System.Windows.Automation.WindowPattern]$closePattern).Close()
        Assert-True (Wait-WindowVisibility $false 5) 'The window did not hide before the tray pause action.'
        [void](Invoke-TrayMenuAction @('暂停') '请右键 Taskronome 托盘图标并点击“暂停”；完成后按回车继续')
        $paused = Wait-AppState 'PausedManual' 5
        Assert-Equal $beforePause.WorkSegmentCount $paused.WorkSegmentCount 'Tray pause created an unexpected duplicate segment.'

        [void](Invoke-TrayMenuAction @('恢复') '请右键 Taskronome 托盘图标并点击“恢复”；完成后按回车继续')
        [void](Wait-AppState 'Running' 5)

        $topmostHandle = [IntPtr]$script:window.Current.NativeWindowHandle
        $topmostBefore = [TaskronomeAcceptanceNative]::IsTopMost($topmostHandle)
        $closePattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        ([System.Windows.Automation.WindowPattern]$closePattern).Close()
        Assert-True (Wait-WindowVisibility $false 5) 'The window did not hide before the tray topmost action.'
        [void](Invoke-TrayMenuAction @('窗口始终置顶') '请右键 Taskronome 托盘图标并点击“窗口始终置顶”；完成后按回车继续')
        Start-Sleep -Milliseconds 300
        Assert-Equal (-not $topmostBefore) ([TaskronomeAcceptanceNative]::IsTopMost($topmostHandle)) 'Tray topmost menu did not toggle the window style.'
        [void](Invoke-TrayMenuAction @('窗口始终置顶') '请再次右键 Taskronome 托盘图标并点击“窗口始终置顶”恢复原状态；完成后按回车继续')
        Start-Sleep -Milliseconds 300
        Assert-Equal $topmostBefore ([TaskronomeAcceptanceNative]::IsTopMost($topmostHandle)) 'Tray topmost menu did not restore the window style.'

        [void](Invoke-TrayMenuAction @('显示 Taskronome') '请右键 Taskronome 托盘图标并点击“显示 Taskronome”；窗口显示后按回车继续')
        Assert-True (Wait-WindowVisibility $true 5) 'Tray Show menu did not restore the window after topmost testing.'
        Stop-RotationViaUi

        $dataPath = Join-Path $script:dataDir 'data.json'
        $backupPath = Join-Path $script:dataDir 'data.json.bak'
        $closePattern = $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        ([System.Windows.Automation.WindowPattern]$closePattern).Close()
        Assert-True (Wait-WindowVisibility $false 5) 'The window did not hide before the tray exit action.'
        [void](Invoke-TrayMenuAction @('退出') '请右键 Taskronome 托盘图标并点击“退出”；确认程序退出后按回车继续')
        $script:process.Refresh()
        Assert-True ($script:process.HasExited -or @(Get-ProcessIdsForApp).Count -eq 0) 'Tray Exit did not terminate the only Taskronome process.'
        Assert-True (Test-Path -LiteralPath $dataPath -PathType Leaf) 'Tray Exit did not leave data.json.'
        Assert-True (Test-Path -LiteralPath $backupPath -PathType Leaf) 'Tray Exit did not leave data.json.bak after safe save.'
        $script:window = $null
        Start-Taskronome
        [void](Wait-AppState 'Idle' 10)
        Select-Tab 'TasksTab'
    } -ScreenshotName '18-tray-menu-actions' -SnapshotFiles | Out-Null

    if (-not (Restore-MainWindowViaSingleInstance)) {
        Stop-Taskronome -Force
        Start-Taskronome
    }

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
        $systemPanel = Find-ElementById 'SystemPausePanel'
        Assert-True (-not $systemPanel.Current.IsOffscreen) 'System-pause panel was not visible after restart.'
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
        Assert-True (Get-ButtonEnabled 'PauseResumeButton') 'Pause/resume was not enabled after lock recovery.'
        Invoke-ButtonById 'PauseResumeButton' | Out-Null
        [void](Wait-AppState 'AwaitingConfirmation' 5)
        Stop-RotationViaUi
    } -ScreenshotName '20-lock-recovery' -SnapshotFiles | Out-Null

    $sleepCapability = @(powercfg /a 2>&1 | ForEach-Object { [string]$_ })
    $sleepAvailable = $sleepCapability -match 'Standby|待机|睡眠|休眠|Low Power Idle|Modern Standby|S3|S0'
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
        $originalRect = $script:window.Current.BoundingRectangle
        $minimumResult = [TaskronomeAcceptanceNative]::SetWindowPos(
            $handle,
            [IntPtr]::Zero,
            [int]$originalRect.Left,
            [int]$originalRect.Top,
            760,
            560,
            0x0004 -bor 0x0010)
        Assert-True $minimumResult 'Unable to place the window at its declared minimum size.'
        try {
            Start-Sleep -Milliseconds 500
            $minimumRect = $script:window.Current.BoundingRectangle
            Assert-True ($minimumRect.Width -ge 750 -and $minimumRect.Height -ge 550) 'The minimum-size window was smaller than the declared bounds.'
            Assert-CoreLayout
        }
        finally {
            [void][TaskronomeAcceptanceNative]::SetWindowPos(
                $handle,
                [IntPtr]::Zero,
                [int]$originalRect.Left,
                [int]$originalRect.Top,
                [int]$originalRect.Width,
                [int]$originalRect.Height,
                0x0004 -bor 0x0010)
            Start-Sleep -Milliseconds 300
        }
    } -ScreenshotName '25-current-dpi-layout' -SnapshotFiles | Out-Null

    $singleMonitorEnvironment = Get-EnvironmentSnapshot
    if ($singleMonitorEnvironment.MonitorCount -gt 1) {
        Invoke-Recorded -TestId 'single-monitor-offscreen-clamp' -Category 'DPI/Displays' -Expected 'If there is one monitor, stored off-screen placement is clamped back into the visible work area.' -Action { throw 'A second monitor is present; this single-monitor branch is not applicable.' } -NaReason "N/A: display enumeration found $($singleMonitorEnvironment.MonitorCount) monitor(s), so a one-monitor-only placement test is not applicable." | Out-Null
    }
    else {
        Invoke-Recorded -TestId 'single-monitor-offscreen-clamp' -Category 'DPI/Displays' -Expected 'If there is one monitor, stored off-screen placement is clamped back into the visible work area.' -Action {
            $screens = [System.Windows.Forms.Screen]::AllScreens
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
    }

    $environment = Get-EnvironmentSnapshot
    if ($environment.MonitorCount -lt 2) {
        Invoke-Recorded -TestId 'second-monitor' -Category 'DPI/Displays' -Expected 'A second monitor is enumerated when present.' -Action { throw 'No second monitor is present on this machine.' } -NaReason "N/A: monitor enumeration found $($environment.MonitorCount) monitor(s); no second display is available." | Out-Null
    }
    else {
        Invoke-Recorded -TestId 'second-monitor' -Category 'DPI/Displays' -Expected 'Move, maximize, restore, unplug/disable, and recover the window on the second monitor.' -Action {
            $screensBefore = [System.Windows.Forms.Screen]::AllScreens
            $second = @($screensBefore | Where-Object { -not $_.Primary }) | Select-Object -First 1
            Assert-True ($null -ne $second) 'The second monitor disappeared before the multi-monitor test began.'
            $handle = [IntPtr]$script:window.Current.NativeWindowHandle
            $moveResult = [TaskronomeAcceptanceNative]::SetWindowPos(
                $handle,
                [IntPtr]::Zero,
                $second.WorkingArea.Left + 40,
                $second.WorkingArea.Top + 40,
                920,
                640,
                0x0004 -bor 0x0010)
            Assert-True $moveResult 'SetWindowPos failed for the second monitor.'
            Start-Sleep -Milliseconds 500
            $windowPattern = [System.Windows.Automation.WindowPattern]$script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
            $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized)
            Start-Sleep -Milliseconds 700
            Assert-Equal ([System.Windows.Automation.WindowVisualState]::Maximized.ToString()) $windowPattern.Current.WindowVisualState.ToString() 'The window did not maximize on the second monitor.'
            Assert-CoreLayout
            $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
            Start-Sleep -Milliseconds 700
            Assert-Equal ([System.Windows.Automation.WindowVisualState]::Normal.ToString()) $windowPattern.Current.WindowVisualState.ToString() 'The window did not restore on the second monitor.'
            $normalRect = $script:window.Current.BoundingRectangle
            Assert-True ($normalRect.Left -lt $second.WorkingArea.Right -and $normalRect.Right -gt $second.WorkingArea.Left -and $normalRect.Top -lt $second.WorkingArea.Bottom -and $normalRect.Bottom -gt $second.WorkingArea.Top) 'The restored window was not on the second monitor.'

            if (-not $OperatorAssistance) {
                throw 'A second monitor is present; disable/unplug it with -OperatorAssistance to complete recovery verification.'
            }

            Read-Host '请临时禁用或拔下第二显示器，等待 Windows 完成显示器重新枚举后按回车继续' | Out-Null
            $afterDisableDeadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $screensAfterDisable = [System.Windows.Forms.Screen]::AllScreens
                if ($screensAfterDisable.Count -lt $screensBefore.Count) {
                    break
                }

                Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $afterDisableDeadline)
            Assert-True ($screensAfterDisable.Count -lt $screensBefore.Count) 'The second monitor was not removed from Windows display enumeration.'
            $recoveredRect = $script:window.Current.BoundingRectangle
            $visibleOnRemainingScreen = @($screensAfterDisable | Where-Object {
                    $recoveredRect.Left -lt $_.WorkingArea.Right -and
                    $recoveredRect.Right -gt $_.WorkingArea.Left -and
                    $recoveredRect.Top -lt $_.WorkingArea.Bottom -and
                    $recoveredRect.Bottom -gt $_.WorkingArea.Top
                }).Count -gt 0
            Assert-True $visibleOnRemainingScreen 'The window was left outside every remaining monitor work area.'

            Read-Host '请重新接回或启用第二显示器，等待 Windows 恢复显示器后按回车继续' | Out-Null
            $restoreDeadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $screensAfterRestore = [System.Windows.Forms.Screen]::AllScreens
                if ($screensAfterRestore.Count -ge $screensBefore.Count) {
                    break
                }

                Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $restoreDeadline)
            Assert-True ($screensAfterRestore.Count -ge $screensBefore.Count) 'The second monitor was not restored before the display test ended.'
            $primary = @($screensAfterRestore | Where-Object Primary) | Select-Object -First 1
            [void][TaskronomeAcceptanceNative]::SetWindowPos(
                $handle,
                [IntPtr]::Zero,
                $primary.WorkingArea.Left + 40,
                $primary.WorkingArea.Top + 40,
                920,
                640,
                0x0004 -bor 0x0010)
            Start-Sleep -Milliseconds 500
            Assert-CoreLayout
        } -ScreenshotName '27-second-monitor-recovery' -SnapshotFiles | Out-Null
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

    $originalScale = (Get-EnvironmentSnapshot).CurrentScalePercent
    $dpiScaleTargets = @(100, 125, 150, 200)
    foreach ($scaleTarget in $dpiScaleTargets) {
        if (-not $OperatorAssistance) {
            Invoke-Recorded -TestId "dpi-scale-$scaleTarget" -Category 'DPI/Layout' -Expected "Read the layout after setting Windows display scaling to $scaleTarget%." -Action {
                throw "Windows display scaling $scaleTarget% requires one operator action; rerun with -OperatorAssistance."
            } -ScreenshotName "29-dpi-$scaleTarget" -SnapshotFiles | Out-Null
            continue
        }

        $scaleAnswer = Read-Host "请在 Windows 显示设置将主显示缩放设为 $scaleTarget%，回到 Taskronome 后按回车；若该比例不在设置中请输入 unavailable"
        if ($scaleAnswer -match '^\s*unavailable\b') {
            $scaleEvidence = Get-EnvironmentSnapshot
            Invoke-Recorded -TestId "dpi-scale-$scaleTarget" -Category 'DPI/Layout' -Expected "Read the layout after setting Windows display scaling to $scaleTarget%." -Action { throw "Windows display settings did not offer $scaleTarget%." } -NaReason "N/A: operator reported that Windows did not offer $scaleTarget%; display capability evidence recorded with current monitor layout and scale $($scaleEvidence.CurrentScalePercent)%." -SnapshotFiles | Out-Null
            continue
        }

        Invoke-Recorded -TestId "dpi-scale-$scaleTarget" -Category 'DPI/Layout' -Expected "Read the layout after setting Windows display scaling to $scaleTarget%." -Action {
            Start-Sleep -Seconds 2
            $scaleEvidence = Get-EnvironmentSnapshot
            Assert-Equal $scaleTarget $scaleEvidence.CurrentScalePercent "The active window did not report the requested $scaleTarget% scale."
            Assert-CoreLayout
            return "scale=$($scaleEvidence.CurrentScalePercent); dpi=$($scaleEvidence.CurrentDpiForWindow)"
        } -ScreenshotName "29-dpi-$scaleTarget" -SnapshotFiles | Out-Null
    }

    if ($OperatorAssistance) {
        $restoreScaleAnswer = Read-Host "请将主显示缩放恢复为原始 $originalScale%，回到 Taskronome 后按回车"
        if ($restoreScaleAnswer -match '^\s*unavailable\b') {
            Invoke-Recorded -TestId 'dpi-scale-restored' -Category 'DPI/Layout' -Expected "Restore the original Windows display scale of $originalScale%." -Action { throw 'The original display scale was not restored.' } -NaReason 'N/A: the operator reported that the original display scale was unavailable; the current display capability is retained in the environment snapshot.' -SnapshotFiles | Out-Null
        }
        else {
            Invoke-Recorded -TestId 'dpi-scale-restored' -Category 'DPI/Layout' -Expected "Restore the original Windows display scale of $originalScale%." -Action {
                Start-Sleep -Seconds 2
                $restoredScale = Get-EnvironmentSnapshot
                Assert-Equal $originalScale $restoredScale.CurrentScalePercent 'The original display scale was not restored.'
                Assert-CoreLayout
                return "restored-$($restoredScale.CurrentScalePercent)-percent"
            } -ScreenshotName '33-dpi-restored' -SnapshotFiles | Out-Null
        }
    }
    else {
        Invoke-Recorded -TestId 'dpi-scale-restored' -Category 'DPI/Layout' -Expected "Restore the original Windows display scale of $originalScale%." -Action { throw 'DPI restoration requires the same operator session that changed the scale.' } -ScreenshotName '33-dpi-restored' -SnapshotFiles | Out-Null
    }

    $originalHighContrast = (Get-EnvironmentSnapshot).HighContrast
    Invoke-Recorded -TestId 'high-contrast' -Category 'Accessibility' -Expected 'High contrast mode preserves core control readability and is restored afterward.' -Action {
        if (-not $OperatorAssistance) {
            throw 'High contrast toggle requires one operator action; rerun with -OperatorAssistance.'
        }

        if (-not $originalHighContrast) {
            Start-Process 'ms-settings:easeofaccess-highcontrast' | Out-Null
            Read-Host '请在 Windows 高对比度设置中打开高对比度，确认 Taskronome 核心按钮、倒计时、状态文字和确认区域可辨认后按回车' | Out-Null
            $enabledContrast = Get-EnvironmentSnapshot
            Assert-True $enabledContrast.HighContrast 'Windows high contrast was not enabled for the acceptance check.'
            Assert-CoreLayout
            Read-Host '请将 Windows 高对比度恢复为原始关闭状态，回到 Taskronome 后按回车' | Out-Null
        }
        else {
            Assert-CoreLayout
            Read-Host '高对比度原本已开启；请确认 Taskronome 核心按钮、倒计时、状态文字和确认区域可辨认后按回车' | Out-Null
        }

        $restoredContrast = Get-EnvironmentSnapshot
        Assert-Equal ([bool]$originalHighContrast) ([bool]$restoredContrast.HighContrast) 'High contrast was not restored to its original state.'
        return "original=$originalHighContrast; restored=$($restoredContrast.HighContrast)"
    } -ScreenshotName '34-accessibility-high-contrast' -SnapshotFiles | Out-Null

    return $environment
}

function Write-Reports {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$StartedAtUtc)

    $endedAtUtc = [DateTimeOffset]::UtcNow
    $script:networkAfter = @()
    if ($null -ne $script:process) {
        try {
            $script:process.Refresh()
            if (-not $script:process.HasExited) {
                $script:networkAfter = @(Get-NetworkSnapshot $script:process.Id)
            }
        }
        catch {
            $script:networkAfter = @()
        }
    }

    try {
        $environment = Get-EnvironmentSnapshot
    }
    catch {
        $environment = [pscustomobject][ordered]@{
            Tester = 'unavailable'
            Windows = [pscustomobject][ordered]@{ Caption = 'unavailable'; Build = 'unavailable'; Architecture = 'unavailable' }
            CpuArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
            DotnetSdk = 'unavailable'
            MonitorCount = 0
            Monitors = @()
            CurrentDpiForWindow = $null
            CurrentScalePercent = $null
            HighContrast = $null
            Notification = [pscustomobject][ordered]@{ Setting = 'Unavailable'; GetAllAsync = 'Unavailable'; Assembly = ''; Error = $_.Exception.Message }
            PowerCapabilities = @()
            SessionName = 'unavailable'
            SessionType = 'unknown'
            ClientNamePresent = $false
            UserInteractive = [Environment]::UserInteractive
            ComputerSystem = [pscustomobject][ordered]@{ Model = 'unavailable'; SystemType = 'unavailable' }
        }
    }
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
        $expectedText = if ($null -eq $test.Expected) { '' } else { [string]$test.Expected }
        $actualText = if ($null -eq $test.Actual) { '' } else { [string]$test.Actual }
        $expected = $expectedText.Replace('|', '\|')
        $actual = $actualText.Replace('|', '\|')
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

    Stop-Taskronome -Force
    try {
        $report = Write-Reports $startedAtUtc
    }
    catch {
        $exitCode = 1
        Write-Error ("Write-Reports failed: " + ($_ | Format-List * -Force | Out-String))
        $report = $null
    }
    if ($null -ne $report) {
        $archive = Write-ChecksumsAndArchive
        Write-Host "Acceptance root: $script:root"
        Write-Host "JSON: $($report.JsonPath)"
        Write-Host "Markdown: $($report.MarkdownPath)"
        Write-Host "Evidence ZIP: $($archive.ArchivePath)"
        Write-Host "Evidence ZIP SHA-256: $($archive.ArchiveSha256)"
    }

    $failCount = @($script:results | Where-Object Result -eq 'Fail').Count
    if ($failCount -gt 0) {
        $exitCode = 1
    }
}

exit $exitCode
