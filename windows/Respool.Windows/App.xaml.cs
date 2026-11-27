using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Respool.Core;
using Forms = System.Windows.Forms;

namespace Respool.Windows;

/// <summary>
/// Lives in the notification area. The panel, the quick switcher and the shortcuts hang off it;
/// it opens chats where they belong and announces the ones that want you.
/// </summary>
public partial class App : Application, IAppHost
{
    private Mutex? _single;
    private EventWaitHandle? _wake;
    private Forms.NotifyIcon? _tray;
    private readonly Dictionary<ShortcutKind, HotKey> _hotKeys = new();
    private PanelWindow? _panel;
    private SwitcherWindow? _switcher;
    private WelcomeWindow? _welcome;
    private readonly DispatcherTimer _heartbeat = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly DispatcherTimer _trayClock = new() { Interval = TimeSpan.FromSeconds(1) };
    private string? _balloonSession;

    public Library Library { get; private set; } = null!;
    public Theme Theme { get; private set; } = new(false);

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // One copy at a time: a second launch asks the first to show its panel, then leaves.
        _single = new Mutex(true, "Respool.SingleInstance", out var first);
        _wake = new EventWaitHandle(false, EventResetMode.AutoReset, "Respool.ShowPanel");
        if (!first)
        {
            _wake.Set();
            Shutdown();
            return;
        }
        var waiter = new Thread(() =>
        {
            while (_wake.WaitOne()) Dispatcher.BeginInvoke(() => { if (_welcome is null) ShowPanel(); });
        }) { IsBackground = true };
        waiter.Start();

        // A mistake in one view is written down and shown, rather than taking the app down.
        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            try { File.AppendAllText(Path.Combine(Paths.Support, "errors.log"), $"{DateTime.Now:O} {args.Exception}\n\n"); }
            catch (IOException) { }
            _panel?.ShowNotice(args.Exception.Message);
        };

        var settings = Settings.Load();
        L.Choice = settings.Language;
        Opener.UsesTabs = settings.OpensInTabs;
        Theme = Theme.For(settings.Appearance);
        Ui.T = Theme;
        PaintResources();
        try
        {
            Library = new Library(settings, action => Dispatcher.BeginInvoke(action));
        }
        catch (Exception exception) when (exception is Microsoft.Data.Sqlite.SqliteException or IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(L.IndexUnopened(exception.Message), L.LaunchFailed, MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }
        Library.Attention += Announce;
        Library.Changed += PaintTray;
        Library.LiveChanged += PaintTray;

        _panel = new PanelWindow(this);
        _switcher = new SwitcherWindow(this);
        MakeTray();
        foreach (var kind in Enum.GetValues<ShortcutKind>()) Register(kind, Saved(kind));

        _heartbeat.Tick += (_, _) => Library.RecordHeartbeat();
        _heartbeat.Start();
        _trayClock.Tick += (_, _) => PaintTray();
        _trayClock.Start();
        // Watching what runs goes on with the panel closed, for the notifications.
        var live = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        live.Tick += (_, _) => { if (_panel?.IsVisible != true) Library.RefreshLive(); };
        live.Start();
        SystemEvents.PowerModeChanged += (_, args) =>
        {
            if (args.Mode == PowerModes.Suspend) Dispatcher.BeginInvoke(() => Library.StopTimer());
        };

        Library.Refresh();
        _ = ReleaseNotesPage.CheckIfDue(Library);
        if (!settings.DidOnboard) ShowWelcome();
        else ShowPanel();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Library?.Dispose();
        base.OnExit(e);
    }

    // MARK: Tray

    private void MakeTray()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(L.Open, null, (_, _) => ShowPanel());
            menu.Items.Add(L.Refresh, null, (_, _) => Library.Refresh());
            var login = new Forms.ToolStripMenuItem(L.LaunchAtLogin) { Checked = LaunchesAtLogin };
            login.Click += (_, _) => { if (!SetLaunchesAtLogin(!LaunchesAtLogin)) Notice(L.LoginItemFailed); };
            menu.Items.Add(login);
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add(L.Quit, null, (_, _) => Quit());
        };
        menu.Opening += (_, _) => menu.Renderer = new TrayMenuRenderer(Theme);
        menu.ShowImageMargin = false;
        menu.ShowCheckMargin = true;
        menu.Padding = new Forms.Padding(4);
        menu.Font = new System.Drawing.Font("Segoe UI", 9f);
        _tray = new Forms.NotifyIcon { Icon = TrayIcon(), Text = "Respool", Visible = true, ContextMenuStrip = menu };
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) TogglePanel();
        };
        _tray.BalloonTipClicked += (_, _) =>
        {
            if (_balloonSession is { } id && Library.Session(id) is { } session) Open(session);
        };
    }

    /// <summary>The tooltip says what the Mac's menu bar title says: chats that want you, and the timer.</summary>
    private void PaintTray()
    {
        if (_tray is null) return;
        var parts = new List<string> { "Respool" };
        var waiting = Library.NeedsYou.Count;
        if (waiting > 0) parts.Add(waiting.ToString());
        if (Library.Current.RunningTimer is { } timer) parts.Add($"{timer.ProjectName} {Format.ShortClock((DateTimeOffset.Now - timer.Started).TotalSeconds)}");
        var text = string.Join(" · ", parts);
        _tray.Text = text.Length > 63 ? text[..63] : text;
    }

    /// <summary>The app's icon at the notification area's size.</summary>
    private static System.Drawing.Icon TrayIcon()
    {
        using var stream = typeof(App).Assembly.GetManifestResourceStream("Respool.ico");
        if (stream is null) return System.Drawing.SystemIcons.Application;
        return new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
    }

    // MARK: Notifications

    private void Announce(Announcement announcement)
    {
        if (HostIsInFront(announcement.Live)) return;
        var title = announcement.Session?.Title ?? "Claude Code";
        var body = announcement.Live.State == LiveState.Waiting
            ? (announcement.Live.WaitingFor is { Length: > 0 } what ? L.WaitingFor(what) : L.Waiting)
            : L.Finished;
        _balloonSession = announcement.SessionId;
        _tray?.ShowBalloonTip(6000, title, body, Forms.ToolTipIcon.None);
        PaintTray();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);

    /// <summary>No banner while the app the session runs in is in front: the user sees it already.</summary>
    private static bool HostIsInFront(LiveSession live)
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
        var name = ProcessTree.Name((int)pid)?.ToLowerInvariant();
        if (name is null) return false;
        return live.Host switch
        {
            OpenMethod.Desktop => name == "claude",
            OpenMethod.VsCode => name == "code",
            OpenMethod.Cursor => name == "cursor",
            OpenMethod.Zed => name == "zed",
            OpenMethod.Terminal => name is "windowsterminal" or "conhost" or "openconsole",
            _ => false,
        };
    }

    // MARK: IAppHost — panel

    public void ShowPanel() => _panel?.ShowPanel();
    public void HidePanel() => _panel?.HidePanel();
    private void TogglePanel() => _panel?.TogglePanel();
    public void Notice(string text) => _panel?.ShowNotice(text);
    public void ShowProjectPage(string projectKey) => _panel?.OpenProjectPage(projectKey);

    public void ApplyTheme()
    {
        Theme = Theme.For(Library.Settings.Appearance);
        Ui.T = Theme;
        PaintResources();
        _panel?.ApplyTheme();
        _switcher = new SwitcherWindow(this);
    }

    /// <summary>The scroll bars' and drop-downs' colors (App.xaml), from the theme.</summary>
    private void PaintResources()
    {
        var gray = Theme.Dark ? System.Windows.Media.Color.FromRgb(0xC8, 0xC8, 0xCC) : System.Windows.Media.Color.FromRgb(0x60, 0x60, 0x66);
        Resources["Respool.Thumb"] = Theme.Solid(gray, 0.35);
        Resources["Respool.ThumbHover"] = Theme.Solid(gray, 0.6);
        Resources["Respool.Field"] = Theme.Overlay(0.07);
        Resources["Respool.FieldHover"] = Theme.Overlay(0.11);
        Resources["Respool.Text"] = Theme.Text;
        Resources["Respool.Secondary"] = Theme.Secondary;
        Resources["Respool.Menu"] = Theme.Card;
        Resources["Respool.Border"] = Theme.Overlay(0.12);
        Resources["Respool.Selection"] = Theme.Accent;
        Resources["Respool.SelectionText"] = Theme.White;
    }

    public void ShowWelcome()
    {
        _panel?.HidePanel();
        if (_welcome is not null) { _welcome.Activate(); return; }
        _welcome = new WelcomeWindow(this, () =>
        {
            _welcome = null;
            ShowPanel();
        });
        _welcome.Closed += (_, _) => _welcome = null;
        _welcome.Show();
        _welcome.Activate();
    }

    // MARK: IAppHost — opening

    public void Open(SessionRecord session, OpenMethod? method = null)
    {
        Library.Seen(session.Id);
        var chosen = method ?? Library.OpenMethodFor(session);
        if (chosen is OpenMethod.Automatic or OpenMethod.Desktop && Library.IsInOtherOrganization(session.Id))
        {
            if (Library.Settings.OpensOtherAccountsInTerminal) chosen = OpenMethod.Terminal;
            else
            {
                var name = Library.Current.Organizations.FirstOrDefault(organization => organization.Id == session.OrganizationId)?.Name;
                ShowPanel();
                Notice(name is null ? L.InOtherAccount : L.InAccount(name));
                return;
            }
        }
        var outcome = Opener.Open(session, chosen, Library.Live.GetValueOrDefault(session.Id), Library.DesktopId(session.Id));
        if (outcome == OpenOutcome.Failed)
        {
            ShowPanel();
            Notice(L.ChatFailed);
            return;
        }
        _panel?.Dismiss();
    }

    public void OpenInDesktop(SessionRecord session)
    {
        if (Library.Live.TryGetValue(session.Id, out var live) && live.IsInTerminal)
        {
            Notice(L.ChatOpenInTerminal);
            return;
        }
        if (Library.IsInOtherOrganization(session.Id))
        {
            Open(session, Library.Settings.OpensOtherAccountsInTerminal ? OpenMethod.Terminal : OpenMethod.Desktop);
            return;
        }
        if (!Opener.OpenInDesktop(session, Library.DesktopId(session.Id)))
        {
            ShowPanel();
            Notice(L.ChatFailedInClaude);
            return;
        }
        Library.Seen(session.Id);
        _panel?.Dismiss();
    }

    public void StartSession(ProjectGroup project, string? prompt = null, OpenMethod? method = null)
    {
        var folder = project.Folders.FirstOrDefault(Directory.Exists);
        if (folder is null)
        {
            ShowPanel();
            Notice(L.ProjectFolderMissing);
            return;
        }
        if (!Opener.StartSession(folder, prompt, method ?? Library.StartMethod(project.Key)))
        {
            ShowPanel();
            Notice(L.SessionFailed);
            return;
        }
        _panel?.Dismiss();
    }

    // MARK: IAppHost — shortcuts

    private Shortcut? Saved(ShortcutKind kind) => kind switch
    {
        ShortcutKind.Panel => Library.Settings.PanelShortcut,
        ShortcutKind.QuickTask => Library.Settings.TaskShortcut,
        ShortcutKind.QuickNote => Library.Settings.NoteShortcut,
        _ => Library.Settings.SwitcherShortcut,
    };

    private Action Action(ShortcutKind kind) => kind switch
    {
        ShortcutKind.Panel => () => { if (_welcome is null) TogglePanel(); },
        ShortcutKind.QuickTask => () => _panel?.QuickTask(),
        ShortcutKind.QuickNote => () => _panel?.QuickNote(),
        _ => () => _switcher?.Toggle(),
    };

    private bool Register(ShortcutKind kind, Shortcut? shortcut)
    {
        if (_hotKeys.Remove(kind, out var old)) old.Dispose();
        if (shortcut is null) return true;
        var hotKey = new HotKey(shortcut.Modifiers, shortcut.Key, Action(kind));
        if (!hotKey.IsRegistered)
        {
            hotKey.Dispose();
            if (kind == ShortcutKind.Panel) _tray?.ShowBalloonTip(4000, "Respool", L.ShortcutTaken(shortcut.Label), Forms.ToolTipIcon.Info);
            return false;
        }
        _hotKeys[kind] = hotKey;
        return true;
    }

    public string ShortcutLabel(ShortcutKind kind) => _hotKeys.ContainsKey(kind) ? Saved(kind)?.Label ?? "" : "";

    public void SuspendShortcut(ShortcutKind kind)
    {
        if (_hotKeys.Remove(kind, out var old)) old.Dispose();
    }

    public bool SetShortcut(ShortcutKind kind, Shortcut shortcut)
    {
        if (!Register(kind, shortcut))
        {
            Register(kind, Saved(kind));
            return false;
        }
        Library.ChangeSettings(settings =>
        {
            switch (kind)
            {
                case ShortcutKind.Panel: settings.PanelShortcut = shortcut; break;
                case ShortcutKind.QuickTask: settings.TaskShortcut = shortcut; break;
                case ShortcutKind.QuickNote: settings.NoteShortcut = shortcut; break;
                default: settings.SwitcherShortcut = shortcut; break;
            }
        }, reload: false);
        return true;
    }

    public void RestoreShortcut(ShortcutKind kind) => Register(kind, Saved(kind));

    // MARK: IAppHost — the rest

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private static string StartupLink => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Respool.lnk");

    public bool LaunchesAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Respool") is not null || File.Exists(StartupLink);
        }
    }

    public bool SetLaunchesAtLogin(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) key.SetValue("Respool", "\"" + Environment.ProcessPath + "\"");
            else
            {
                key.DeleteValue("Respool", false);
                if (File.Exists(StartupLink)) File.Delete(StartupLink);
            }
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return false;
        }
    }

    public void Relaunch()
    {
        if (Environment.ProcessPath is not { } path) return;
        Quit(() => Process.Start(new ProcessStartInfo("cmd.exe", $"/c timeout /t 1 >nul & start \"\" \"{path}\"") { CreateNoWindow = true, UseShellExecute = false }));
    }

    public void Quit() => Quit(null);

    private void Quit(Action? after)
    {
        foreach (var hotKey in _hotKeys.Values) hotKey.Dispose();
        _hotKeys.Clear();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        Library.RecordHeartbeat();
        _single?.ReleaseMutex();
        after?.Invoke();
        Shutdown();
    }
}
