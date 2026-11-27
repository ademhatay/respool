using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Respool.Core;

namespace Respool.Windows;

public sealed partial class PanelWindow
{
    private readonly HashSet<long> _outlineExpanded = new();

    /// <summary>A header with a back button, for the sub-pages.</summary>
    private FrameworkElement BackButton(Action back) =>
        Ui.IconButton(Theme.Glyph.ChevronLeft, back, L.Back, 12, T.Secondary, 24, 24);

    private Grid Page(FrameworkElement header, FrameworkElement body)
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(header, 0);
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false };
        Grid.SetRow(scroll, 1);
        grid.Children.Add(header);
        grid.Children.Add(scroll);
        DragArea(header);
        return grid;
    }

    // MARK: Prompt outline

    private FrameworkElement OutlinePage(SessionOutline outline)
    {
        var session = outline.Session;
        var titles = Ui.VStack(2, Ui.Label(session.Title, 14, T.Text, FontWeights.SemiBold, lines: 2), Ui.Label(L.PromptsLine(session.PlaceLabel, outline.Entries.Count), 11, T.Secondary));
        var header = Ui.Row(new UIElement[] { BackButton(() => { _outline = null; Rebuild(); FocusSearch(); }) }, titles,
            new UIElement[] { Ui.SmallButton(L.Open, () => Open(session), L.OpenChat) }, 6);
        header.Margin = new Thickness(12, 14, 12, 4);
        header.Background = Brushes.Transparent;
        foreach (UIElement child in header.Children) if (child is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Top;

        var body = new StackPanel { Margin = new Thickness(10, 0, 10, 12) };
        FrameworkElement? marked = null;
        if (outline.Entries.Count == 0)
        {
            body.Children.Add(Centered(Ui.Label(L.OutlineEmpty, 12, T.Secondary, lines: 0)).Margin(0, 48, 0, 0));
        }
        foreach (var group in outline.Entries.GroupBy(entry => entry.Date?.LocalDateTime.Date))
        {
            body.Children.Add(SectionHeader(group.Key is { } day ? Format.Day(day) : L.NoDate));
            foreach (var entry in group)
            {
                var isMarked = outline.Focus == entry.Id;
                var expanded = isMarked || _outlineExpanded.Contains(entry.Id);
                var time = Ui.Label(Format.TimeOfDay(entry.Date), 11, T.Tertiary);
                time.Width = 34;
                time.VerticalAlignment = VerticalAlignment.Top;
                var text = Ui.Label(entry.Text, 12, T.Text, lines: expanded ? 0 : 3);
                var id = entry.Id;
                var row = Ui.Hover(Ui.Row(new UIElement[] { time }, text, Array.Empty<UIElement>(), 10), () =>
                {
                    if (!_outlineExpanded.Remove(id)) _outlineExpanded.Add(id);
                    Rebuild();
                }, 7, isMarked ? T.AccentAt(0.16) : null, null, new Thickness(8, 6, 8, 6));
                row.ContextMenu = Ui.Menu(Ui.Item(L.Copy, () => { Copy(entry.Text); ShowNotice(L.PromptCopied); }));
                row.Margin = new Thickness(0, 0, 0, 1);
                if (isMarked) marked = row;
                body.Children.Add(row);
            }
        }
        var page = Page(header, body);
        if (marked is not null)
        {
            var target = marked;
            target.Loaded += (_, _) => target.BringIntoView(new Rect(0, -120, target.ActualWidth, target.ActualHeight + 240));
        }
        return page;
    }

    // MARK: Project page

    private FrameworkElement ProjectPage(ProjectGroup project, double offset)
    {
        var timing = Library.IsTiming(project.Key);
        var name = Ui.HStack(6, Ui.Icon(Theme.Glyph.FolderOpen, 12, T.Accent), Ui.Label(project.Name, 15, T.Text, FontWeights.SemiBold));
        var titles = Ui.VStack(2, name, Ui.Label(L.LastActivity(Format.Date(project.LastActivity)), 11, T.Secondary));
        var timer = new Border
        {
            Child = Ui.Icon(timing ? Theme.Glyph.Stop : Theme.Glyph.Play, 9, timing ? T.Accent : T.Text),
            Width = 28, Height = 20, CornerRadius = new CornerRadius(5), Background = T.Overlay(0.09), Cursor = System.Windows.Input.Cursors.Hand,
        }.Tip(timing ? L.StopTimer : L.StartTimer);
        timer.MouseLeftButtonUp += (_, _) => Library.ToggleTimer(project.Key);
        var header = Ui.Row(
            new UIElement[] { BackButton(() => { _projectPage = null; Rebuild(); FocusSearch(); }) },
            titles,
            new UIElement[] { timer, Ui.SmallButton(L.NewChat, () => _host.StartSession(project), L.StartChatHere) }, 6);
        header.Margin = new Thickness(12, 14, 12, 6);
        header.Background = Brushes.Transparent;

        var body = new StackPanel { Margin = new Thickness(10, 0, 10, 12) };
        string Worked(TimePeriod period) => Library.TimeFor(project.Key, period) is var seconds and >= 60 ? Format.Worked(seconds) : "—";
        body.Children.Add(Ui.Tiles(Ui.StatTile(Worked(TimePeriod.Today), L.Today), Ui.StatTile(Worked(TimePeriod.Week), L.WeekTitle), Ui.StatTile(Worked(TimePeriod.Month), L.ThisMonth)).Margin(2, 4, 2, 0));

        var chosen = Library.Current.ProjectOpenMethods.TryGetValue(project.Key, out var method) ? method : (OpenMethod?)null;
        var installed = Opener.Installed;
        var titlesList = new[] { L.UseGeneralSetting }.Concat(installed.Select(choice => choice.Title())).ToList();
        var selected = chosen is { } value ? installed.ToList().IndexOf(value) + 1 : 0;
        var popup = Ui.Popup(titlesList, selected, index => Library.SetOpenMethod(index == 0 ? null : installed[index - 1], project));
        var setting = Ui.Row(new UIElement[] { Ui.Label(L.OpenMethodMenu, 13) }, null, new UIElement[] { popup });
        body.Children.Add(new Border { Child = setting, Padding = new Thickness(12, 0, 12, 0), Height = 40, CornerRadius = new CornerRadius(9), Background = T.Overlay(0.06), Margin = new Thickness(0, 10, 0, 0) });

        var tasks = Library.TasksOf(project);
        if (tasks.Count > 0)
        {
            body.Children.Add(SectionHeader(L.TodosTitle));
            foreach (var task in tasks) body.Children.Add(TaskRow(task, tasks, showLink: true, listedDay: Format.Today));
        }
        body.Children.Add(SectionHeader(L.Sessions(project.Sessions.Count)));
        foreach (var session in project.Sessions) body.Children.Add(SessionRow(session, RowKey.Page(session.Id), FirstLine(session.LastPrompt)));
        if (project.Folders.Count > 0)
        {
            body.Children.Add(SectionHeader(L.Folders(project.Folders.Count)));
            foreach (var folder in project.Folders)
            {
                var label = new TextBlock { Text = Format.FolderPath(folder), FontSize = 12, Foreground = T.Text, TextTrimming = TextTrimming.CharacterEllipsis };
                body.Children.Add(Ui.Hover(Ui.Row(new UIElement[] { Ui.Icon(Theme.Glyph.Folder, 11, T.Tertiary) }, label, Array.Empty<UIElement>(), 7),
                    () => Opener.RevealFolder(folder), 7, null, null, new Thickness(8, 5, 8, 5)).Tip(L.ShowInFinder));
            }
        }
        var page = Page(header, body);
        if (page.Children[1] is ScrollViewer scroll) scroll.Loaded += (_, _) => scroll.ScrollToVerticalOffset(offset);
        return page;
    }
}
