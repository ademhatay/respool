using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using System.Windows.Threading;
using Respool.Core;

namespace Respool.Windows;

/// <summary>
/// The side panel: a rounded sheet at an edge of the screen with a search field, three tabs
/// (Today, Chats, Time), the sections of each, and a footer. Its content is rebuilt from the
/// library's snapshot whenever something changes, as SwiftUI does on the Mac.
/// </summary>
public sealed partial class PanelWindow : Window
{
    private const double DefaultWidth = 400;
    private const double Inset = 8;

    private readonly IAppHost _host;
    private Library Library => _host.Library;
    private Settings Settings => _host.Library.Settings;
    private Theme T => _host.Theme;

    private readonly Border _sheet = new();
    private readonly Grid _root = new();
    private readonly ContentControl _body = new();
    private readonly StackPanel _list = new();
    private readonly ScrollViewer _scroll = new();
    private readonly TextBox _search;
    private readonly Grid _searchView;
    private readonly TextBlock _status;
    private readonly TextBlock _shortcutLabel;
    private readonly Border _footer;
    private readonly ContentControl _timerBar = new();
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _liveTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly DispatcherTimer _noticeTimer = new() { Interval = TimeSpan.FromSeconds(4) };
    private readonly DispatcherTimer _searchTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private string? _notice;
    private DateTime _hiddenAt = DateTime.MinValue;
    private bool _animating;
    private SettingsPage? _settingsPage;
    private ReleaseNotesPage? _releasePage;
    private readonly DetailCard _card;

    public PanelWindow(IAppHost host)
    {
        _host = host;
        _card = new DetailCard(host);
        Title = "Respool";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.CanResize;
        MinWidth = 320 + 2 * 10;
        MinHeight = 320;
        MaxWidth = 900;
        Width = DefaultWidth + 20;
        FontFamily = Theme.Font;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            ResizeBorderThickness = new Thickness(8),
            GlassFrameThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0),
            UseAeroCaptionButtons = false,
        });

        (_searchView, _search) = Ui.Field(L.SearchPlaceholder, 14);
        _search.TextChanged += (_, _) => QueryChanged();
        _status = Ui.Label("", 11, null);
        _shortcutLabel = Ui.Label("", 11, null);
        _footer = new Border();

        _scroll.Content = _list;
        _scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        _scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        _scroll.Focusable = false;
        _list.Margin = new Thickness(12, 0, 12, 16);

        _sheet.Margin = new Thickness(10);
        _sheet.CornerRadius = new CornerRadius(18);
        _sheet.BorderThickness = new Thickness(1);
        _sheet.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 22, ShadowDepth = 3, Opacity = 0.3 };
        _sheet.Child = _root;
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_body, 0);
        Grid.SetRow(_timerBar, 1);
        Grid.SetRow(_footer, 2);
        _root.Children.Add(_body);
        _root.Children.Add(_timerBar);
        _root.Children.Add(_footer);
        _sheet.RenderTransform = new TranslateTransform();
        Content = _sheet;

        PreviewKeyDown += OnKey;
        Deactivated += (_, _) =>
        {
            if (_animating) return;
            if (Settings.StaysOpen) _card.HideCard();
            else HidePanel();
        };
        LocationChanged += (_, _) => FrameMovedByUser();
        SizeChanged += (_, _) => FrameMovedByUser();

        _clock.Tick += (_, _) => PaintTimerBar();
        _liveTimer.Tick += (_, _) => Library.RefreshLive();
        _noticeTimer.Tick += (_, _) => { _noticeTimer.Stop(); _notice = null; PaintFooter(); };
        _searchTimer.Tick += (_, _) => { _searchTimer.Stop(); RunSearch(); };

        Library.Changed += () => { if (IsVisible) Rebuild(); else PaintFooter(); };
        Library.LiveChanged += () => { if (IsVisible) Rebuild(); };
        Library.Progress += PaintFooter;
        Library.Notice += ShowNotice;

        _tab = Enum.TryParse<PanelTab>(Settings.PanelTab, true, out var tab) ? tab : PanelTab.Chats;
        ApplyTheme();
    }

    public void ApplyTheme()
    {
        Ui.T = T;
        _sheet.Background = T.Background;
        _sheet.BorderBrush = T.Overlay(0.12);
        _search.Foreground = T.Text;
        _search.CaretBrush = T.Text;
        _status.Foreground = T.Tertiary;
        _shortcutLabel.Foreground = T.Tertiary;
        _footer.Child = null;
        _settingsPage = null;
        _releasePage = null;
        if (IsVisible) Rebuild();
    }

    // MARK: Showing and hiding

    public void TogglePanel()
    {
        if (IsVisible && !_animating) HidePanel();
        else if ((DateTime.UtcNow - _hiddenAt).TotalSeconds > 0.25) ShowPanel();
    }

    public void ShowPanel()
    {
        if (IsVisible)
        {
            Activate();
            return;
        }
        PanelDidOpen();
        var frame = PlannedFrame();
        _animating = true;
        _placing = true;
        Left = frame.Left;
        Top = frame.Top;
        Width = frame.Width;
        Height = frame.Height;
        _placing = false;
        var slide = Settings.PanelEdge switch
        {
            "left" => new Vector(-24, 0),
            "top" => new Vector(0, -24),
            "bottom" => new Vector(0, 24),
            "free" => new Vector(0, -10),
            _ => new Vector(24, 0),
        };
        var move = (TranslateTransform)_sheet.RenderTransform;
        Opacity = 0;
        Show();
        Activate();
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        move.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(slide.X, 0, TimeSpan.FromMilliseconds(200)) { EasingFunction = ease });
        move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(slide.Y, 0, TimeSpan.FromMilliseconds(200)) { EasingFunction = ease });
        var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200)) { EasingFunction = ease };
        fade.Completed += (_, _) => _animating = false;
        BeginAnimation(OpacityProperty, fade);
        FocusSearch();
        _liveTimer.Start();
        _clock.Start();
    }

    public void HidePanel()
    {
        if (!IsVisible) return;
        _card.HideCard();
        _liveTimer.Stop();
        _clock.Stop();
        _animating = true;
        var fade = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(140)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn } };
        fade.Completed += (_, _) =>
        {
            Hide();
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
            _animating = false;
            _hiddenAt = DateTime.UtcNow;
        };
        BeginAnimation(OpacityProperty, fade);
    }

    /// <summary>After opening a chat: the panel goes away unless it is kept open.</summary>
    public void Dismiss()
    {
        if (!Settings.StaysOpen) HidePanel();
    }

    private bool _placing;

    /// <summary>The panel's frame at its edge, on the screen under the pointer, outside the 10-unit shadow margin.</summary>
    private Rect PlannedFrame()
    {
        var area = ScreenUnderMouse();
        const double margin = 10;
        var full = area.Height - 2 * Inset;
        var width = DefaultWidth;
        Rect frame;
        switch (Settings.PanelEdge)
        {
            case "left":
                frame = new Rect(area.Left + Inset, area.Top + Inset, width, full);
                break;
            case "top":
            case "bottom":
                var height = Math.Min(full, Math.Max(480, Math.Round(area.Height * 0.66)));
                var top = Settings.PanelEdge == "top" ? area.Top + Inset : area.Bottom - Inset - height;
                frame = new Rect(area.Left + (area.Width - width) / 2, top, width, height);
                break;
            case "free" when ParseFrame(Settings.PanelFrame) is { } saved:
                var screen = ScreenFor(saved) ?? area;
                var w = Math.Clamp(saved.Width, 320, Math.Min(900, screen.Width - 2 * Inset));
                var h = Math.Clamp(saved.Height, 320, screen.Height - 2 * Inset);
                var x = Math.Clamp(saved.Left, screen.Left + Inset, screen.Right - Inset - w);
                var y = Math.Clamp(saved.Top, screen.Top + Inset, screen.Bottom - Inset - h);
                frame = new Rect(x, y, w, h);
                break;
            default:
                frame = new Rect(area.Right - width - Inset, area.Top + Inset, width, full);
                break;
        }
        return new Rect(frame.Left - margin, frame.Top - margin, frame.Width + 2 * margin, frame.Height + 2 * margin);
    }

    private static Rect? ParseFrame(string? text)
    {
        var parts = text?.Split(',');
        if (parts is not { Length: 4 }) return null;
        var values = parts.Select(part => double.TryParse(part, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) ? value : double.NaN).ToArray();
        return values.Any(double.IsNaN) ? null : new Rect(values[0], values[1], values[2], values[3]);
    }

    /// <summary>The work area of the screen under the pointer, in device-independent units.</summary>
    private Rect ScreenUnderMouse()
    {
        var point = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(point);
        return ToUnits(screen.WorkingArea);
    }

    private Rect? ScreenFor(Rect frame)
    {
        foreach (var screen in System.Windows.Forms.Screen.AllScreens)
        {
            var area = ToUnits(screen.WorkingArea);
            if (area.IntersectsWith(frame)) return area;
        }
        return null;
    }

    private Rect ToUnits(System.Drawing.Rectangle pixels)
    {
        var source = PresentationSource.FromVisual(this);
        var scale = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        if (source is null)
        {
            using var graphics = System.Drawing.Graphics.FromHwnd(IntPtr.Zero);
            scale = new Matrix(96.0 / graphics.DpiX, 0, 0, 96.0 / graphics.DpiY, 0, 0);
        }
        var topLeft = scale.Transform(new Point(pixels.Left, pixels.Top));
        var bottomRight = scale.Transform(new Point(pixels.Right, pixels.Bottom));
        return new Rect(topLeft, bottomRight);
    }

    /// <summary>A move or resize by the user keeps that frame and leaves the edge.</summary>
    private void FrameMovedByUser()
    {
        if (_placing || _animating || !IsVisible || !IsLoaded) return;
        _card.HideCard();
        var frame = new Rect(Left + 10, Top + 10, ActualWidth - 20, ActualHeight - 20);
        var text = string.Join(",", new[] { frame.Left, frame.Top, frame.Width, frame.Height }.Select(value => value.ToString("0", System.Globalization.CultureInfo.InvariantCulture)));
        if (Settings.PanelEdge == "free" && Settings.PanelFrame == text) return;
        Settings.PanelEdge = "free";
        Settings.PanelFrame = text;
        Settings.Save();
    }

    /// <summary>Lets an area move the window, as the search bar's margin and the footer do on the Mac.</summary>
    private void DragArea(FrameworkElement element)
    {
        element.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is TextBox || e.ButtonState != MouseButtonState.Pressed) return;
            try { DragMove(); } catch (InvalidOperationException) { }
        };
    }

    private void PanelDidOpen()
    {
        _selection = null;
        _taskLink = null;
        _addingTaskFor = null;
        _renamingProject = null;
        _renamingRow = null;
        _tagEditor = null;
        _showingSettings = false;
        _showingReleaseNotes = false;
        _outline = null;
        _settingsPage?.CancelRecording();
        _selectedDay = Format.Today;
        _calendarAnchor = DateTime.Today;
        _shortcutLabel.Text = _host.ShortcutLabel(ShortcutKind.Panel);
        Library.PanelDidOpen();
        Rebuild();
    }

    public void FocusSearch() => Dispatcher.BeginInvoke(() =>
    {
        _search.Focus();
        Keyboard.Focus(_search);
    }, DispatcherPriority.Input);

    // MARK: Quick task, quick note, project page

    public void QuickTask()
    {
        ShowPanel();
        Dispatcher.BeginInvoke(() =>
        {
            ClearForBrowse();
            _tab = PanelTab.Today;
            SaveTab();
            Library.ChangeSettings(settings => { settings.ShowsTodos = true; settings.CollapsedSections.Remove(PanelSection.Todos); }, reload: false);
            _taskLink = null;
            _focusRequest = "todo";
            Rebuild();
            _scroll.ScrollToTop();
        }, DispatcherPriority.Background);
    }

    public void QuickNote()
    {
        ShowPanel();
        Dispatcher.BeginInvoke(() =>
        {
            ClearForBrowse();
            _tab = PanelTab.Today;
            SaveTab();
            Library.ChangeSettings(settings => { settings.HiddenSections.Remove(PanelSection.Notes); settings.CollapsedSections.Remove(PanelSection.Notes); }, reload: false);
            _focusRequest = "note";
            Rebuild();
        }, DispatcherPriority.Background);
    }

    public void OpenProjectPage(string key)
    {
        ShowPanel();
        _card.HideCard();
        _showingSettings = false;
        _outline = null;
        _projectPage = key;
        _selection = null;
        Rebuild();
        _scroll.ScrollToTop();
    }

    private void ClearForBrowse()
    {
        _search.Text = "";
        if (Library.TagFilter is not null) Library.SetTagFilter(null);
        _showingSettings = false;
        _showingReleaseNotes = false;
        _outline = null;
        _projectPage = null;
    }

    // MARK: Notices and the footer

    public void ShowNotice(string text)
    {
        _notice = text;
        _noticeTimer.Stop();
        _noticeTimer.Start();
        PaintFooter();
    }

    private void PaintFooter()
    {
        string text;
        if (_notice is not null) text = _notice;
        else if (Library.Indexing is { } progress) text = L.IndexingProgress(progress.Done, progress.Total);
        else if (Library.Unreachable && !Library.HasLoaded) text = L.NoChats;
        else
        {
            var shown = Library.Current.Projects.Count;
            var total = Library.Current.AllProjects.Count;
            text = L.StatusLine(Library.SessionCount, shown, total);
        }
        _status.Text = text;
        if (_footer.Child is not null) return;
        if (_status.Parent is Panel oldStatus) oldStatus.Children.Remove(_status);
        if (_shortcutLabel.Parent is Panel oldLabel) oldLabel.Children.Remove(_shortcutLabel);
        _status.Margin = new Thickness(0);
        _shortcutLabel.Margin = new Thickness(0);
        var row = Ui.Row(new UIElement[] { _status }, null, new UIElement[] { _shortcutLabel });
        _footer.Child = Ui.VStack(0, Ui.Hairline(), new Border { Child = row, Padding = new Thickness(18, 0, 18, 0), Height = 30, Background = Brushes.Transparent });
        DragArea(_footer);
    }

    private void PaintTimerBar()
    {
        if (Library.Current.RunningTimer is not { } timer)
        {
            _timerBar.Content = null;
            return;
        }
        var elapsed = (DateTimeOffset.Now - timer.Started).TotalSeconds;
        var row = Ui.Row(
            new UIElement[] { Ui.Dot(7, T.Accent), Ui.Label(timer.ProjectName, 12, T.Text, FontWeights.Medium) },
            null,
            new UIElement[]
            {
                Ui.Label(Format.Clock(elapsed), 12, T.Secondary),
                new Border
                {
                    Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = T.Overlay(0.09),
                    Child = Ui.IconButton(Theme.Glyph.Stop, () => Library.StopTimer(), L.StopTimer, 8, T.Secondary, 20, 20),
                },
            });
        _timerBar.Content = Ui.VStack(0, Ui.Hairline(), new Border { Child = row, Padding = new Thickness(18, 0, 14, 0), Height = 34 });
    }

    // MARK: Keys

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (_settingsPage is { IsRecording: true } recording && _showingSettings)
        {
            if (recording.HandleKey(e)) { e.Handled = true; return; }
        }
        var control = Keyboard.Modifiers == ModifierKeys.Control;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (control)
        {
            switch (key)
            {
                case Key.Enter:
                    ShowOutlineOfSelection();
                    e.Handled = true;
                    return;
                case Key.OemComma:
                    ShowSettings();
                    e.Handled = true;
                    return;
                case Key.P:
                    if (SelectedSession() is { } selected) Library.TogglePin(selected.Id);
                    e.Handled = true;
                    return;
                case >= Key.D1 and <= Key.D9 when _results is null:
                    var index = key - Key.D1;
                    if (index < Library.Current.Pinned.Count) Open(Library.Current.Pinned[index].Session);
                    e.Handled = true;
                    return;
            }
        }
        if (key == Key.Escape)
        {
            e.Handled = true;
            if (HandleEscape()) HidePanel();
            return;
        }
        var inSearch = ReferenceEquals(Keyboard.FocusedElement, _search) || Keyboard.FocusedElement is not TextBox;
        if (!inSearch) return;
        switch (key)
        {
            case Key.Down:
                MoveSelection(1);
                e.Handled = true;
                break;
            case Key.Up:
                MoveSelection(-1);
                e.Handled = true;
                break;
            case Key.Enter when ReferenceEquals(Keyboard.FocusedElement, _search):
                if (SelectedSession() is { } session) Open(session);
                e.Handled = true;
                break;
        }
    }

    /// <summary>Esc undoes the innermost thing first; true when there is nothing left and the panel can close.</summary>
    private bool HandleEscape()
    {
        if (_renamingRow is not null) { _renamingRow = null; Rebuild(); FocusSearch(); return false; }
        if (_renamingProject is not null) { _renamingProject = null; Rebuild(); FocusSearch(); return false; }
        if (_tagEditor is not null) { _tagEditor = null; Rebuild(); FocusSearch(); return false; }
        if (_showingReleaseNotes) { _showingReleaseNotes = false; Rebuild(); return false; }
        if (_projectPage is not null && _outline is null) { _projectPage = null; Rebuild(); FocusSearch(); return false; }
        if (_showingSettings || _outline is not null)
        {
            _settingsPage?.CancelRecording();
            _showingSettings = false;
            _outline = null;
            Rebuild();
            FocusSearch();
            return false;
        }
        if (_addingTaskFor is not null) { _addingTaskFor = null; Rebuild(); FocusSearch(); return false; }
        if (_taskLink is not null) { _taskLink = null; Rebuild(); FocusSearch(); return false; }
        if (!ReferenceEquals(Keyboard.FocusedElement, _search) && Keyboard.FocusedElement is TextBox) { FocusSearch(); return false; }
        if (_search.Text.Length > 0) { _search.Text = ""; return false; }
        return true;
    }

    // MARK: Search

    private void QueryChanged()
    {
        _searchTimer.Stop();
        if (_search.Text.Trim().Length == 0)
        {
            _results = null;
            _selection = null;
            Rebuild();
            return;
        }
        _searchTimer.Start();
    }

    private int _searchGeneration;

    private void RunSearch()
    {
        var text = _search.Text.Trim();
        if (text.Length == 0) return;
        var generation = ++_searchGeneration;
        Task.Run(() => Library.Search(text)).ContinueWith(task =>
        {
            if (generation != _searchGeneration || !task.IsCompletedSuccessfully) return;
            _results = task.Result;
            _selection = _results.Count > 0 ? RowKey.Hit(_results[0].Session.Id) : null;
            Rebuild();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    // MARK: Building the page

    private Grid? _searchBar;
    private bool _rebuilding;

    /// <summary>Puts the page together again from the current state.</summary>
    public void Rebuild()
    {
        if (_rebuilding) return;
        _rebuilding = true;
        try
        {
            var offset = _scroll.VerticalOffset;
            _rowKeys.Clear();
            _rowElements.Clear();
            PaintFooter();
            PaintTimerBar();
            if (_showingReleaseNotes)
            {
                _releasePage ??= new ReleaseNotesPage(_host, () => { _showingReleaseNotes = false; Rebuild(); });
                _releasePage.Rebuild();
                _body.Content = _releasePage.View;
                return;
            }
            if (_showingSettings)
            {
                _settingsPage ??= new SettingsPage(_host, CloseSettings, () => { _showingReleaseNotes = true; Rebuild(); });
                _settingsPage.Rebuild();
                _body.Content = _settingsPage.View;
                return;
            }
            if (_outline is not null)
            {
                _body.Content = OutlinePage(_outline);
                return;
            }
            if (_projectPage is not null && Library.Current.Project(_projectPage) is { } project)
            {
                _body.Content = ProjectPage(project, offset);
                return;
            }
            _projectPage = null;

            var browse = new Grid();
            browse.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            browse.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            var top = new StackPanel();
            top.Children.Add(SearchBar());
            if (_search.Text.Trim().Length == 0) top.Children.Add(TabBar());
            if (FilterBar() is { } filters) top.Children.Add(filters);
            if (ExpiryBanner() is { } banner) top.Children.Add(banner);
            Grid.SetRow(top, 0);
            browse.Children.Add(top);

            _list.Children.Clear();
            FillList();
            if (_scroll.Parent is Panel parent) parent.Children.Remove(_scroll);
            if (_scroll.Parent is ContentControl holder) holder.Content = null;
            Grid.SetRow(_scroll, 1);
            browse.Children.Add(_scroll);
            _body.Content = browse;
            _scroll.UpdateLayout();
            _scroll.ScrollToVerticalOffset(offset);
            ApplyFocusRequest();
        }
        finally
        {
            _rebuilding = false;
        }
    }

    private Grid SearchBar()
    {
        if (_searchView.Parent is Panel oldParent) oldParent.Children.Remove(_searchView);
        // The field outlives each search bar; the row adds its spacing to the margin, so it starts from none.
        _searchView.Margin = new Thickness(0);
        var more = Ui.IconButton(Theme.Glyph.More, () => Ui.Show(MoreMenu(), _searchBar!), null, 13, T.Secondary, 22, 22);
        var clear = _search.Text.Length > 0
            ? Ui.IconButton(Theme.Glyph.Clear, () => { _search.Text = ""; FocusSearch(); }, L.ClearSearch, 10, T.Tertiary, 20, 20)
            : null;
        var close = Ui.IconButton(Theme.Glyph.Close, HidePanel, L.Close, 10, T.Secondary, 22, 22);
        var row = Ui.Row(new UIElement[] { Ui.Icon(Theme.Glyph.Search, 13, T.Secondary) }, _searchView, new UIElement?[] { clear, more, close }, 6);
        var field = new Border { Child = row, Height = 38, Padding = new Thickness(12, 0, 8, 0), CornerRadius = new CornerRadius(10), Background = T.Overlay(0.07) };
        _searchBar = new Grid { Background = Brushes.Transparent };
        _searchBar.Children.Add(new Border { Child = field, Margin = new Thickness(12, 12, 12, 4) });
        DragArea(_searchBar);
        return _searchBar;
    }

    private ContextMenu MoreMenu() => Ui.Menu(
        Ui.Item(L.Refresh, () => Library.Refresh()),
        Ui.Item(L.NewTag, () => { _tagEditor = new TagEditorState(null, "", 4, null); Rebuild(); }),
        Ui.Item(L.StaysOpen, () => Library.ChangeSettings(settings => settings.StaysOpen = !settings.StaysOpen, reload: false), check: Settings.StaysOpen),
        Ui.Item(L.SettingsMenu, ShowSettings),
        ReleaseNotesPage.Releases is { Count: > 0 } releases && Updates.IsNewer(releases[0].Version, Updates.Installed)
            ? Ui.Item(L.UpdateMenu(releases[0].Version), () => { _showingReleaseNotes = true; Rebuild(); })
            : null,
        Ui.Divider(),
        Ui.Item(L.Quit, _host.Quit));

    private void ShowSettings()
    {
        _card.HideCard();
        _outline = null;
        _showingSettings = true;
        Rebuild();
    }

    private void CloseSettings()
    {
        _settingsPage?.CancelRecording();
        _showingSettings = false;
        Rebuild();
        FocusSearch();
    }

    private void SaveTab() => Library.ChangeSettings(settings => settings.PanelTab = _tab.ToString().ToLowerInvariant(), reload: false);

    private Border TabBar()
    {
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1 };
        foreach (var tab in Enum.GetValues<PanelTab>())
        {
            var selected = tab == _tab;
            var (glyph, title) = tab switch
            {
                PanelTab.Today => (Theme.Glyph.Today, L.Today),
                PanelTab.Chats => (Theme.Glyph.Chats, L.ChatsTab),
                _ => (Theme.Glyph.Clock, L.TimeTitle),
            };
            var content = Ui.HStack(6, Ui.Icon(glyph, 11, selected ? T.Text : T.Secondary), Ui.Label(title, 12, selected ? T.Text : T.Secondary, selected ? FontWeights.SemiBold : FontWeights.Normal));
            if (tab == PanelTab.Today && Library.NeedsYou.Count is var count and > 0)
            {
                var badge = Ui.Capsule(Ui.Label(count.ToString(), 10, T.White, FontWeights.SemiBold), T.Solid(T.Orange), 15, 5);
                badge.MinWidth = 16;
                content.Children.Add(badge.Margin(6, 0, 0, 0));
            }
            content.HorizontalAlignment = HorizontalAlignment.Center;
            var button = Ui.Hover(content, () =>
            {
                if (_tab == tab) return;
                _tab = tab;
                _selection = null;
                SaveTab();
                Rebuild();
            }, 7, selected ? T.Overlay(0.10) : null, T.Overlay(0.05));
            button.Height = 26;
            button.Margin = new Thickness(2, 0, 2, 0);
            grid.Children.Add(button);
        }
        return new Border { Child = grid, Padding = new Thickness(3), CornerRadius = new CornerRadius(9), Background = T.Overlay(0.05), Margin = new Thickness(12, 6, 12, 2) };
    }

    private FrameworkElement? FilterBar()
    {
        var organizations = Settings.ShowsOrganizations && Library.Current.Organizations.Count > 1;
        var tagsShown = Library.Current.Tags.Count > 0 && (_tab == PanelTab.Chats || _results is not null || Library.TagFilter is not null);
        if (!organizations && _tagEditor is null && !tagsShown) return null;
        var stack = new StackPanel { Margin = new Thickness(12, 6, 12, 2) };
        if (organizations)
        {
            var list = Library.Current.Organizations;
            var titles = new[] { L.All }.Concat(list.Select(organization => organization.Name.Length > 16 ? organization.Name[..15] + "…" : organization.Name)).ToList();
            var selected = Settings.OrganizationFilter is { } filter ? list.ToList().FindIndex(organization => organization.Id == filter) + 1 : 0;
            stack.Children.Add(Ui.Segmented(titles, selected, index =>
                Library.ChangeSettings(settings => settings.OrganizationFilter = index == 0 ? null : list[index - 1].Id)));
        }
        if (_tagEditor is { } editor) stack.Children.Add(TagEditorRow(editor).Margin(0, organizations ? 8 : 0, 0, 0));
        else if (tagsShown)
        {
            var chips = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var tag in Library.Current.Tags)
            {
                var selected = Library.TagFilter == tag.Id;
                var chip = Ui.Hover(Ui.HStack(5, Ui.TagMark(tag.Color), Ui.Label(tag.Name, 11, T.Text, selected ? FontWeights.SemiBold : FontWeights.Normal)),
                    () => Library.SetTagFilter(tag.Id), 11, selected ? T.Solid(T.TagColor(tag.Color), 0.28) : T.Overlay(0.07), T.Overlay(0.11), new Thickness(9, 0, 9, 0));
                chip.Height = 22;
                chip.Margin = new Thickness(0, 0, 6, 0);
                chip.ContextMenu = Ui.Menu(
                    Ui.Item(L.Rename, () => { _tagEditor = new TagEditorState(tag.Id, tag.Name, tag.Color, null); Rebuild(); }),
                    Ui.Submenu(L.Color, L.ColorNames.Select((name, index) => (object?)Ui.Item(name, () => Library.Recolor(tag, index), check: tag.Color == index))),
                    Ui.Divider(),
                    Ui.Item(L.DeleteTag, () => Library.Delete(tag)));
                chips.Children.Add(chip);
            }
            stack.Children.Add(new ScrollViewer { Content = chips, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Margin = new Thickness(0, organizations ? 8 : 0, 0, 0) });
        }
        return stack;
    }

    private sealed record TagEditorState(long? TagId, string Name, int Color, string? SessionId);
    private TagEditorState? _tagEditor;

    private Border TagEditorRow(TagEditorState editor)
    {
        var (view, box) = Ui.Field(L.TagName, 12, field =>
        {
            Library.SaveTag(editor.TagId, field.Text, _tagEditor?.Color ?? editor.Color, editor.SessionId);
            _tagEditor = null;
            FocusSearch();
        }, editor.Name);
        box.TextChanged += (_, _) => { if (_tagEditor is not null) _tagEditor = _tagEditor with { Name = box.Text }; };
        var dots = new StackPanel { Orientation = Orientation.Horizontal };
        for (var index = 0; index < 7; index++)
        {
            var at = index;
            var dot = new Border
            {
                Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Cursor = Cursors.Hand,
                BorderThickness = new Thickness(editor.Color == index ? 1.5 : 0), BorderBrush = T.Overlay(0.75),
                Child = Ui.Dot(12, T.Solid(T.TagColor(index))),
            }.Tip(L.ColorNames[index]);
            dot.MouseLeftButtonUp += (_, _) => { _tagEditor = (_tagEditor ?? editor) with { Color = at, Name = box.Text }; Rebuild(); };
            dots.Children.Add(dot);
        }
        _focusRequest ??= "tag";
        box.Tag = "tag";
        return new Border { Child = Ui.Row(Array.Empty<UIElement>(), view, new UIElement[] { dots }, 9), Padding = new Thickness(10, 0, 10, 0), Height = 32, CornerRadius = new CornerRadius(8), Background = T.Overlay(0.07) };
    }

    private bool _expiryExpanded;
    private bool _expiryAll;

    private FrameworkElement? ExpiryBanner()
    {
        var expiring = Library.UnbackedExpiringSessions;
        if (expiring.Count == 0) return null;
        var header = Ui.Row(
            new UIElement[]
            {
                Ui.Hover(Ui.HStack(6, Ui.Icon(Theme.Glyph.Warning, 11, T.Solid(T.Orange)), Ui.Label(L.ExpiringChats(expiring.Count), 12),
                    Ui.Icon(_expiryExpanded ? Theme.Glyph.ChevronDown : Theme.Glyph.ChevronRight, 8, T.Tertiary)),
                    () => { _expiryExpanded = !_expiryExpanded; Rebuild(); }, 5),
            },
            null,
            new UIElement[] { Ui.SmallButton(L.BackUp, () => Library.BackUp(expiring)) });
        var stack = new StackPanel();
        stack.Children.Add(header);
        if (_expiryExpanded)
        {
            foreach (var session in _expiryAll ? expiring : expiring.Take(3))
            {
                var days = Library.DaysLeft(session) ?? 0;
                var row = Ui.Row(new UIElement[] { Ui.Label(session.Title, 12) },
                    Ui.Label(session.ProjectName, 11, T.Secondary).Margin(6, 0, 0, 0),
                    new UIElement[] { Ui.Label(days <= 0 ? L.Today.ToLower(L.Culture) : L.Days(days), 11, T.Secondary) });
                var hover = Ui.Hover(row, () => Open(session), 6, null, T.Overlay(0.08), new Thickness(19, 4, 6, 4));
                hover.ContextMenu = Ui.Menu(
                    Ui.Item(L.BackUpTranscript, () => Library.BackUp(new[] { session })),
                    Ui.Item(L.PromptOutline, () => ShowOutline(session, null)));
                stack.Children.Add(hover);
            }
            if (!_expiryAll && expiring.Count > 3)
            {
                stack.Children.Add(Ui.Hover(Ui.Label(L.MoreSessions(expiring.Count - 3), 11, T.Secondary), () => { _expiryAll = true; Rebuild(); }, 5, null, null, new Thickness(25, 4, 0, 4)));
            }
        }
        return new Border
        {
            Child = stack,
            Padding = new Thickness(12, 6, 8, 6),
            CornerRadius = new CornerRadius(9),
            Background = T.Solid(T.Orange, 0.10),
            Margin = new Thickness(12, 0, 12, 4),
        }.Tip(L.ExpiryHelp(Retention.Days));
    }
}
