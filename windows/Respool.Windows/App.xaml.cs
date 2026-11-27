using System;
using System.Threading;
using System.Windows;
using Forms = System.Windows.Forms;

namespace Respool.Windows;

/// <summary>
/// Lives in the notification area. Alt+Shift+Space, or a click on the icon, shows the panel.
/// </summary>
public partial class App : Application
{
    private Mutex? _single;
    private Forms.NotifyIcon? _tray;
    private HotKey? _hotKey;
    private MainWindow? _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // One copy at a time: a second launch just leaves.
        _single = new Mutex(true, "Respool.SingleInstance", out var first);
        if (!first)
        {
            Shutdown();
            return;
        }

        _window = new MainWindow();

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Strings.Open, null, (_, _) => _window.Toggle());
        menu.Items.Add(Strings.Refresh, null, (_, _) => _window.Refresh());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Strings.Quit, null, (_, _) => Quit());
        _tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = "Respool",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) _window.Toggle();
        };

        _hotKey = new HotKey(HotKey.Alt | HotKey.Shift, 0x20 /* space */, () => _window.Toggle());
        if (!_hotKey.IsRegistered)
        {
            _tray.ShowBalloonTip(4000, "Respool", Strings.ShortcutTaken, Forms.ToolTipIcon.Info);
        }

        _window.Refresh();
        _window.Toggle();
    }

    private void Quit()
    {
        _hotKey?.Dispose();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        _single?.ReleaseMutex();
        Shutdown();
    }
}
