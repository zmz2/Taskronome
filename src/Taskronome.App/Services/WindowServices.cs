using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Taskronome.Core;

namespace Taskronome.App.Services;

internal static partial class NativeMethods
{
    internal const int WmPowerBroadcast = 0x0218;
    internal const int WmWtsSessionChange = 0x02B1;
    internal const int PbtApmSuspend = 0x0004;
    internal const int PbtApmResumeAutomatic = 0x0012;
    internal const int WtsSessionRemoteDisconnect = 0x4;
    internal const int WtsSessionLock = 0x7;
    internal const int WtsSessionUnlock = 0x8;
    internal const int NotifyForThisSession = 0;

    [LibraryImport("Wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool WTSRegisterSessionNotification(nint hWnd, int dwFlags);

    [LibraryImport("Wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool WTSUnRegisterSessionNotification(nint hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(nint hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool FlashWindowEx(ref FlashWindowInfo info);

    [StructLayout(LayoutKind.Sequential)]
    internal struct FlashWindowInfo
    {
        internal uint Size;
        internal nint Hwnd;
        internal uint Flags;
        internal uint Count;
        internal uint Timeout;
    }
}

public static class WindowActivationService
{
    private const uint FlashAll = 0x00000003;
    private const uint FlashTimerNoForeground = 0x0000000C;

    public static void BringToFront(Window window, IInputElement? focusTarget = null)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (!window.Dispatcher.CheckAccess())
        {
            window.Dispatcher.Invoke(() => BringToFront(window, focusTarget));
            return;
        }

        if (!window.IsVisible)
        {
            window.Show();
        }

        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }

        window.Activate();
        var handle = new WindowInteropHelper(window).Handle;
        if (handle != nint.Zero)
        {
            _ = NativeMethods.SetForegroundWindow(handle);
        }

        focusTarget?.Focus();
    }

    public static void FlashTaskbar(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == nint.Zero)
        {
            return;
        }

        var info = new NativeMethods.FlashWindowInfo
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.FlashWindowInfo>(),
            Hwnd = handle,
            Flags = FlashAll | FlashTimerNoForeground,
            Count = 5,
            Timeout = 0,
        };
        _ = NativeMethods.FlashWindowEx(ref info);
    }
}

public static class WindowPlacementService
{
    public const double MinimumWidth = 400;
    public const double MinimumHeight = 300;

    private const double MinimumVisibleWidth = 160;
    private const double MinimumVisibleHeight = 80;

    public static void Apply(Window window, WindowPlacementData placement)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(placement);

        var width = IsFinitePositive(placement.Width) ? Math.Max(MinimumWidth, placement.Width) : 1040;
        var height = IsFinitePositive(placement.Height) ? Math.Max(MinimumHeight, placement.Height) : 720;
        window.Width = Math.Min(width, Math.Max(MinimumWidth, SystemParameters.VirtualScreenWidth));
        window.Height = Math.Min(height, Math.Max(MinimumHeight, SystemParameters.VirtualScreenHeight));

        if (double.IsFinite(placement.Left) && double.IsFinite(placement.Top))
        {
            window.Left = placement.Left;
            window.Top = placement.Top;
            ClampToVisibleVirtualDesktop(window);
        }
        else
        {
            window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }

        if (placement.IsMaximized)
        {
            window.WindowState = WindowState.Maximized;
        }
    }

    public static WindowPlacementData Capture(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        var bounds = window.RestoreBounds;
        return new WindowPlacementData
        {
            Left = bounds.Left,
            Top = bounds.Top,
            Width = bounds.Width,
            Height = bounds.Height,
            IsMaximized = window.WindowState == WindowState.Maximized,
        };
    }

    private static void ClampToVisibleVirtualDesktop(Window window)
    {
        var virtualLeft = SystemParameters.VirtualScreenLeft;
        var virtualTop = SystemParameters.VirtualScreenTop;
        var virtualRight = virtualLeft + SystemParameters.VirtualScreenWidth;
        var virtualBottom = virtualTop + SystemParameters.VirtualScreenHeight;

        if (window.Left + MinimumVisibleWidth > virtualRight)
        {
            window.Left = virtualRight - MinimumVisibleWidth;
        }

        if (window.Top + MinimumVisibleHeight > virtualBottom)
        {
            window.Top = virtualBottom - MinimumVisibleHeight;
        }

        if (window.Left + window.Width - MinimumVisibleWidth < virtualLeft)
        {
            window.Left = virtualLeft - window.Width + MinimumVisibleWidth;
        }

        if (window.Top < virtualTop)
        {
            window.Top = virtualTop;
        }
    }

    private static bool IsFinitePositive(double value) => double.IsFinite(value) && value > 0;
}

public sealed class WindowsSessionMonitor : IDisposable
{
    private readonly Window _window;
    private readonly Action<SystemPauseReason> _pauseAction;
    private readonly Action _resumeSignal;
    private HwndSource? _source;
    private nint _handle;
    private bool _registered;

    public WindowsSessionMonitor(
        Window window,
        Action<SystemPauseReason> pauseAction,
        Action resumeSignal)
    {
        _window = window ?? throw new ArgumentNullException(nameof(window));
        _pauseAction = pauseAction ?? throw new ArgumentNullException(nameof(pauseAction));
        _resumeSignal = resumeSignal ?? throw new ArgumentNullException(nameof(resumeSignal));
    }

    public void Attach()
    {
        _handle = new WindowInteropHelper(_window).Handle;
        if (_handle == nint.Zero)
        {
            return;
        }

        _source = HwndSource.FromHwnd(_handle);
        _source?.AddHook(WndProc);
        _registered = NativeMethods.WTSRegisterSessionNotification(_handle, NativeMethods.NotifyForThisSession);
    }

    private nint WndProc(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == NativeMethods.WmPowerBroadcast)
        {
            var code = wParam.ToInt32();
            if (code == NativeMethods.PbtApmSuspend)
            {
                _pauseAction(SystemPauseReason.Suspend);
            }
            else if (code == NativeMethods.PbtApmResumeAutomatic)
            {
                _resumeSignal();
            }
        }
        else if (message == NativeMethods.WmWtsSessionChange)
        {
            switch (wParam.ToInt32())
            {
                case NativeMethods.WtsSessionLock:
                    _pauseAction(SystemPauseReason.Lock);
                    break;
                case NativeMethods.WtsSessionRemoteDisconnect:
                    _pauseAction(SystemPauseReason.SessionDisconnected);
                    break;
                case NativeMethods.WtsSessionUnlock:
                    _resumeSignal();
                    break;
            }
        }

        return nint.Zero;
    }

    public void Dispose()
    {
        if (_registered && _handle != nint.Zero)
        {
            _ = NativeMethods.WTSUnRegisterSessionNotification(_handle);
        }

        _source?.RemoveHook(WndProc);
        _source = null;
        _registered = false;
        _handle = nint.Zero;
    }
}
