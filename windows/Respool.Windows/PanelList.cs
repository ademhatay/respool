using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Respool.Core;

namespace Respool.Windows;

public sealed partial class PanelWindow
{
    // MARK: State that is not saved

    private PanelTab _tab;
    private IReadOnlyList<SearchHit>? _results;
    private string? _selection;
    private TaskLink? _taskLink;
    private string? _addingTaskFor;
    private string _pinDraft = "";
    private string _todoDraft = "";
    private string _noteDraft = "";
    private string? _renamingRow;
    private string? _renamingProject;
    private string? _projectPage;
    private SessionOutline? _outline;
    private bool _showingSettings;
    private bool _showingReleaseNotes;
    private string _selectedDay = Format.Today;
    private DateTime _calendarAnchor = DateTime.Today;
    private readonly Dictionary<string, bool> _dayFold = new();
    private readonly HashSet<string> _showingAll = new();
    private readonly HashSet<long> _expandedNotes = new();
    private bool _timeShowAll;
    private string? _focusRequest;

    /// <summary>The keys of the session rows in the order they are shown, for ↑ and ↓.</summary>
    private readonly List<string> _rowKeys = new();
    private readonly Dictionary<string, FrameworkElement> _rowElements = new();

    private double RowPadding => Settings.Compact ? 3 : 7;

    // MARK: The list

    private void FillList()
    {
        var current = Library.Current;
        if (!Library.HasLoaded) return;
        if (current.Sessions.Count == 0)
        {
            _list.Children.Add(EmptyState());
            return;
        }
        if (_results is { } results)
        {
            if (results.Count == 0)
            {
                _list.Children.Add(Ui.VStack(6, Centered(Ui.Label(L.NoResults, 13, T.Text, FontWeights.Medium)),
                    Centered(Ui.Label(L.NoMatch(_search.Text.Trim()), 12, T.Secondary, lines: 0))).Margin(24, 48, 24, 0));
                return;
            }
            _list.Children.Add(SectionHeader(L.Sessions(results.Count)));
            foreach (var hit in results)
            {
                _list.Children.Add(SessionRow(hit.Session, RowKey.Hit(hit.Session.Id), detail: hit.Session.PlaceLabel, snippet: hit.Snippet, matchRow: hit.MatchRow));
            }
            return;
        }
        if (current.Tagged is { } tagged && current.Tags.FirstOrDefault(tag => tag.Id == Library.TagFilter) is { } filter)
        {
            if (tagged.Count == 0)
            {
                _list.Children.Add(Ui.VStack(6, Centered(Ui.Label(L.NoTaggedChats, 13, T.Text, FontWeights.Medium)),
                    Centered(Ui.Label(L.TagHint(filter.Name), 12, T.Secondary, lines: 0))).Margin(24, 48, 24, 0));
                return;
            }
            _list.Children.Add(SectionHeader(L.SessionsInTag(filter.Name, tagged.Count)));
            foreach (var session in tagged) _list.Children.Add(SessionRow(session, RowKey.Tagged(session.Id), session.PlaceLabel));
            return;
        }

        if (_tab == PanelTab.Today && Library.ShowsDayEndCard) _list.Children.Add(DayEndCard());
        foreach (var section in Settings.SectionOrder)
        {
            if (PanelSection.Tab(section) != _tab || !IsShown(section)) continue;
            switch (section)
            {
                case PanelSection.Waiting: WaitingSection(); break;
                case PanelSection.TodayChats: TodayChatsSection(); break;
                case PanelSection.Todos: TodosSection(); break;
                case PanelSection.Notes: NotesSection(); break;
                case PanelSection.Pinned: PinnedSection(); break;
                case PanelSection.Recent: RecentSection(); break;
                case PanelSection.Projects: ProjectsSection(); break;
                case PanelSection.TimeSection: TimeSection(); break;
                case PanelSection.Week: WeekSection(); break;
            }
        }
    }

    private static FrameworkElement Centered(FrameworkElement element)
    {
        element.HorizontalAlignment = HorizontalAlignment.Center;
        if (element is TextBlock text) text.TextAlignment = TextAlignment.Center;
        return element;
    }

    private FrameworkElement EmptyState()
    {
        if (Library.Indexing is { } progress)
        {
            var bar = new ProgressBar { Width = 160, Height = 4, Maximum = Math.Max(progress.Total, 1), Value = progress.Done };
            return Ui.VStack(8, Centered(bar), Centered(Ui.Label(L.Indexing, 13, T.Text, FontWeights.Medium)),
                Centered(Ui.Label($"{progress.Done} / {progress.Total}", 12, T.Secondary))).Margin(32, 120, 32, 0);
        }
        return Ui.VStack(6, Centered(Ui.Label(L.NoChats, 13, T.Text, FontWeights.Medium)),
            Centered(Ui.Label(L.NoChatsHint, 12, T.Secondary, lines: 0))).Margin(32, 120, 32, 0);
    }

    private bool IsShown(string section) => section switch
    {
        PanelSection.Todos => Settings.ShowsTodos,
        PanelSection.Week => Settings.ShowsWeek,
        PanelSection.TimeSection => Settings.ShowsTime,
        _ => !Settings.HiddenSections.Contains(section),
    };

    private bool IsCollapsed(string section) => Settings.CollapsedSections.Contains(section);

    private void ToggleSection(string section) => Library.ChangeSettings(settings =>
    {
        if (!settings.CollapsedSections.Remove(section)) settings.CollapsedSections.Add(section);
    }, reload: false);

    /// <summary>A section's title that folds it away, with its count while folded.</summary>
    private FrameworkElement CollapsibleHeader(string section, int count, FrameworkElement? trailing = null)
    {
        var collapsed = IsCollapsed(section);
        var chevron = Ui.Icon(collapsed ? Theme.Glyph.ChevronRight : Theme.Glyph.ChevronDown, 8, T.Tertiary);
        chevron.Opacity = collapsed ? 1 : 0;
        var title = Ui.HStack(5,
            Ui.Label(PanelSection.Title(section), 11, T.Secondary, FontWeights.SemiBold),
            collapsed && count > 0 ? Ui.Label(L.Count(count), 11, T.Tertiary) : null,
            chevron);
        var button = Ui.Hover(title, () => { ToggleSection(section); Rebuild(); }, 4, null, Brushes.Transparent).Tip(collapsed ? L.ShowSection : L.HideSection);
        button.MouseEnter += (_, _) => chevron.Opacity = 1;
        button.MouseLeave += (_, _) => chevron.Opacity = collapsed ? 1 : 0;
        var row = Ui.Row(new UIElement[] { button }, null, trailing is null ? Array.Empty<UIElement>() : new UIElement[] { trailing.Margin(0, 0, 4, 0) });
        row.Margin = new Thickness(8, 20, 8, 6);
        return row;
    }

    private FrameworkElement SectionHeader(string title) =>
        Ui.Label(title, 11, T.Secondary, FontWeights.SemiBold).Margin(8, 16, 8, 4);

    // MARK: Sections

    private void WaitingSection()
    {
        var waiting = Library.NeedsYou;
        if (waiting.Count == 0) return;
        _list.Children.Add(CollapsibleHeader(PanelSection.Waiting, waiting.Count));
        if (IsCollapsed(PanelSection.Waiting)) return;
        foreach (var session in waiting)
        {
            var live = Library.Live.GetValueOrDefault(session.Id);
            var state = live?.State == LiveState.Waiting
                ? (live.WaitingFor is { Length: > 0 } what ? L.WaitingFor(what) : L.Waiting)
                : L.Finished;
            _list.Children.Add(SessionRow(session, RowKey.Waiting(session.Id), state + " · " + session.PlaceLabel));
        }
    }

    /// <summary>The chats worked in today: the ones prompts were typed in, the busiest first.</summary>
    private void TodayChatsSection()
    {
        var work = Library.TodaySummary?.Work ?? Array.Empty<DayWork>();
        if (work.Count == 0) return;
        _list.Children.Add(CollapsibleHeader(PanelSection.TodayChats, work.Count));
        if (IsCollapsed(PanelSection.TodayChats)) return;
        foreach (var item in work)
        {
            _list.Children.Add(SessionRow(item.Session, RowKey.Today(item.Session.Id), L.PromptsLine(item.Session.PlaceLabel, item.Prompts)));
        }
    }

    private void PinnedSection()
    {
        var pinned = Library.Current.Pinned;
        if (pinned.Count == 0) return;
        _list.Children.Add(CollapsibleHeader(PanelSection.Pinned, pinned.Count));
        if (IsCollapsed(PanelSection.Pinned)) return;
        foreach (var pin in pinned) _list.Children.Add(PinnedCard(pin));
    }

    private void RecentSection()
    {
        var recent = Library.Current.Recent;
        if (recent.Count == 0) return;
        _list.Children.Add(CollapsibleHeader(PanelSection.Recent, recent.Count));
        if (IsCollapsed(PanelSection.Recent)) return;
        foreach (var session in recent) _list.Children.Add(SessionRow(session, RowKey.Recent(session.Id), session.PlaceLabel));
    }

    private void ProjectsSection()
    {
        var current = Library.Current;
        _list.Children.Add(CollapsibleHeader(PanelSection.Projects, current.Projects.Count, ProjectSortMenuButton()));
        if (IsCollapsed(PanelSection.Projects)) return;
        if (current.Projects.Count == 0 && current.AllProjects.Count > 0)
        {
            _list.Children.Add(Ui.Label(L.AllProjectsHidden, 12, T.Secondary, lines: 0).Margin(8, 6));
            return;
        }
        foreach (var project in current.Projects) _list.Children.Add(ProjectSection(project));
    }

    private FrameworkElement ProjectSortMenuButton()
    {
        var filtering = Settings.HidesSingleSessionProjects || Settings.HidesInactiveProjects || Library.Current.Hidden.Count > 0;
        Border? button = null;
        button = Ui.IconButton(Theme.Glyph.Filter, () =>
        {
            var sort = (ProjectSort)Settings.ProjectSort;
            var menu = Ui.Menu(
                Ui.Submenu(L.SortBy, Enum.GetValues<ProjectSort>().Select(choice =>
                    (object?)Ui.Item(choice.Title(), () => Library.ChangeSettings(settings => settings.ProjectSort = (int)choice), check: choice == sort))),
                Ui.Divider(),
                Ui.Item(L.HideSingleSessionProjects, () => Library.ChangeSettings(settings => settings.HidesSingleSessionProjects = !settings.HidesSingleSessionProjects), check: Settings.HidesSingleSessionProjects),
                Ui.Item(L.HideInactiveProjects, () => Library.ChangeSettings(settings => settings.HidesInactiveProjects = !settings.HidesInactiveProjects), check: Settings.HidesInactiveProjects),
                Library.Current.Hidden.Count > 0 ? Ui.Divider() : null,
                Library.Current.Hidden.Count > 0 ? Ui.Item(L.ManageHidden, ShowSettings) : null);
            Ui.Show(menu, button!);
        }, L.SortOrFilter, 11, filtering ? T.Accent : T.Secondary, 22, 22);
        return button;
    }

    private void WeekSection()
    {
        var week = Library.Current.Week;
        if (week.Count == 0) return;
        var distinct = week.SelectMany(day => day.Work.Select(work => work.Session.Id)).Distinct().Count();
        _list.Children.Add(CollapsibleHeader(PanelSection.Week, distinct));
        if (IsCollapsed(PanelSection.Week)) return;
        foreach (var day in week)
        {
            var open = _dayFold.TryGetValue(day.Day, out var folded) ? folded : day.Day == Format.Today;
            var row = Ui.Row(
                new UIElement[] { Ui.Icon(open ? Theme.Glyph.ChevronDown : Theme.Glyph.ChevronRight, 9, T.Tertiary).Margin(0, 0, 0, 0), Ui.Label(Format.DayLabel(day.Day), 12, T.Text, FontWeights.Medium) },
                null,
                new UIElement[] { Ui.Label(L.DaySummary(day.Work.Count, day.Prompts), 11, T.Tertiary) });
            var key = day.Day;
            _list.Children.Add(Ui.Hover(row, () => { _dayFold[key] = !open; Rebuild(); }, 7, null, null, new Thickness(8, 6, 8, 6)).Tip(open ? L.HideDay : L.ShowDay));
            if (!open) continue;
            foreach (var work in day.Work)
            {
                _list.Children.Add(SessionRow(work.Session, RowKey.Day(day.Day, work.Session.Id), L.PromptsLine(work.Session.PlaceLabel, work.Prompts), inset: 16));
            }
        }
    }

    // MARK: Session row

    /// <summary>One chat: where it opens, its title and detail, and its time or the buttons that show under the pointer.</summary>
    private FrameworkElement SessionRow(SessionRecord session, string key, string detail, double inset = 0, Snippet? snippet = null, long? matchRow = null, bool pinned = false, Action? addTask = null)
    {
        _rowKeys.Add(key);
        var selected = _selection == key;
        var titleBrush = selected ? T.White : T.Text;
        var detailBrush = selected ? T.Solid(Colors.White, 0.78) : T.Secondary;
        var faintBrush = selected ? T.Solid(Colors.White, 0.62) : T.Tertiary;

        var mark = new Border { Width = 15, Height = 15, Child = AppMarks.For(Library.Destination(session), 15), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 0, 0) }
            .Tip(Library.Destination(session) is var destination && destination == OpenMethod.Automatic ? "Terminal" : destination.Title());

        FrameworkElement title;
        if (_renamingRow == key)
        {
            var (view, box) = Ui.Field(session.OriginalTitle, 13, field => { Library.Rename(session, field.Text); _renamingRow = null; FocusSearch(); }, session.Title);
            box.Tag = "rename";
            box.LostKeyboardFocus += (_, _) => { if (_renamingRow == key) { Library.Rename(session, box.Text); _renamingRow = null; } };
            _focusRequest = "rename";
            title = view;
        }
        else
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal };
            var text = Ui.Label(session.Title, 13, titleBrush);
            line.Children.Add(text);
            foreach (var tag in Library.TagsOf(session).Take(3)) line.Children.Add(Ui.TagMark(tag.Color, selected).Tip(tag.Name).Margin(5, 0, 0, 0));
            if (Library.Expiry(session) is { } expiry)
            {
                var glyph = expiry.BackedUp ? Theme.Glyph.Download : Theme.Glyph.Warning;
                var color = selected ? T.White : expiry.BackedUp ? T.Secondary : T.Solid(T.Orange);
                var tip = expiry.BackedUp
                    ? (expiry.Days <= 0 ? L.BackedUp : L.BackedUpDaysLeft(expiry.Days))
                    : (expiry.Days <= 0 ? L.MayDeleteNow : L.MayDeleteIn(expiry.Days));
                line.Children.Add(Ui.Icon(glyph, 10, color).Tip(tip).Margin(5, 0, 0, 0));
            }
            title = line;
        }

        FrameworkElement detailView;
        if (snippet is not null)
        {
            var block = new TextBlock { FontSize = 11, Foreground = detailBrush, TextWrapping = TextWrapping.Wrap, MaxHeight = 30, TextTrimming = TextTrimming.CharacterEllipsis, FontFamily = Theme.Font };
            var at = 0;
            foreach (var (start, end) in snippet.Matches)
            {
                if (start > at) block.Inlines.Add(new System.Windows.Documents.Run(snippet.Text[at..start]));
                block.Inlines.Add(new System.Windows.Documents.Run(snippet.Text[start..end]) { FontWeight = FontWeights.SemiBold, Foreground = titleBrush });
                at = end;
            }
            if (at < snippet.Text.Length) block.Inlines.Add(new System.Windows.Documents.Run(snippet.Text[at..]));
            detailView = block;
        }
        else detailView = Ui.Label(detail, 11, detailBrush);
        var middle = Ui.VStack(2, title, detail.Length > 0 || snippet is not null ? detailView : null);

        // The time, swapped for the buttons under the pointer.
        var resting = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 0, 0) };
        if (Library.Live.TryGetValue(session.Id, out var live))
        {
            resting.Children.Add(Ui.LiveMark(live.State, Library.AttentionSet.Contains(session.Id), selected).Margin(0, 0, 6, 0));
        }
        else if (Library.AttentionSet.Contains(session.Id))
        {
            resting.Children.Add(Ui.Dot(7, selected ? T.White : T.Solid(T.Green)).Margin(0, 0, 6, 0));
        }
        resting.Children.Add(Ui.Label(Format.Relative(session.LastActivity), 11, faintBrush));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top, Opacity = 0 };
        if (addTask is not null) buttons.Children.Add(Ui.IconButton(Theme.Glyph.Add, addTask, L.AddTask, 11, detailBrush));
        buttons.Children.Add(matchRow is not null
            ? Ui.IconButton(Theme.Glyph.Find, () => ShowOutline(session, matchRow), L.GoToMatch, 11, detailBrush)
            : Ui.IconButton(Theme.Glyph.List, () => ShowOutline(session, null), L.PromptOutline, 11, detailBrush));
        var isPinned = Library.IsPinned(session.Id);
        buttons.Children.Add(Ui.IconButton(isPinned ? Theme.Glyph.Unpin : Theme.Glyph.Pin, () => Library.TogglePin(session.Id), isPinned ? L.Unpin : L.Pin, 11, detailBrush));
        var trailing = new Grid { Height = 16, VerticalAlignment = VerticalAlignment.Top };
        resting.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        trailing.Children.Add(resting);
        trailing.Children.Add(buttons);

        var row = Ui.Row(new UIElement[] { mark }, middle, new UIElement[] { trailing.Margin(4, 0, 0, 0) });
        var hover = Ui.Hover(row, () => Open(session), 7, selected ? T.Accent : null, null, new Thickness(8 + inset, RowPadding, 8, RowPadding));
        hover.MouseEnter += (_, _) => { resting.Opacity = 0; buttons.Opacity = 1; HoverBegan(session, null, hover); };
        hover.MouseLeave += (_, _) => { resting.Opacity = 1; buttons.Opacity = 0; HoverEnded(); };
        hover.ContextMenuOpening += (_, _) => hover.ContextMenu = SessionMenu(session, key, matchRow);
        hover.ContextMenu = new ContextMenu();
        hover.Margin = new Thickness(0, 0, 0, 1);
        _rowElements[key] = hover;
        return hover;
    }

    private ContextMenu SessionMenu(SessionRecord session, string key, long? matchRow)
    {
        var running = Library.Live.ContainsKey(session.Id);
        var methods = Opener.Installed.Where(method => method != OpenMethod.Automatic)
            .Select(method => (object?)Ui.Item(method.Title(), () =>
            {
                if (method == OpenMethod.Desktop) _host.OpenInDesktop(session); else _host.Open(session, method);
            }, enabled: !running || method == OpenMethod.Desktop));
        var tags = Library.Current.Tags.Select(tag => (object?)Ui.Item(tag.Name, () => Library.Toggle(tag, session), check: session.TagIds.Contains(tag.Id))).ToList();
        if (tags.Count > 0) tags.Add(Ui.Divider());
        tags.Add(Ui.Item(L.NewTag, () => { _tagEditor = new TagEditorState(null, "", 4, session.Id); Rebuild(); }));
        return Ui.Menu(
            Ui.Submenu(L.OpenWith, methods),
            Ui.Item(matchRow is not null ? L.GoToMatch : L.PromptOutline, () => ShowOutline(session, matchRow)),
            Ui.Divider(),
            Ui.Item(Library.IsPinned(session.Id) ? L.Unpin : L.Pin, () => Library.TogglePin(session.Id)),
            Ui.Item(L.AddTask, () => BeginTask(new TaskLink.ToSession(session.Id, session.Title))),
            Ui.Item(L.Rename, () => { _renamingRow = key; Rebuild(); }),
            session.LocalName is not null ? Ui.Item(L.RestoreTitle, () => Library.Rename(session, "")) : null,
            Ui.Submenu(L.Tags, tags),
            Ui.Divider(),
            Ui.Item(L.BackUpTranscript, () => Library.BackUp(new[] { session })),
            Directory(session.Cwd) ? Ui.Item(L.ShowInFinder, () => Opener.RevealFolder(session.Cwd)) : null,
            Ui.Item(L.CopySessionID, () => Copy(session.Id)));
    }

    private static bool Directory(string path) => path.Length > 0 && System.IO.Directory.Exists(path);

    private static void Copy(string text)
    {
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.COMException) { }
    }

    /// <summary>Starts a to-do attached to a session or project, on the Today tab.</summary>
    private void BeginTask(TaskLink link)
    {
        ClearForBrowse();
        _taskLink = link;
        _tab = PanelTab.Today;
        SaveTab();
        Library.ChangeSettings(settings => { settings.ShowsTodos = true; settings.CollapsedSections.Remove(PanelSection.Todos); }, reload: false);
        _focusRequest = "todo";
        Rebuild();
    }

    // MARK: Pinned card

    private FrameworkElement PinnedCard(PinnedSession pin)
    {
        var session = pin.Session;
        var detail = pin.OpenCount > 0 ? L.OpenTasksLine(session.PlaceLabel, pin.OpenCount) : session.PlaceLabel;
        var stack = new StackPanel();
        var row = SessionRow(session, RowKey.Pin(session.Id), detail, pinned: true, addTask: () => { _addingTaskFor = session.Id; _pinDraft = ""; _focusRequest = "pin"; Rebuild(); });
        stack.Children.Add(row);
        foreach (var task in pin.Tasks) stack.Children.Add(TaskRow(task, pin.Tasks, showLink: false, listedDay: null));
        if (_addingTaskFor == session.Id)
        {
            var (view, box) = Ui.Field(L.AddTask, 12, field =>
            {
                if (field.Text.Trim().Length == 0) { _addingTaskFor = null; Rebuild(); FocusSearch(); return; }
                Library.AddTask(field.Text, session.Id);
                _pinDraft = "";
                _focusRequest = "pin";
            }, _pinDraft);
            box.Tag = "pin";
            box.TextChanged += (_, _) => _pinDraft = box.Text;
            box.LostKeyboardFocus += (_, _) =>
            {
                if (box.Text.Trim().Length == 0 && _addingTaskFor == session.Id && _focusRequest != "pin")
                {
                    _addingTaskFor = null;
                    Dispatcher.BeginInvoke(Rebuild, DispatcherPriority.Background);
                }
            };
            stack.Children.Add(Ui.Row(new UIElement[] { Ui.Icon(Theme.Glyph.Circle, 14, T.Tertiary) }, view, Array.Empty<UIElement>()).Margin(8, 4));
        }
        var card = new Border { Child = stack, CornerRadius = new CornerRadius(7), Background = Brushes.Transparent };
        // Dragging a pin onto another puts it before or after it.
        row.MouseMove += (_, e) =>
        {
            if (e.LeftButton != MouseButtonState.Pressed || Library.Current.Pinned.Count < 2) return;
            DragDrop.DoDragDrop(row, "pin:" + session.Id, DragDropEffects.Move);
        };
        card.AllowDrop = true;
        card.DragOver += (_, e) =>
        {
            var ok = e.Data.GetData(typeof(string)) is string payload && payload.StartsWith("pin:", StringComparison.Ordinal) && payload[4..] != session.Id;
            e.Effects = ok ? DragDropEffects.Move : DragDropEffects.None;
            card.Background = ok ? T.AccentAt(0.12) : Brushes.Transparent;
            e.Handled = true;
        };
        card.DragLeave += (_, _) => card.Background = Brushes.Transparent;
        card.Drop += (_, e) =>
        {
            card.Background = Brushes.Transparent;
            if (e.Data.GetData(typeof(string)) is not string payload || !payload.StartsWith("pin:", StringComparison.Ordinal)) return;
            var after = e.GetPosition(card).Y > card.ActualHeight / 2;
            Library.MovePin(payload[4..], session.Id, after);
        };
        return card;
    }

    // MARK: Project section

    private FrameworkElement ProjectSection(ProjectGroup project)
    {
        var expanded = Settings.ExpandedProjects.Contains(project.Key);
        var timing = Library.IsTiming(project.Key);
        var stack = new StackPanel();

        FrameworkElement name;
        if (_renamingProject == project.Key)
        {
            var (view, box) = Ui.Field(L.ProjectName, 13, field => { Library.Rename(project, field.Text); _renamingProject = null; FocusSearch(); }, project.Name);
            box.Tag = "rename";
            _focusRequest = "rename";
            name = view;
        }
        else name = Ui.Label(project.Name, 13, T.Text, FontWeights.SemiBold);

        var badge = Ui.Capsule(Ui.Label(L.Count(project.Sessions.Count), 10, T.Secondary, FontWeights.Medium), T.Overlay(0.08), 15, 5);
        badge.MinWidth = 18;
        var timer = Ui.IconButton(timing ? Theme.Glyph.Stop : Theme.Glyph.Play, () => Library.ToggleTimer(project.Key), timing ? L.StopTimer : L.StartTimer, 9, timing ? T.Accent : T.Secondary);
        var start = Ui.IconButton(Theme.Glyph.Terminal, () => _host.StartSession(project), L.StartChatHere, 11, T.Secondary);
        var info = Ui.IconButton(Theme.Glyph.Info, () => OpenProjectPage(project.Key), L.ProjectPage, 11, T.Secondary);
        timer.Visibility = timing ? Visibility.Visible : Visibility.Collapsed;
        start.Visibility = Visibility.Collapsed;
        info.Visibility = Visibility.Collapsed;
        var header = Ui.Row(
            new UIElement[]
            {
                Ui.Icon(expanded ? Theme.Glyph.ChevronDown : Theme.Glyph.ChevronRight, 9, T.Tertiary),
                Ui.Icon(expanded ? Theme.Glyph.FolderOpen : Theme.Glyph.Folder, 12, expanded ? T.Accent : T.Secondary).Margin(-1, 0, 0, 0),
            },
            Ui.HStack(7, name, badge),
            new UIElement[] { timer, start, info, Ui.Label(Format.Relative(project.LastActivity), 11, T.Tertiary).Margin(4, 0, 0, 0) },
            7);
        var padding = Settings.Compact ? 4 : 7;
        var hover = Ui.Hover(header, () => ToggleProject(project.Key), 7, expanded ? T.Overlay(0.045) : null, T.Overlay(0.08), new Thickness(8, padding, 8, padding));
        hover.MouseEnter += (_, _) =>
        {
            timer.Visibility = start.Visibility = info.Visibility = Visibility.Visible;
            HoverBegan(null, project, hover);
        };
        hover.MouseLeave += (_, _) =>
        {
            timer.Visibility = timing ? Visibility.Visible : Visibility.Collapsed;
            start.Visibility = info.Visibility = Visibility.Collapsed;
            HoverEnded();
        };
        hover.ContextMenu = new ContextMenu();
        hover.ContextMenuOpening += (_, _) => hover.ContextMenu = ProjectMenu(project);
        stack.Children.Add(hover);

        if (expanded)
        {
            var showAll = _showingAll.Contains(project.Key);
            var visible = showAll ? project.Sessions : project.Sessions.Take(Library.ProjectPreviewCount).ToList();
            var repeated = visible.GroupBy(session => session.Title).Where(group => group.Count() > 1).Select(group => group.Key).ToHashSet();
            var sessions = new StackPanel();
            foreach (var session in visible)
            {
                var detail = repeated.Contains(session.Title) ? FirstLine(session.LastPrompt) : "";
                sessions.Children.Add(SessionRow(session, RowKey.Project(session.Id), detail, inset: 16));
            }
            var guide = new Grid();
            guide.Children.Add(new Border { Width = 2, CornerRadius = new CornerRadius(1), Background = T.Overlay(0.12), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(12, 4, 0, 4) });
            guide.Children.Add(sessions);
            stack.Children.Add(guide);
            if (!showAll && project.Sessions.Count > visible.Count)
            {
                stack.Children.Add(Ui.Hover(Ui.Label(L.MoreSessions(project.Sessions.Count - visible.Count), 12, T.Secondary),
                    () => { _showingAll.Add(project.Key); Rebuild(); }, 5, null, Brushes.Transparent, new Thickness(24, 6, 0, 6)));
            }
        }
        return stack;
    }

    private static string FirstLine(string? text) => (text ?? "").Trim().Split('\n', 2)[0].Trim();

    private void ToggleProject(string key) => Library.ChangeSettings(settings =>
    {
        if (!settings.ExpandedProjects.Remove(key)) settings.ExpandedProjects.Add(key);
        else _showingAll.Remove(key);
    }, reload: false);

    private ContextMenu ProjectMenu(ProjectGroup project)
    {
        var timing = Library.IsTiming(project.Key);
        var chosen = Library.Current.ProjectOpenMethods.TryGetValue(project.Key, out var method) ? method : (OpenMethod?)null;
        var openIn = new List<object?> { Ui.Item(L.UseGeneralSetting, () => Library.SetOpenMethod(null, project), check: chosen is null), Ui.Divider() };
        openIn.AddRange(Opener.Installed.Select(choice => (object?)Ui.Item(choice.Title(), () => Library.SetOpenMethod(choice, project), check: chosen == choice)));
        var others = Library.Current.AllProjects.Where(other => other.Key != project.Key).OrderBy(other => other.Name, NaturalComparer.Instance)
            .Select(other => (object?)Ui.Item(other.Name, () => Library.Merge(project, other)));
        return Ui.Menu(
            Ui.Item(L.ProjectPage, () => OpenProjectPage(project.Key)),
            Ui.Item(L.StartChat, () => _host.StartSession(project)),
            Ui.Item(L.AddTask, () => BeginTask(new TaskLink.ToProject(project.Key, project.Name))),
            Ui.Item(timing ? L.StopTimer : L.StartTimer, () => Library.ToggleTimer(project.Key)),
            Ui.Submenu(L.OpenMethodMenu, openIn),
            Ui.Item(L.Rename, () => { _renamingProject = project.Key; Rebuild(); }),
            Ui.Submenu(L.MergeInto, others),
            project.MergedKeys.Count > 0 ? Ui.Item(L.UndoMerge, () => Library.Separate(project)) : null,
            Ui.Divider(),
            Ui.Item(L.Hide, () => Library.Hide(project)),
            project.Folders.FirstOrDefault(Directory) is { } folder ? Ui.Item(L.ShowInFinder, () => Opener.RevealFolder(folder)) : null);
    }

    // MARK: Hover card

    private readonly DispatcherTimer _hoverTimer = new() { Interval = TimeSpan.FromMilliseconds(700) };
    private readonly DispatcherTimer _hoverEndTimer = new() { Interval = TimeSpan.FromMilliseconds(200) };
    private (SessionRecord? Session, ProjectGroup? Project, FrameworkElement Element)? _hoverTarget;
    private bool _cardShown;

    private void HoverBegan(SessionRecord? session, ProjectGroup? project, FrameworkElement element)
    {
        _hoverEndTimer.Stop();
        _hoverTarget = (session, project, element);
        _hoverTimer.Stop();
        _hoverTimer.Interval = TimeSpan.FromMilliseconds(_cardShown ? 50 : 700);
        _hoverTimer.Tick -= ShowHoverCard;
        _hoverTimer.Tick += ShowHoverCard;
        _hoverTimer.Start();
        _hoverEndTimer.Tick -= EndHover;
        _hoverEndTimer.Tick += EndHover;
    }

    private void HoverEnded()
    {
        _hoverTimer.Stop();
        _hoverEndTimer.Stop();
        _hoverEndTimer.Start();
    }

    private void EndHover(object? sender, EventArgs e)
    {
        _hoverEndTimer.Stop();
        _hoverTarget = null;
        _cardShown = false;
        _card.HideCard();
    }

    private void ShowHoverCard(object? sender, EventArgs e)
    {
        _hoverTimer.Stop();
        if (_hoverTarget is not { } target || !IsVisible || !target.Element.IsMouseOver) return;
        var bounds = new Rect(Left + 10, Top + 10, ActualWidth - 20, ActualHeight - 20);
        var mouse = PointToScreen(Mouse.GetPosition(this));
        var source = PresentationSource.FromVisual(this);
        var y = source?.CompositionTarget is { } composition ? composition.TransformFromDevice.Transform(mouse).Y : mouse.Y;
        if (target.Session is { } session) _card.ShowFor(session, bounds, y);
        else if (target.Project is { } project) _card.ShowFor(project, bounds, y);
        _cardShown = true;
    }

    // MARK: Selection and opening

    private SessionRecord? SelectedSession() => _selection is { } key ? Library.Session(RowKey.SessionId(key)) : null;

    private void MoveSelection(int step)
    {
        if (_showingSettings || _outline is not null || _rowKeys.Count == 0) return;
        var index = _selection is null ? -1 : _rowKeys.IndexOf(_selection);
        index = index < 0 ? (step > 0 ? 0 : _rowKeys.Count - 1) : Math.Clamp(index + step, 0, _rowKeys.Count - 1);
        _selection = _rowKeys[index];
        Rebuild();
        if (_rowElements.TryGetValue(_selection, out var element)) element.BringIntoView();
    }

    private void Open(SessionRecord session)
    {
        _card.HideCard();
        _host.Open(session);
    }

    private void ShowOutlineOfSelection()
    {
        if (SelectedSession() is not { } session) return;
        var match = _results?.FirstOrDefault(hit => hit.Session.Id == session.Id)?.MatchRow;
        ShowOutline(session, match);
    }

    private void ShowOutline(SessionRecord session, long? near)
    {
        _card.HideCard();
        var outline = Library.Outline(session, near);
        _outline = outline with { Focus = near is null ? null : outline.Focus };
        _outlineExpanded.Clear();
        Rebuild();
    }

    /// <summary>After a rebuild, the field that asked for the keyboard gets it.</summary>
    private void ApplyFocusRequest()
    {
        if (_focusRequest is not { } wanted) return;
        _focusRequest = null;
        Dispatcher.BeginInvoke(() =>
        {
            var box = FindBox(_body, wanted);
            if (box is null) return;
            box.Focus();
            Keyboard.Focus(box);
            box.CaretIndex = box.Text.Length;
            if (wanted == "rename") box.SelectAll();
            box.BringIntoView();
        }, DispatcherPriority.Input);
    }

    private static TextBox? FindBox(DependencyObject root, string tag)
    {
        if (root is TextBox box && Equals(box.Tag, tag)) return box;
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            if (FindBox(VisualTreeHelper.GetChild(root, index), tag) is { } found) return found;
        }
        if (root is ContentControl { Content: DependencyObject content } && VisualTreeHelper.GetChildrenCount(root) == 0) return FindBox(content, tag);
        return null;
    }
}
