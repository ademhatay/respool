using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Respool.Core;

namespace Respool.Windows;

public sealed partial class PanelWindow
{
    // MARK: To-dos

    private void TodosSection()
    {
        _list.Children.Add(CollapsibleHeader(PanelSection.Todos, Library.OpenListedTaskCount));
        if (IsCollapsed(PanelSection.Todos)) return;
        _list.Children.Add(Calendar());
        var today = Format.Today;
        if (_selectedDay == today && Library.OverdueTasks is { Count: > 0 } overdue)
        {
            _list.Children.Add(GroupTitle(L.Overdue));
            foreach (var task in overdue) _list.Children.Add(TaskRow(task, overdue, showLink: true, listedDay: _selectedDay));
        }
        var due = Library.TasksOn(_selectedDay).OrderBy(task => task.Done).ThenBy(task => task.Rank).ToList();
        foreach (var task in due) _list.Children.Add(TaskRow(task, due, showLink: true, listedDay: _selectedDay));
        var undated = Library.UndatedTasks;
        if (undated.Count > 0)
        {
            _list.Children.Add(GroupTitle(L.NoDate));
            foreach (var task in undated) _list.Children.Add(TaskRow(task, undated, showLink: true, listedDay: null));
        }
        _list.Children.Add(AddTodoRow());
    }

    private FrameworkElement GroupTitle(string title) => Ui.Label(title, 11, T.Secondary, FontWeights.Medium).Margin(8, 6, 8, 1);

    private FrameworkElement AddTodoRow()
    {
        var (view, box) = Ui.Field(L.AddTask, 12, field =>
        {
            Library.AddTodo(field.Text, _selectedDay, _taskLink);
            _taskLink = null;
            _todoDraft = "";
            field.Text = "";
            _focusRequest = "todo";
        }, _todoDraft);
        box.Tag = "todo";
        box.TextChanged += (_, _) => _todoDraft = box.Text;
        var trailing = new List<UIElement>();
        if (_taskLink is { } link)
        {
            var chip = Ui.HStack(4,
                Ui.Icon(link is TaskLink.ToSession ? Theme.Glyph.Chat : Theme.Glyph.Folder, 9, T.Secondary),
                new TextBlock { Text = link.Title, MaxWidth = 120, FontSize = 11, Foreground = T.Secondary, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center },
                Ui.IconButton(Theme.Glyph.Close, () => { _taskLink = null; Rebuild(); }, L.RemoveLink, 7, T.Secondary, 12, 12));
            var capsule = Ui.Capsule(chip, T.Overlay(0.07), 20, 6).Tip(L.TaskLinkHelp(link.Title));
            capsule.Padding = new Thickness(6, 0, 3, 0);
            trailing.Add(capsule);
        }
        trailing.Add(Ui.Label(Format.DayLabel(_selectedDay), 11, T.Tertiary).Tip(L.NewTaskDayHelp));
        return Ui.Row(new UIElement[] { Ui.Icon(Theme.Glyph.Add, 11, T.Tertiary).Margin(0, 0, 0, 0) }, view, trailing).Margin(8, 5);
    }

    /// <summary>A task: a check, its text, what it is linked to and its day; run and delete under the pointer.</summary>
    private FrameworkElement TaskRow(TaskItem task, IReadOnlyList<TaskItem> list, bool showLink, string? listedDay)
    {
        var check = Ui.IconButton(task.Done ? Theme.Glyph.CheckCircle : Theme.Glyph.Circle, () => Library.Toggle(task),
            task.Done ? L.MarkNotDone : L.MarkDone, 14, task.Done ? T.Accent : T.Secondary, 20, 18);
        var text = Ui.Label(task.Text, 12, task.Done ? T.Tertiary : T.Text, lines: 2);
        if (task.Done) text.TextDecorations = TextDecorations.Strikethrough;
        var link = showLink ? Library.LinkOf(task) : null;
        var overdue = !task.Done && task.Due is { } due && string.CompareOrdinal(due, Format.Today) < 0;
        var showDay = task.Due is not null && task.Due != listedDay;
        var middle = new StackPanel();
        middle.Children.Add(text);
        if (link is not null || showDay)
        {
            var detail = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 0) };
            if (link is not null)
            {
                detail.Children.Add(Ui.Icon(link is TaskLink.ToSession ? Theme.Glyph.Chat : Theme.Glyph.Folder, 9, T.Secondary).Margin(0, 0, 4, 0));
                detail.Children.Add(new TextBlock { Text = link.Title, FontSize = 11, Foreground = T.Secondary, MaxWidth = 200, TextTrimming = TextTrimming.CharacterEllipsis });
            }
            if (link is not null && showDay) detail.Children.Add(Ui.Label(" · ", 11, T.Secondary));
            if (showDay) detail.Children.Add(Ui.Label(Format.DayLabel(task.Due!), 11, overdue ? T.Solid(T.Orange) : T.Secondary));
            middle.Children.Add(detail);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Opacity = 0, VerticalAlignment = VerticalAlignment.Top };
        if (link is not null) buttons.Children.Add(Ui.IconButton(Theme.Glyph.Play, () => RunTask(task, link), L.StartTaskInClaude, 9, T.Secondary, 22, 14));
        buttons.Children.Add(Ui.IconButton(Theme.Glyph.Close, () => Library.Delete(task), L.DeleteTask, 9, T.Secondary, 22, 14));
        var row = Ui.Row(new UIElement[] { check }, middle, new UIElement[] { buttons }, 8);
        row.VerticalAlignment = VerticalAlignment.Top;
        var hover = Ui.Hover(row, null, 7, null, Brushes.Transparent, new Thickness(8, 4, 8, 4));
        hover.MouseEnter += (_, _) => buttons.Opacity = 1;
        hover.MouseLeave += (_, _) => buttons.Opacity = 0;
        hover.ContextMenu = new ContextMenu();
        hover.ContextMenuOpening += (_, _) => hover.ContextMenu = TaskMenu(task);

        // Open tasks in a list of two or more can be dragged into a new order.
        var draggable = !task.Done && list.Count(item => !item.Done) >= 2;
        if (draggable)
        {
            var start = new Point();
            hover.PreviewMouseLeftButtonDown += (_, e) => start = e.GetPosition(hover);
            hover.MouseMove += (_, e) =>
            {
                if (e.LeftButton != MouseButtonState.Pressed || (e.GetPosition(hover) - start).Length < 4) return;
                if (e.OriginalSource is DependencyObject source && FindParent<TextBox>(source) is not null) return;
                DragDrop.DoDragDrop(hover, "task:" + task.Id, DragDropEffects.Move);
            };
            hover.AllowDrop = true;
            hover.DragOver += (_, e) =>
            {
                var ok = e.Data.GetData(typeof(string)) is string payload && payload.StartsWith("task:", StringComparison.Ordinal)
                    && long.TryParse(payload[5..], out var id) && id != task.Id && list.Any(item => item.Id == id);
                e.Effects = ok ? DragDropEffects.Move : DragDropEffects.None;
                hover.Background = ok ? T.AccentAt(0.16) : Brushes.Transparent;
                e.Handled = true;
            };
            hover.DragLeave += (_, _) => hover.Background = Brushes.Transparent;
            hover.Drop += (_, e) =>
            {
                hover.Background = Brushes.Transparent;
                if (e.Data.GetData(typeof(string)) is not string payload || !long.TryParse(payload.Replace("task:", ""), out var id)) return;
                if (list.FirstOrDefault(item => item.Id == id) is not { } moved) return;
                Library.MoveTask(moved, list, task, e.GetPosition(hover).Y > hover.ActualHeight / 2);
            };
        }
        return hover;
    }

    private static T2? FindParent<T2>(DependencyObject child) where T2 : DependencyObject
    {
        for (var node = child; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is T2 match) return match;
            if (node is not Visual) break;
        }
        return null;
    }

    private ContextMenu TaskMenu(TaskItem task)
    {
        var today = Format.Today;
        var tomorrow = Format.DayKey(DateTime.Today.AddDays(1));
        var days = new List<object?>
        {
            Ui.Item(L.Today, () => Library.SetDue(task, today), check: task.Due == today),
            Ui.Item(L.Tomorrow, () => Library.SetDue(task, tomorrow), check: task.Due == tomorrow),
        };
        var later = CalendarDays().Select(Format.DayKey).Where(day => string.CompareOrdinal(day, tomorrow) > 0).ToList();
        if (later.Count > 0)
        {
            days.Add(Ui.Divider());
            days.AddRange(later.Select(day => (object?)Ui.Item(Format.DayLabel(day), () => Library.SetDue(task, day), check: task.Due == day)));
        }
        days.Add(Ui.Divider());
        days.Add(Ui.Item(L.NoDate, () => Library.SetDue(task, null), check: task.Due is null));
        var projects = Library.Current.AllProjects.OrderBy(project => project.Name, NaturalComparer.Instance)
            .Select(project => (object?)Ui.Item(project.Name, () => Library.Link(task, project.Key))).ToList();
        if (Library.LinkOf(task) is not null)
        {
            projects.Add(Ui.Divider());
            projects.Add(Ui.Item(L.RemoveLink, () => Library.Link(task, null)));
        }
        return Ui.Menu(Ui.Submenu(L.Date, days), Ui.Submenu(L.LinkToProject, projects), Ui.Divider(), Ui.Item(L.Delete, () => Library.Delete(task)));
    }

    /// <summary>A session task goes on the clipboard and the session opens; a project task starts a chat with it.</summary>
    private void RunTask(TaskItem task, TaskLink link)
    {
        switch (link)
        {
            case TaskLink.ToSession toSession when Library.Session(toSession.Id) is { } session:
                Copy(task.Text);
                ShowNotice(L.TaskCopied);
                Open(session);
                break;
            case TaskLink.ToProject toProject when Library.Current.Project(toProject.Key) is { } project:
                _host.StartSession(project, task.Text);
                break;
        }
    }

    // MARK: Calendar

    private IReadOnlyList<DateTime> CalendarDays()
    {
        if (!Settings.CalendarExpanded)
        {
            var monday = SnapshotBuilder.StartOfWeek(_calendarAnchor);
            return Enumerable.Range(0, 7).Select(offset => monday.AddDays(offset)).ToList();
        }
        var first = new DateTime(_calendarAnchor.Year, _calendarAnchor.Month, 1);
        var start = SnapshotBuilder.StartOfWeek(first);
        var end = SnapshotBuilder.StartOfWeek(first.AddMonths(1).AddDays(-1)).AddDays(7);
        var days = new List<DateTime>();
        for (var day = start; day < end; day = day.AddDays(1)) days.Add(day);
        return days;
    }

    private void ShiftCalendar(int step)
    {
        var month = Settings.CalendarExpanded;
        _calendarAnchor = month ? _calendarAnchor.AddMonths(step) : _calendarAnchor.AddDays(7 * step);
        if (Format.FromDayKey(_selectedDay) is { } selected)
            _selectedDay = Format.DayKey(month ? selected.AddMonths(step) : selected.AddDays(7 * step));
        Rebuild();
    }

    private FrameworkElement Calendar()
    {
        var days = CalendarDays();
        var month = Settings.CalendarExpanded;
        var title = month ? Format.Month(_calendarAnchor) : Format.CalendarTitle(days[0], days[^1]);
        var todayButton = Ui.Hover(Ui.Label(L.Today, 11, T.Secondary, FontWeights.Medium), () =>
        {
            _calendarAnchor = DateTime.Today;
            _selectedDay = Format.Today;
            Rebuild();
        }, 5, null, null, new Thickness(7, 3, 7, 3)).Tip(L.BackToToday);
        todayButton.Opacity = _selectedDay == Format.Today ? 0.5 : 1;
        var header = Ui.Row(
            new UIElement[]
            {
                Ui.IconButton(Theme.Glyph.ChevronLeft, () => ShiftCalendar(-1), month ? L.PreviousMonth : L.PreviousWeek, 10, T.Secondary, 22, 22),
                Ui.Hover(Ui.Label(title, 12, T.Text, FontWeights.SemiBold), () =>
                    Library.ChangeSettings(settings => settings.CalendarExpanded = !settings.CalendarExpanded, reload: false), 5, null, null, new Thickness(7, 2, 7, 2))
                    .Tip(month ? L.WeekView : L.MonthView),
                Ui.IconButton(Theme.Glyph.ChevronRight, () => ShiftCalendar(1), month ? L.NextMonth : L.NextWeek, 10, T.Secondary, 22, 22),
            },
            null,
            new UIElement[] { todayButton }, 2);

        var weekdays = new UniformGrid { Columns = 7, Margin = new Thickness(0, 3, 0, 0) };
        foreach (var day in days.Take(7))
        {
            var name = Ui.Label(Format.Weekday(day), 10, T.Tertiary);
            name.HorizontalAlignment = HorizontalAlignment.Center;
            weekdays.Children.Add(name);
        }
        var grid = new UniformGrid { Columns = 7 };
        var today = Format.Today;
        foreach (var day in days)
        {
            var key = Format.DayKey(day);
            var isToday = key == today;
            var selected = key == _selectedDay;
            var inMonth = !month || day.Month == _calendarAnchor.Month;
            var numberBrush = isToday ? (selected ? T.White : T.Accent) : inMonth ? T.Text : T.Secondary;
            var number = Ui.Label(day.Day.ToString(), 12, numberBrush, isToday || selected ? FontWeights.SemiBold : FontWeights.Normal);
            number.HorizontalAlignment = HorizontalAlignment.Center;
            var circle = new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Child = number,
                Background = selected ? (isToday ? T.Accent : T.Overlay(0.14)) : Brushes.Transparent,
                BorderBrush = T.Accent,
                BorderThickness = new Thickness(isToday && !selected ? 1.5 : 0),
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            var dot = Ui.Dot(4, Library.OpenTaskCount(key) > 0 ? T.Accent : Brushes.Transparent);
            dot.HorizontalAlignment = HorizontalAlignment.Center;
            var cell = Ui.Hover(Ui.VStack(3, circle, dot), () => { _selectedDay = key; Rebuild(); }, 6, null, selected ? Brushes.Transparent : T.Overlay(0.06));
            cell.Height = 31;
            cell.ToolTip = Format.Day(day);
            grid.Children.Add(cell);
        }
        return Ui.VStack(3, header, weekdays, grid).Margin(8, 2, 8, 6);
    }

    // MARK: Notes

    private void NotesSection()
    {
        var notes = Library.Current.Notes;
        _list.Children.Add(CollapsibleHeader(PanelSection.Notes, notes.Count));
        if (IsCollapsed(PanelSection.Notes)) return;
        var (view, box) = Ui.Field(L.NotePlaceholder, 12, field =>
        {
            Library.AddNote(field.Text);
            _noteDraft = "";
            field.Text = "";
            _focusRequest = "note";
        }, _noteDraft);
        box.Tag = "note";
        box.TextChanged += (_, _) => _noteDraft = box.Text;
        _list.Children.Add(Ui.Row(new UIElement[] { Ui.Icon(Theme.Glyph.Note, 11, T.Tertiary) }, view, Array.Empty<UIElement>()).Margin(8, 5));
        foreach (var note in notes)
        {
            var expanded = _expandedNotes.Contains(note.Id);
            var text = Ui.Label(note.Text, 12, T.Text, lines: expanded ? 0 : 3);
            var stack = Ui.VStack(2, text, note.Created is { } created ? Ui.Label(Format.ShortDate(created), 10, T.Tertiary) : null);
            var delete = Ui.IconButton(Theme.Glyph.Close, () => Library.Delete(note), L.DeleteNote, 9, T.Secondary, 22, 14);
            delete.Opacity = 0;
            delete.VerticalAlignment = VerticalAlignment.Top;
            var id = note.Id;
            var hover = Ui.Hover(Ui.Row(Array.Empty<UIElement>(), stack, new UIElement[] { delete }), () =>
            {
                if (!_expandedNotes.Remove(id)) _expandedNotes.Add(id);
                Rebuild();
            }, 7, null, null, new Thickness(8, 5, 8, 5));
            hover.MouseEnter += (_, _) => delete.Opacity = 1;
            hover.MouseLeave += (_, _) => delete.Opacity = 0;
            hover.ContextMenu = Ui.Menu(
                Ui.Item(L.Copy, () => { Copy(note.Text); ShowNotice(L.NoteCopied); }),
                Ui.Item(L.TurnIntoTask, () => Library.MakeTask(note, _selectedDay)),
                Ui.Divider(),
                Ui.Item(L.DeleteNote, () => Library.Delete(note)));
            _list.Children.Add(hover);
        }
    }

    // MARK: The day's summary

    private FrameworkElement DayEndCard()
    {
        var figures = Library.DaySummaryFigures;
        var indigo = T.Indigo;
        var header = Ui.Row(
            new UIElement[] { Ui.Icon(Theme.Glyph.Moon, 12, T.Solid(indigo)), Ui.Label(L.DayEndTitle, 13, T.Text, FontWeights.SemiBold) },
            null,
            new UIElement[]
            {
                Ui.IconButton(Theme.Glyph.Copy, () => { Copy(Library.DaySummaryText); ShowNotice(L.SummaryCopied); }, L.CopySummary, 11, T.Secondary, 22, 20),
                Ui.IconButton(Theme.Glyph.Close, () => { Library.DismissDayEndCard(); Rebuild(); }, L.HideForToday, 10, T.Secondary, 22, 20),
            });
        var tiles = Ui.Tiles(Ui.StatTile(Format.Worked(figures.Worked), L.Worked), Ui.StatTile(L.Count(figures.Chats), L.Chats), Ui.StatTile(L.Count(figures.Prompts), L.PromptsLabel));
        var projects = new StackPanel();
        var peak = figures.Projects.Count == 0 ? 1 : Math.Max(1, figures.Projects.Max(row => row.Total));
        foreach (var row in figures.Projects.Take(4))
        {
            var color = T.TimeColor(row.Color);
            var bar = new Border { Height = 5, CornerRadius = new CornerRadius(2.5), Background = T.Solid(color, 0.75), HorizontalAlignment = HorizontalAlignment.Left };
            var track = new Grid();
            track.Children.Add(bar);
            track.SizeChanged += (_, _) => bar.Width = Math.Max(4, track.ActualWidth * row.Total / peak);
            var name = Ui.Label(row.Name, 12);
            name.Width = 110;
            var length = Ui.Label(Format.Worked(row.Total), 11, T.Secondary);
            length.Width = 70;
            length.TextAlignment = TextAlignment.Right;
            projects.Children.Add(Ui.Row(new UIElement[] { Ui.Dot(7, T.Solid(color)), name }, track, new UIElement[] { length }).Margin(0, 0, 0, 7));
        }
        var gradient = new LinearGradientBrush(Color.FromArgb(36, indigo.R, indigo.G, indigo.B), Color.FromArgb(13, indigo.R, indigo.G, indigo.B), new Point(0, 0), new Point(1, 1));
        return new Border
        {
            Child = Ui.VStack(12, header, tiles, projects.Children.Count > 0 ? projects : null),
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(12),
            Background = gradient,
            BorderBrush = T.Solid(indigo, 0.18),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 12, 0, 0),
        };
    }
}
