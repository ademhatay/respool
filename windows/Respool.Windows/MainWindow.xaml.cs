using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using Respool.Core;

namespace Respool.Windows;

/// <summary>One line of the list.</summary>
public sealed class Row
{
    public required SessionInfo Session { get; init; }
    public required string Title { get; init; }
    public required string Detail { get; init; }
    public required string Time { get; init; }
    public required Brush TitleBrush { get; init; }
    public required Brush DetailBrush { get; init; }
    public Brush LiveBrush { get; init; } = Brushes.Transparent;
    public Visibility LiveVisibility { get; init; } = Visibility.Collapsed;
}

public partial class MainWindow : Window
{
    private readonly SessionStore _store = new();
    private IReadOnlyList<SessionInfo> _sessions = Array.Empty<SessionInfo>();
    private IReadOnlyDictionary<string, LiveSessions.State> _live = new Dictionary<string, LiveSessions.State>();
    private readonly DispatcherTimer _liveTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private bool _loading;
    private bool _unreachable;
    private readonly Palette _palette = Palette.Current();

    public MainWindow()
    {
        InitializeComponent();
        ApplyPalette();
        Placeholder.Text = Strings.Search;
        Status.Text = Strings.Loading;
        _liveTimer.Tick += (_, _) => RefreshLive();
    }

    // MARK: Showing and hiding

    public void Toggle()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        // Full height at the right edge of the screen's working area, above the taskbar.
        var area = SystemParameters.WorkArea;
        Height = area.Height;
        Left = area.Right - Width;
        Top = area.Top;
        Show();
        Activate();
        Query.Focus();
        Query.SelectAll();
        Refresh();
        _liveTimer.Start();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        Hide();
        _liveTimer.Stop();
    }

    // MARK: Loading

    /// <summary>Reads the transcripts in the background; only changed ones are read again.</summary>
    public void Refresh()
    {
        if (_loading) return;
        _loading = true;
        Task.Run(() => (_store.Scan(), LiveSessions.Load())).ContinueWith(task =>
        {
            _loading = false;
            if (!task.IsCompletedSuccessfully) return;
            var (sessions, live) = task.Result;
            // An unreadable folder (an unplugged drive) keeps what was shown before.
            _unreachable = sessions is null;
            if (sessions is not null) _sessions = sessions;
            _live = live;
            ShowRows();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void RefreshLive()
    {
        Task.Run(() => LiveSessions.Load()).ContinueWith(task =>
        {
            if (!task.IsCompletedSuccessfully) return;
            if (task.Result.Count == _live.Count && task.Result.All(pair => _live.TryGetValue(pair.Key, out var state) && state == pair.Value)) return;
            _live = task.Result;
            ShowRows();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void OnQueryChanged(object sender, TextChangedEventArgs e)
    {
        Placeholder.Visibility = Query.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowRows();
    }

    private void ShowRows()
    {
        var selected = (List.SelectedItem as Row)?.Session.Id;
        var matches = SessionSearch.Filter(_sessions, Query.Text).Take(300);
        var rows = matches.Select(session =>
        {
            var hasLive = _live.TryGetValue(session.Id, out var state);
            return new Row
            {
                Session = session,
                Title = session.Title,
                Detail = session.ProjectName,
                Time = RelativeTime.Short(session.LastActivity),
                TitleBrush = _palette.Text,
                DetailBrush = _palette.Secondary,
                LiveVisibility = hasLive ? Visibility.Visible : Visibility.Collapsed,
                LiveBrush = state switch
                {
                    LiveSessions.State.Waiting => Brushes.Orange,
                    LiveSessions.State.Working => _palette.Accent,
                    _ => Brushes.SeaGreen,
                },
            };
        }).ToList();
        List.ItemsSource = rows;
        List.SelectedIndex = Math.Max(0, rows.FindIndex(row => row.Session.Id == selected));

        var projects = _sessions.Select(session => session.ProjectName).Distinct().Count();
        Status.Text = _unreachable ? Strings.FolderMissing
            : _sessions.Count == 0 ? (_loading ? Strings.Loading : Strings.NoChats)
            : rows.Count == 0 ? Strings.NoResults
            : Strings.Status(_sessions.Count, projects);
    }

    // MARK: Keys

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape:
                if (Query.Text.Length > 0) Query.Clear(); else Hide();
                e.Handled = true;
                break;
            case Key.Down:
                Move(1);
                e.Handled = true;
                break;
            case Key.Up:
                Move(-1);
                e.Handled = true;
                break;
            case Key.Enter:
                OpenSelected();
                e.Handled = true;
                break;
        }
    }

    private void Move(int step)
    {
        if (List.Items.Count == 0) return;
        List.SelectedIndex = Math.Clamp(List.SelectedIndex + step, 0, List.Items.Count - 1);
        List.ScrollIntoView(List.SelectedItem);
    }

    private void OnListDoubleClick(object sender, MouseButtonEventArgs e) => OpenSelected();

    // MARK: Opening

    private static bool HasWindowsTerminal =>
        File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "wt.exe"));

    private void OpenSelected()
    {
        if (List.SelectedItem is not Row row) return;
        Run(Launch.Resume(row.Session, HasWindowsTerminal));
    }

    private void Run(LaunchCommand command)
    {
        try
        {
            Process.Start(new ProcessStartInfo(command.FileName, command.Arguments) { UseShellExecute = true });
            Hide();
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Status.Text = Strings.OpenFailed;
        }
    }

    private void OnRowMenuOpened(object sender, RoutedEventArgs e)
    {
        RowMenu.Items.Clear();
        if (List.SelectedItem is not Row row) return;
        var session = row.Session;
        Add(Strings.Open, () => Run(Launch.Resume(session, HasWindowsTerminal)));
        Add(Strings.NewChatHere, () => Run(Launch.NewSession(session.Cwd, HasWindowsTerminal)));
        RowMenu.Items.Add(new Separator());
        Add(Strings.CopyId, () => Clipboard.SetText(session.Id));
        if (Directory.Exists(session.Cwd))
        {
            Add(Strings.ShowFolder, () => Process.Start(new ProcessStartInfo("explorer.exe", Launch.Quote(session.Cwd)) { UseShellExecute = true }));
        }

        void Add(string title, Action action)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => action();
            RowMenu.Items.Add(item);
        }
    }

    // MARK: Colors

    private void ApplyPalette()
    {
        Sheet.Background = _palette.Background;
        Sheet.BorderBrush = _palette.Border;
        SearchBox.Background = _palette.Field;
        Query.Foreground = _palette.Text;
        Query.CaretBrush = _palette.Text;
        Placeholder.Foreground = _palette.Tertiary;
        Footer.BorderBrush = _palette.Border;
        Status.Foreground = _palette.Tertiary;
        ShortcutLabel.Foreground = _palette.Tertiary;
    }
}

/// <summary>The panel's colors, light or dark as the Windows apps setting is.</summary>
public sealed record Palette(Brush Background, Brush Field, Brush Border, Brush Text, Brush Secondary, Brush Tertiary, Brush Accent)
{
    public static Palette Current()
    {
        var light = Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int value
            && value == 1;
        var accent = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        return light
            ? new Palette(Solid(0xF7, 0xF7, 0xF8), Solid(0xEC, 0xEC, 0xEE), Solid(0xDD, 0xDD, 0xE0),
                Solid(0x1D, 0x1D, 0x1F), Solid(0x6E, 0x6E, 0x73), Solid(0x9A, 0x9A, 0x9F), accent)
            : new Palette(Solid(0x24, 0x24, 0x26), Solid(0x2F, 0x2F, 0x32), Solid(0x3A, 0x3A, 0x3D),
                Solid(0xF2, 0xF2, 0xF4), Solid(0xA1, 0xA1, 0xA6), Solid(0x76, 0x76, 0x7B), accent);
    }

    private static SolidColorBrush Solid(byte red, byte green, byte blue)
    {
        var brush = new SolidColorBrush(Color.FromRgb(red, green, blue));
        brush.Freeze();
        return brush;
    }
}
