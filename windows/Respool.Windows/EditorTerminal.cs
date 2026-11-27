using System;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Respool.Core;

namespace Respool.Windows;

/// <summary>
/// Runs a command in an editor's own terminal, as the macOS app does: once the editor is in
/// front, its command palette opens a new terminal and the command is pasted into it. The
/// clipboard is borrowed for a few seconds and given back. Windows needs no permission for the
/// key presses, only that the editor's window is the one in front.
/// </summary>
public static class EditorTerminal
{
    private const byte Control = 0x11;
    private const byte Shift = 0x10;
    private const byte Menu = 0x12;
    private const byte KeyP = 0x50;
    private const byte KeyV = 0x56;
    private const byte Return = 0x0D;
    private const uint KeyUp = 0x0002;

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    /// <summary>The palette command that opens a new terminal, or null for an editor that has none.</summary>
    private static string? PaletteCommand(OpenMethod editor) => editor switch
    {
        OpenMethod.VsCode or OpenMethod.Cursor => "Terminal: Create New Terminal",
        OpenMethod.Zed => "workspace: new terminal",
        _ => null,
    };

    private static string ProcessName(OpenMethod editor) => editor switch
    {
        OpenMethod.Cursor => "cursor",
        OpenMethod.Zed => "zed",
        _ => "code",
    };

    /// <summary>Starts the work in the background; <paramref name="fallback"/> runs on the UI thread if it could not.</summary>
    public static void Run(OpenMethod editor, string command, Action fallback, Dispatcher dispatcher)
    {
        if (PaletteCommand(editor) is not { } palette)
        {
            fallback();
            return;
        }
        Task.Run(() =>
        {
            bool done;
            try { done = Type(editor, palette, command, dispatcher); }
            catch (Exception exception) when (exception is InvalidOperationException or ExternalException or TaskCanceledException)
            {
                done = false;
            }
            if (!done) dispatcher.BeginInvoke(fallback);
        });
    }

    private static bool Type(OpenMethod editor, string palette, string command, Dispatcher dispatcher)
    {
        // The editor may take a while to start or to open the folder; ten seconds at most.
        var name = ProcessName(editor);
        var clock = Stopwatch.StartNew();
        var tried = false;
        while (!IsInFront(name))
        {
            if (clock.Elapsed.TotalSeconds > 10) return false;
            if (!tried && clock.Elapsed.TotalSeconds > 3)
            {
                tried = true;
                BringForward(name);
            }
            Thread.Sleep(100);
        }
        // A window that just came up needs a moment before it takes keys.
        Thread.Sleep(clock.Elapsed.TotalSeconds > 0.5 ? 1200 : 400);
        WaitForModifiersUp();

        var saved = dispatcher.Invoke(() => Clipboard.ContainsText() ? Clipboard.GetText() : null);
        try
        {
            Press(Control, Shift, KeyP);
            Thread.Sleep(450);
            Paste(palette, dispatcher);
            Thread.Sleep(350);
            Press(Return);
            Thread.Sleep(1000);
            if (!IsInFront(name)) return false;
            Paste(command, dispatcher);
            Thread.Sleep(200);
            Press(Return);
            Thread.Sleep(300);
        }
        finally
        {
            dispatcher.Invoke(() =>
            {
                try
                {
                    if (saved is not null) Clipboard.SetText(saved);
                    else Clipboard.Clear();
                }
                catch (ExternalException) { }
            });
        }
        return true;
    }

    private static void Paste(string text, Dispatcher dispatcher)
    {
        dispatcher.Invoke(() => Clipboard.SetText(text));
        Press(Control, KeyV);
    }

    /// <summary>Presses keys down in order, then lets them go in reverse, as a hand would.</summary>
    private static void Press(params byte[] keys)
    {
        foreach (var key in keys)
        {
            keybd_event(key, 0, 0, UIntPtr.Zero);
            Thread.Sleep(20);
        }
        foreach (var key in keys.Reverse())
        {
            keybd_event(key, 0, KeyUp, UIntPtr.Zero);
            Thread.Sleep(20);
        }
    }

    /// <summary>A shortcut that opened the chat (Ctrl+Enter) may still be held; its keys would mix with ours.</summary>
    private static void WaitForModifiersUp()
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed.TotalSeconds < 2
               && ((GetAsyncKeyState(Control) & 0x8000) != 0 || (GetAsyncKeyState(Shift) & 0x8000) != 0 || (GetAsyncKeyState(Menu) & 0x8000) != 0))
        {
            Thread.Sleep(50);
        }
    }

    private static bool IsInFront(string name)
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
        return string.Equals(ProcessTree.Name((int)pid), name, StringComparison.OrdinalIgnoreCase);
    }

    private static void BringForward(string name)
    {
        foreach (var process in Process.GetProcessesByName(name).OrderByDescending(Started))
        {
            using (process)
            {
                if (process.MainWindowHandle != IntPtr.Zero && ProcessTree.Activate(process.MainWindowHandle)) return;
            }
        }
    }

    private static DateTime Started(Process process)
    {
        try { return process.StartTime; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { return DateTime.MinValue; }
    }
}
