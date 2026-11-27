using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Respool.Windows;

/// <summary>A system-wide shortcut, registered with <c>RegisterHotKey</c> on a hidden message window.</summary>
public sealed class HotKey : IDisposable
{
    public const uint Alt = 0x0001;
    public const uint Control = 0x0002;
    public const uint Shift = 0x0004;
    private const uint NoRepeat = 0x4000;
    private const int WmHotKey = 0x0312;
    private const int Identifier = 0x5250;

    private readonly HwndSource _window;
    private readonly Action _action;

    public bool IsRegistered { get; }

    public HotKey(uint modifiers, uint key, Action action)
    {
        _action = action;
        _window = new HwndSource(new HwndSourceParameters("Respool.HotKey") { Width = 0, Height = 0, WindowStyle = 0 });
        _window.AddHook(Hook);
        IsRegistered = RegisterHotKey(_window.Handle, Identifier, modifiers | NoRepeat, key);
    }

    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmHotKey && wParam.ToInt32() == Identifier)
        {
            _action();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (IsRegistered) UnregisterHotKey(_window.Handle, Identifier);
        _window.RemoveHook(Hook);
        _window.Dispose();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
