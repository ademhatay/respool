using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Respool.Core;
using Forms = System.Windows.Forms;

namespace Respool.Windows;

/// <summary>
/// The quick switcher: a search field in the middle of the screen that finds a chat or a project
/// and opens it, from anywhere.
/// </summary>
public sealed class SwitcherWindow : Window
{
    private const double SheetWidth = 620;
    private const double SheetHeight = 540;
    private const double ShadowMargin = 18;
    private const int MaxItems = 9;

    private readonly IAppHost _host;
    private TextBox? _field;
    private StackPanel _list = new();
    private ScrollViewer _scroll = new();
    private StackPanel _hints = new();
    private readonly List<Border> _rows = new();
    private IReadOnlyList<Item> _items = Array.Empty<Item>();
    private int _selected;
    private Point? _lastMouse;

    private abstract record Item;
    private sealed record SessionItem(SessionRecord Session) : Item;
    private sealed record ProjectItem(ProjectGroup Project) : Item;

    private enum Mode { Plain, Editor, Terminal }

    public SwitcherWindow(IAppHost host)
    {
        _host = host;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = SheetWidth + ShadowMargin * 2;
        Height = SheetHeight + ShadowMargin * 2;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Title = "Respool";
        Deactivated += (_, _) => Dismiss();
        PreviewKeyDown += OnKey;
    }

    /// <summary>Shows the switcher, or hides it when it is up.</summary>
    public void Toggle()
    {
        if (IsVisible) Dismiss();
        else Present();
    }

    private void Present()
    {
        Build();
        Place();
        Opacity = 0;
        Show();
        Activate();
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero) SetForegroundWindow(handle);
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.12)));
        if (_field is not null)
        {
            _field.Focus();
            Keyboard.Focus(_field);
        }
    }

    private void Dismiss()
    {
        if (!IsVisible) return;
        BeginAnimation(OpacityProperty, null);
        Hide();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Kept for the next time: Alt+F4 only hides it.
        e.Cancel = true;
        Dismiss();
        base.OnClosing(e);
    }

    private void Place()
    {
        var area = WorkAreas.UnderCursor();
        var left = area.Left + (area.Width - SheetWidth) / 2;
        var top = area.Top + area.Height * 0.28;
        if (top + SheetHeight > area.Bottom) top = Math.Max(area.Top, area.Bottom - SheetHeight);
        Left = left - ShadowMargin;
        Top = top - ShadowMargin;
    }

    // MARK: Building

    private void Build()
    {
        var t = Ui.T;
        _lastMouse = null;
        var (fieldView, field) = Ui.Field(L.SwitcherPlaceholder, 20);
        _field = field;
        field.TextChanged += (_, _) => Reload(resetSelection: true);

        var magnifier = Ui.Icon(Theme.Glyph.Search, 18, t.Secondary);
        var search = Ui.Row(new UIElement?[] { magnifier }, fieldView, Array.Empty<UIElement?>(), spacing: 12);
        search.Margin = new Thickness(20, 0, 20, 0);
        search.Height = 60;

        _list = new StackPanel();
        _scroll = new ScrollViewer
        {
            Content = _list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(8),
            Focusable = false,
        };

        _hints = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        var footer = new Border { Height = 36, Padding = new Thickness(16, 0, 16, 0), Child = _hints };

        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        void Put(UIElement element, int row)
        {
            Grid.SetRow(element, row);
            layout.Children.Add(element);
        }
        Put(search, 0);
        Put(Ui.Hairline(), 1);
        Put(_scroll, 2);
        Put(Ui.Hairline(), 3);
        Put(footer, 4);

        Content = Sheets.Make(layout, 16, ShadowMargin);
        Reload(resetSelection: true);
    }

    private void Reload(bool resetSelection)
    {
        var query = _field?.Text ?? "";
        _items = Rank(query);
        if (resetSelection) _selected = 0;
        _selected = _items.Count == 0 ? 0 : Math.Clamp(_selected, 0, _items.Count - 1);

        _list.Children.Clear();
        _rows.Clear();
        _scroll.ScrollToTop();
        if (_items.Count == 0)
        {
            var none = Ui.Label(L.NoResults, 13, Ui.T.Secondary);
            none.HorizontalAlignment = HorizontalAlignment.Center;
            none.Margin = new Thickness(0, 150, 0, 0);
            _list.Children.Add(none);
            PaintHints();
            return;
        }
        if (Fold(query.Trim()).Length == 0)
        {
            var caption = Ui.Label(L.RecentTitle, 11, Ui.T.Secondary, FontWeights.SemiBold);
            caption.Margin = new Thickness(12, 4, 12, 2);
            _list.Children.Add(caption);
        }
        for (var index = 0; index < _items.Count; index++)
        {
            var row = MakeRow(_items[index], index);
            if (_list.Children.Count > 0) row.Margin = new Thickness(0, 2, 0, 0);
            _rows.Add(row);
            _list.Children.Add(row);
        }
        PaintSelection(scroll: false);
    }

    private Border MakeRow(Item item, int index)
    {
        var t = Ui.T;
        Grid content;
        if (item is SessionItem { Session: var session })
        {
            var mark = new Grid { Width = 22, Height = 22, Children = { AppMarks.For(_host.Library.Destination(session), 15 * 1.3) } };
            var texts = Ui.VStack(1,
                Ui.Label(session.Title, 14, t.Text),
                Ui.Label(session.PlaceLabel, 11, t.Secondary));
            texts.VerticalAlignment = VerticalAlignment.Center;
            var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            if (_host.Library.Live.TryGetValue(session.Id, out var live))
            {
                var dot = Ui.LiveMark(live.State, _host.Library.AttentionSet.Contains(session.Id), false);
                dot.Margin = new Thickness(0, 0, 6, 0);
                trailing.Children.Add(dot);
            }
            trailing.Children.Add(Ui.Label(Format.Relative(session.LastActivity), 11, t.Tertiary));
            content = Ui.Row(new UIElement?[] { mark }, texts, new UIElement?[] { trailing }, spacing: 12);
        }
        else
        {
            var project = ((ProjectItem)item).Project;
            var mark = new Grid { Width = 22, Height = 22, Children = { Ui.Icon(Theme.Glyph.Folder, 15, t.Accent) } };
            var texts = Ui.VStack(1,
                Ui.Label(project.Name, 14, t.Text, FontWeights.SemiBold),
                Ui.Label(L.Sessions(project.Sessions.Count), 11, t.Secondary));
            texts.VerticalAlignment = VerticalAlignment.Center;
            var badge = Ui.Capsule(Ui.Label(L.ProjectTag, 10, t.Secondary, FontWeights.Medium), t.Overlay(0.08), 17, 6);
            content = Ui.Row(new UIElement?[] { mark }, texts, new UIElement?[] { badge }, spacing: 12);
        }

        var row = new Border
        {
            Child = content,
            Height = 44,
            Padding = new Thickness(12, 0, 12, 0),
            CornerRadius = new CornerRadius(9),
            Background = Brushes.Transparent,
            Cursor = Cursors.Hand,
        };
        row.MouseMove += (_, e) =>
        {
            // Only a real move selects: a list scrolling under a still pointer does not.
            var position = e.GetPosition(this);
            if (_lastMouse is { } last && last == position) return;
            _lastMouse = position;
            if (_selected == index) return;
            _selected = index;
            PaintSelection(scroll: false);
        };
        var pressed = false;
        row.MouseLeftButtonDown += (_, e) => { pressed = true; e.Handled = true; };
        row.MouseLeftButtonUp += (_, e) =>
        {
            if (!pressed) return;
            pressed = false;
            e.Handled = true;
            Choose(index, Mode.Plain);
        };
        row.MouseLeave += (_, _) => pressed = false;
        return row;
    }

    private void PaintSelection(bool scroll)
    {
        var lit = Ui.T.AccentAt(0.18);
        for (var index = 0; index < _rows.Count; index++) _rows[index].Background = index == _selected ? lit : Brushes.Transparent;
        if (scroll && _selected < _rows.Count) _rows[_selected].BringIntoView();
        PaintHints();
    }

    private void PaintHints()
    {
        _hints.Children.Clear();
        var hints = new List<(string Key, string Label)>();
        if (_selected < _items.Count)
        {
            switch (_items[_selected])
            {
                case ProjectItem:
                    hints.Add(("Enter", L.ProjectPage));
                    hints.Add(("Ctrl+Enter", L.NewChat));
                    break;
                case SessionItem { Session: var session }:
                    hints.Add(("Enter", L.Open));
                    if (EditorFor(session) is { } editor) hints.Add(("Ctrl+Enter", editor.Title()));
                    hints.Add(("Alt+Enter", OpenMethod.Terminal.Title()));
                    break;
            }
        }
        hints.Add(("Esc", L.Close));
        foreach (var (key, label) in hints)
        {
            var hint = Hint(key, label);
            if (_hints.Children.Count > 0) hint.Margin = new Thickness(16, 0, 0, 0);
            _hints.Children.Add(hint);
        }
    }

    private static StackPanel Hint(string key, string label)
    {
        var t = Ui.T;
        var capText = Ui.Label(key, 11, t.Secondary, FontWeights.Medium);
        capText.HorizontalAlignment = HorizontalAlignment.Center;
        var cap = new Border
        {
            Child = capText,
            MinWidth = 20,
            Height = 18,
            Padding = new Thickness(5, 0, 5, 0),
            CornerRadius = new CornerRadius(4),
            Background = t.Overlay(0.09),
            VerticalAlignment = VerticalAlignment.Center,
        };
        return Ui.HStack(5, cap, Ui.Label(label, 11, t.Secondary));
    }

    // MARK: Keys and choosing

    private void OnKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        switch (key)
        {
            case Key.Escape:
                e.Handled = true;
                Dismiss();
                break;
            case Key.Down:
            case Key.Up:
                e.Handled = true;
                if (_items.Count == 0) return;
                _selected = (_selected + (key == Key.Down ? 1 : -1) + _items.Count) % _items.Count;
                PaintSelection(scroll: true);
                break;
            case Key.Enter:
                e.Handled = true;
                var modifiers = Keyboard.Modifiers;
                var mode = modifiers.HasFlag(ModifierKeys.Control) ? Mode.Editor
                    : modifiers.HasFlag(ModifierKeys.Alt) || e.Key == Key.System ? Mode.Terminal
                    : Mode.Plain;
                Choose(_selected, mode);
                break;
        }
    }

    private void Choose(int index, Mode mode)
    {
        if (index < 0 || index >= _items.Count) return;
        switch (_items[index])
        {
            case ProjectItem { Project: var project }:
                if (mode == Mode.Terminal) return;
                Dismiss();
                if (mode == Mode.Editor) _host.StartSession(project);
                else _host.ShowProjectPage(project.Key);
                break;
            case SessionItem { Session: var session }:
                switch (mode)
                {
                    case Mode.Editor:
                        if (EditorFor(session) is not { } editor) return;
                        Dismiss();
                        _host.Open(session, editor);
                        break;
                    case Mode.Terminal:
                        Dismiss();
                        _host.Open(session, OpenMethod.Terminal);
                        break;
                    default:
                        Dismiss();
                        _host.Open(session);
                        break;
                }
                break;
        }
    }

    /// <summary>The project's editor, else the editor the chat ran in, else the first one installed.</summary>
    private OpenMethod? EditorFor(SessionRecord session)
    {
        var library = _host.Library;
        if (library.Current.Project(session.ProjectKey) is { } project && library.OpenMethodFor(project) is var chosen && chosen.IsEditor()) return chosen;
        if (library.OpenMethodFor(session) is var host && host.IsEditor()) return host;
        return Opener.FirstEditor;
    }

    // MARK: Ranking

    private IReadOnlyList<Item> Rank(string text)
    {
        var current = _host.Library.Current;
        var query = Fold(text.Trim());
        var pins = current.Pinned.Select(pin => pin.Session).ToList();
        var listed = current.Sessions.Where(session => !current.Hidden.Contains(session.ProjectKey))
            .OrderByDescending(session => session.LastActivity ?? DateTimeOffset.MinValue);

        if (query.Length == 0)
        {
            return pins.Concat(listed).DistinctBy(session => session.Id).Take(MaxItems)
                .Select(session => (Item)new SessionItem(session)).ToList();
        }

        var projects = current.AllProjects
            .Where(project => !current.Hidden.Contains(project.Key))
            .Select(project => (Project: project, Rank: Match(project.Name, query)))
            .Where(pair => pair.Rank is not null)
            .OrderBy(pair => pair.Rank)
            .ThenByDescending(pair => pair.Project.LastActivity ?? DateTimeOffset.MinValue)
            .Take(3)
            .Select(pair => (Item)new ProjectItem(pair.Project))
            .ToList();

        var sessions = listed.Concat(pins.OrderByDescending(session => session.LastActivity ?? DateTimeOffset.MinValue))
            .DistinctBy(session => session.Id)
            .Select(session =>
            {
                var byTitle = Match(session.Title, query);
                var byProject = Match(session.ProjectName, query) is { } rank ? rank + 3 : (int?)null;
                return (Session: session, Rank: byTitle is null ? byProject : byProject is null ? byTitle : Math.Min(byTitle.Value, byProject.Value));
            })
            .Where(pair => pair.Rank is not null)
            .OrderBy(pair => pair.Rank) // Stable, so recency breaks ties.
            .Take(MaxItems - projects.Count)
            .Select(pair => (Item)new SessionItem(pair.Session));

        return projects.Concat(sessions).ToList();
    }

    /// <summary>0 when the text starts with the query, 1 at the start of a word, 2 inside one; null when absent.</summary>
    private static int? Match(string text, string query)
    {
        var folded = Fold(text);
        int? best = null;
        var at = folded.IndexOf(query, StringComparison.Ordinal);
        while (at >= 0)
        {
            var rank = at == 0 ? 0 : !char.IsLetterOrDigit(folded[at - 1]) ? 1 : 2;
            if (best is null || rank < best) best = rank;
            if (rank == 0 || at + 1 >= folded.Length) break;
            at = folded.IndexOf(query, at + 1, StringComparison.Ordinal);
        }
        return best;
    }

    /// <summary>Lower case without accents, so "Çalışma" matches "calisma".</summary>
    private static string Fold(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark) continue;
            builder.Append(character switch { 'ı' => 'i', 'İ' => 'i', _ => char.ToLowerInvariant(character) });
        }
        return builder.ToString();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr handle);
}

/// <summary>
/// The icon of the app a session opens in: Claude, Windows Terminal (or the Command Prompt),
/// VS Code, Cursor, Zed. A glyph when the program or its icon cannot be found.
/// </summary>
public static class AppMarks
{
    private static readonly Dictionary<OpenMethod, ImageSource?> Cache = new();

    public static FrameworkElement For(OpenMethod method, double size)
    {
        FrameworkElement mark;
        if (Source(method) is { } source)
        {
            var image = new Image { Source = source, Width = size, Height = size, Stretch = Stretch.Uniform, SnapsToDevicePixels = true };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
            mark = image;
        }
        else
        {
            mark = Ui.Icon(method == OpenMethod.Desktop ? Theme.Glyph.Chat : Theme.Glyph.Terminal, Math.Max(8, Math.Round(size * 0.67)), Ui.T.Secondary);
        }
        var box = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        box.Children.Add(mark);
        box.ToolTip = method == OpenMethod.Automatic ? OpenMethod.Terminal.Title() : method.Title();
        return box;
    }

    /// <summary>The app's icon, read once.</summary>
    public static ImageSource? Source(OpenMethod method)
    {
        if (method == OpenMethod.Automatic) method = OpenMethod.Terminal;
        if (Cache.TryGetValue(method, out var known)) return known;
        ImageSource? source = null;
        if (ProgramPath(method) is { } path) source = Extract(path);
        Cache[method] = source;
        return source;
    }

    /// <summary>The program whose icon stands for a way of opening.</summary>
    public static string? ProgramPath(OpenMethod method)
    {
        try
        {
            switch (method)
            {
                case OpenMethod.Desktop:
                    var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    var squirrel = Path.Combine(local, "AnthropicClaude", "claude.exe");
                    if (File.Exists(squirrel)) return squirrel;
                    return InPackage("Claude_", Path.Combine("app", "claude.exe"));
                case OpenMethod.Automatic:
                case OpenMethod.Terminal:
                    if (Opener.HasWindowsTerminal) return InPackage("Microsoft.WindowsTerminal_", "WindowsTerminal.exe");
                    var cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
                    return File.Exists(cmd) ? cmd : null;
                default:
                    if (Opener.EditorPath(method) is not { } editor) return null;
                    if (editor.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return editor;
                    // code.cmd lives in the editor's bin folder, next to which is Code.exe.
                    var name = Path.GetFileNameWithoutExtension(editor) + ".exe";
                    var folder = Path.GetDirectoryName(editor);
                    var parent = folder is null ? null : Path.GetDirectoryName(folder);
                    return new[] { folder, parent }.OfType<string>().Select(dir => Path.Combine(dir, name)).FirstOrDefault(File.Exists);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
        {
            return null;
        }
    }

    /// <summary>A program inside an installed Store package, found through the package's folder in the registry.</summary>
    private static string? InPackage(string prefix, string relative)
    {
        const string packages = @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages";
        using var key = Registry.CurrentUser.OpenSubKey(packages);
        if (key is null) return null;
        foreach (var name in key.GetSubKeyNames().Where(name => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).OrderByDescending(name => name, StringComparer.OrdinalIgnoreCase))
        {
            using var package = key.OpenSubKey(name);
            if (package?.GetValue("PackageRootFolder") is not string root) continue;
            var path = Path.Combine(root, relative);
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private static ImageSource? Extract(string path)
    {
        try
        {
            using var icon = System.Drawing.Icon.ExtractIcon(path, 0, 64) ?? System.Drawing.Icon.ExtractAssociatedIcon(path);
            if (icon is null) return null;
            var source = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or ExternalException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}

/// <summary>Screens' work areas in WPF units, for windows placed by hand.</summary>
public static class WorkAreas
{
    /// <summary>The work area of the screen under the pointer.</summary>
    public static Rect UnderCursor()
    {
        var point = GetCursorPos(out var cursor) ? new System.Drawing.Point(cursor.X, cursor.Y) : Forms.Cursor.Position;
        return Work(Forms.Screen.FromPoint(point));
    }

    /// <summary>The work area of the screen holding a point given in WPF units; the nearest screen when none does.</summary>
    public static Rect Containing(Point point)
    {
        var screens = Forms.Screen.AllScreens;
        foreach (var screen in screens)
        {
            if (Bounds(screen).Contains(point)) return Work(screen);
        }
        var nearest = screens.OrderBy(screen => Distance(Bounds(screen), point)).FirstOrDefault() ?? Forms.Screen.PrimaryScreen;
        return nearest is null ? SystemParameters.WorkArea : Work(nearest);
    }

    private static double Distance(Rect rect, Point point)
    {
        var dx = Math.Max(Math.Max(rect.Left - point.X, 0), point.X - rect.Right);
        var dy = Math.Max(Math.Max(rect.Top - point.Y, 0), point.Y - rect.Bottom);
        return dx * dx + dy * dy;
    }

    private static Rect Work(Forms.Screen screen) => Scaled(screen.WorkingArea, Scale(screen));
    private static Rect Bounds(Forms.Screen screen) => Scaled(screen.Bounds, Scale(screen));

    private static Rect Scaled(System.Drawing.Rectangle rect, double scale) =>
        new(rect.X / scale, rect.Y / scale, rect.Width / scale, rect.Height / scale);

    private static double Scale(Forms.Screen screen)
    {
        try
        {
            var center = new NativePoint { X = screen.Bounds.X + screen.Bounds.Width / 2, Y = screen.Bounds.Y + screen.Bounds.Height / 2 };
            var monitor = MonitorFromPoint(center, 2 /* MONITOR_DEFAULTTONEAREST */);
            if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0 /* MDT_EFFECTIVE_DPI */, out var x, out _) == 0 && x > 0) return x / 96.0;
        }
        catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException) { }
        return 1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
}

/// <summary>The rounded, shadowed sheet the floating windows are drawn on.</summary>
internal static class Sheets
{
    public static Grid Make(UIElement content, double radius, double margin, double? width = null)
    {
        var t = Ui.T;
        // The shadow is cast by a plain shape behind the content, so the text is not rendered through an effect.
        var shadow = new Border
        {
            Background = t.Background,
            CornerRadius = new CornerRadius(radius),
            Effect = new DropShadowEffect { BlurRadius = margin, ShadowDepth = 3, Direction = 270, Color = Colors.Black, Opacity = t.Dark ? 0.5 : 0.2 },
        };
        var sheet = new Border
        {
            Background = t.Background,
            BorderBrush = t.Overlay(0.12),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(radius),
            Child = content,
            ClipToBounds = false,
        };
        var grid = new Grid { Margin = new Thickness(margin) };
        if (width is { } fixedWidth) grid.Width = fixedWidth;
        grid.Children.Add(shadow);
        grid.Children.Add(sheet);
        return grid;
    }
}
