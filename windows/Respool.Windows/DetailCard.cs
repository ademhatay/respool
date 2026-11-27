using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Respool.Core;

namespace Respool.Windows;

/// <summary>
/// The card beside the panel with a chat's or a project's figures. It never takes focus and lets
/// the pointer through; the panel decides when it shows.
/// </summary>
public sealed class DetailCard : Window
{
    private const double CardWidth = 320;
    private const double ContentWidth = CardWidth - 32;
    private const double ShadowMargin = 14;
    private const double Gap = 8;

    private readonly IAppHost _host;
    private int _generation;
    private Rect _panel;
    private double _screenY;

    public DetailCard(IAppHost host)
    {
        _host = host;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        Topmost = true;
        Width = CardWidth + ShadowMargin * 2;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Title = "Respool";
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = GetWindowLong(handle, ExStyle);
            SetWindowLong(handle, ExStyle, style | NoActivate | Transparent | ToolWindow);
        };
        SizeChanged += (_, _) => { if (IsVisible) Place(); };
    }

    // MARK: Showing

    /// <summary>Shows a chat's card beside the panel, centered on <paramref name="screenY"/>; both in WPF units.</summary>
    public void ShowFor(SessionRecord session, Rect panelBounds, double screenY)
    {
        var generation = ++_generation;
        var (content, fill) = SessionContent(session);
        Present(content, panelBounds, screenY);
        var library = _host.Library;
        Load(() => library.Activity(session), generation, fill);
    }

    /// <summary>Shows a project's card beside the panel, centered on <paramref name="screenY"/>; both in WPF units.</summary>
    public void ShowFor(ProjectGroup project, Rect panelBounds, double screenY)
    {
        var generation = ++_generation;
        var (content, fill) = ProjectContent(project);
        Present(content, panelBounds, screenY);
        var library = _host.Library;
        Load(() => library.Activity(project), generation, fill);
    }

    public void HideCard()
    {
        _generation++;
        if (!IsVisible) return;
        BeginAnimation(OpacityProperty, null);
        Hide();
    }

    private void Present(UIElement content, Rect panelBounds, double screenY)
    {
        _panel = panelBounds;
        _screenY = screenY;
        var body = new Border { Padding = new Thickness(16), Child = content };
        Content = Sheets.Make(body, 14, ShadowMargin, CardWidth);
        Place();
        if (IsVisible) return;
        Opacity = 0;
        Show();
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.12)));
    }

    /// <summary>Left of the panel when the screen has room there, else right; centered on the pointer, inside the work area.</summary>
    private void Place()
    {
        if (Content is not FrameworkElement sheet) return;
        sheet.Measure(new Size(CardWidth + ShadowMargin * 2, double.PositiveInfinity));
        var height = Math.Max(sheet.DesiredSize.Height - ShadowMargin * 2, 0);
        var area = WorkAreas.Containing(new Point(_panel.Left + _panel.Width / 2, _panel.Top + _panel.Height / 2));
        var left = _panel.Left - Gap - CardWidth >= area.Left ? _panel.Left - Gap - CardWidth : _panel.Right + Gap;
        var top = _screenY - height / 2;
        top = Math.Max(area.Top + 8, Math.Min(top, area.Bottom - 8 - height));
        Left = left - ShadowMargin;
        Top = top - ShadowMargin;
    }

    private void Load(Func<ActivitySeries> read, int generation, Action<ActivitySeries> fill)
    {
        Task.Run(read).ContinueWith(task =>
        {
            if (!task.IsCompletedSuccessfully) return;
            var series = task.Result;
            Dispatcher.BeginInvoke(() =>
            {
                // The card has moved on to something else since.
                if (generation != _generation) return;
                fill(series);
            });
        }, TaskScheduler.Default);
    }

    // MARK: Session

    private (UIElement Content, Action<ActivitySeries> Fill) SessionContent(SessionRecord session)
    {
        var t = Ui.T;
        var library = _host.Library;
        var blocks = new List<UIElement?>();

        // Title, place, live state, tags.
        var header = new List<UIElement?> { Ui.Label(session.Title, 14, t.Text, FontWeights.SemiBold, lines: 2) };
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(Ui.Label(session.PlaceLabel, 11, t.Secondary));
        if (library.Live.TryGetValue(session.Id, out var live))
        {
            line.Children.Add(Ui.Label(" · ", 11, t.Secondary));
            var mark = Ui.LiveMark(live.State, library.AttentionSet.Contains(session.Id), false);
            mark.Margin = new Thickness(0, 0, 5, 0);
            line.Children.Add(mark);
            var state = live.State switch { LiveState.Working => L.Working, LiveState.Waiting => L.Waiting, _ => L.Idle };
            line.Children.Add(Ui.Label(state + (live.IsInTerminal ? L.InTerminal : L.InClaude), 11, t.Secondary));
        }
        header.Add(line);
        var tags = library.TagsOf(session);
        if (tags.Count > 0)
        {
            var row = new WrapPanel { Margin = new Thickness(0, 1, 0, 0) };
            foreach (var tag in tags)
            {
                var item = Ui.HStack(4, Ui.TagMark(tag.Color), Ui.Label(tag.Name, 11, t.Secondary));
                item.Margin = new Thickness(0, 0, 10, 0);
                row.Children.Add(item);
            }
            header.Add(row);
        }
        blocks.Add(Ui.VStack(5, header.ToArray()));

        // Context.
        if (session.ContextTokens is { } context && context > 0) blocks.Add(ContextGauge(context));

        // Prompts, worked, size.
        var worked = Ui.StatTile("—", L.Worked);
        blocks.Add(Ui.Tiles(Ui.StatTile(L.Count(session.MessageCount), L.PromptsLabel), worked, Ui.StatTile(Format.Bytes(session.FileSize), L.Size)));

        blocks.Add(Section(L.Tokens, TokenTiles(session.InputTokens, session.CachedTokens, session.OutputTokens)));

        // Activity across the chat's life.
        var chart = new Border { Child = Ui.ActivityChart(new int[Library.ActivityBuckets]) };
        var first = Ui.Label("—", 10, t.Tertiary);
        var last = Ui.Label("", 10, t.Tertiary);
        var labels = Ui.Row(new UIElement?[] { first }, null, new UIElement?[] { last });
        blocks.Add(Section(L.Activity, Ui.VStack(4, chart, labels)));

        // Facts.
        var facts = new List<UIElement?>();
        if (!string.IsNullOrEmpty(session.Model)) facts.Add(Fact(Theme.Glyph.Processor, session.Model!));
        if (!string.IsNullOrEmpty(session.Branch) && session.Branch != "HEAD") facts.Add(Fact(Theme.Glyph.Branch, session.Branch!));
        if (session.PrNumber is { } pr) facts.Add(Fact(Theme.Glyph.PullRequest, $"Pull request #{pr}"));
        if (session.Cwd.Length > 0) facts.Add(Fact(Theme.Glyph.Folder, Format.FolderPath(session.Cwd)));
        if (facts.Count > 0) blocks.Add(Ui.VStack(5, facts.ToArray()));

        // The last prompt.
        var prompt = session.LastPrompt?.Trim();
        if (!string.IsNullOrEmpty(prompt))
        {
            var text = Ui.Label(prompt!, 11, t.Secondary, lines: 3);
            text.TextTrimming = TextTrimming.WordEllipsis;
            var bar = new Border { Width = 2, CornerRadius = new CornerRadius(1), Background = t.Overlay(0.18), HorizontalAlignment = HorizontalAlignment.Left };
            var quote = new Grid();
            quote.Children.Add(bar);
            text.Margin = new Thickness(9, 0, 0, 0);
            quote.Children.Add(text);
            blocks.Add(quote);
        }

        void Fill(ActivitySeries series)
        {
            Figure(worked).Text = series.Worked is { } seconds && seconds > 0 ? Format.Worked(seconds) : "—";
            chart.Child = Ui.ActivityChart(series.Buckets);
            first.Text = series.StartLabel.Length > 0 ? series.StartLabel : "—";
            last.Text = series.EndLabel;
        }
        return (Ui.VStack(14, blocks.ToArray()), Fill);
    }

    private static UIElement ContextGauge(long tokens)
    {
        var t = Ui.T;
        const double million = 1_000_000;
        var fraction = Math.Min(tokens / million, 1);
        var header = Ui.Row(
            new UIElement?[] { Ui.Label(L.Context, 11, t.Secondary, FontWeights.SemiBold) },
            null,
            new UIElement?[] { Ui.Label($"{Format.Tokens(tokens)} {L.TokenWord}", 12, t.Text, FontWeights.SemiBold) });

        var bar = new Canvas { Width = ContentWidth, Height = 10, ClipToBounds = false };
        var track = new Border { Width = ContentWidth, Height = 6, CornerRadius = new CornerRadius(3), Background = t.Overlay(0.10) };
        Canvas.SetTop(track, 2);
        var fill = new Border
        {
            Width = Math.Max(6, ContentWidth * fraction),
            Height = 6,
            CornerRadius = new CornerRadius(3),
            Background = fraction > 0.8 ? t.Solid(t.Orange) : t.Accent,
        };
        Canvas.SetTop(fill, 2);
        var tick = new Border { Width = 1.5, Height = 10, Background = t.Overlay(0.45) };
        Canvas.SetLeft(tick, ContentWidth * 0.2 - 0.75);
        bar.Children.Add(track);
        bar.Children.Add(fill);
        bar.Children.Add(tick);

        var scale = new Canvas { Width = ContentWidth, Height = 11 };
        var low = Ui.Label("200K", 9, t.Tertiary);
        Canvas.SetLeft(low, ContentWidth * 0.2 - 11);
        var high = Ui.Label("1M", 9, t.Tertiary);
        high.Width = 30;
        high.TextAlignment = TextAlignment.Right;
        Canvas.SetLeft(high, ContentWidth - 30);
        scale.Children.Add(low);
        scale.Children.Add(high);

        return Ui.VStack(6, header, Ui.VStack(3, bar, scale));
    }

    // MARK: Project

    private (UIElement Content, Action<ActivitySeries> Fill) ProjectContent(ProjectGroup project)
    {
        var t = Ui.T;
        var library = _host.Library;
        var blocks = new List<UIElement?>
        {
            Ui.VStack(5,
                Ui.Label(project.Name, 14, t.Text, FontWeights.SemiBold, lines: 2),
                Ui.Label(L.LastActivity(Format.Date(project.LastActivity)), 11, t.Secondary)),
            Ui.Tiles(
                Ui.StatTile(L.Count(project.Sessions.Count), L.Chats),
                Ui.StatTile(L.Count(project.Sessions.Sum(session => (long)session.MessageCount)), L.PromptsLabel),
                Ui.StatTile(Format.Bytes(project.Sessions.Sum(session => session.FileSize)), L.Size)),
            Section(L.Tokens, TokenTiles(
                project.Sessions.Sum(session => session.InputTokens),
                project.Sessions.Sum(session => session.CachedTokens),
                project.Sessions.Sum(session => session.OutputTokens))),
        };

        string Time(double seconds) => seconds > 0 ? Format.Worked(seconds) : "—";
        var total = Ui.StatTile("—", L.TotalTime);
        blocks.Add(Section(L.TimeTitle, Ui.Tiles(
            Ui.StatTile(Time(library.TimeFor(project.Key, TimePeriod.Today)), L.Today),
            Ui.StatTile(Time(library.TimeFor(project.Key, TimePeriod.Week)), L.WeekTitle),
            total)));

        var chart = new Border { Child = Ui.ActivityChart(new int[Library.ActivityBuckets]) };
        var labels = Ui.Row(
            new UIElement?[] { Ui.Label(L.DaysAgo(30), 10, t.Tertiary) },
            null,
            new UIElement?[] { Ui.Label(L.Today.ToLower(L.Culture), 10, t.Tertiary) });
        blocks.Add(Section(L.Last30Days, Ui.VStack(4, chart, labels)));

        var folders = project.Folders.Take(5).Select(folder => (UIElement?)Fact(Theme.Glyph.Folder, Format.FolderPath(folder))).ToList();
        if (project.Folders.Count > 5)
        {
            var more = Ui.Label(L.MoreFolders(project.Folders.Count - 5), 11, t.Tertiary);
            more.Margin = new Thickness(20, 0, 0, 0);
            folders.Add(more);
        }
        if (folders.Count > 0) blocks.Add(Ui.VStack(5, folders.ToArray()));

        void Fill(ActivitySeries series)
        {
            Figure(total).Text = Time(series.Worked ?? 0);
            chart.Child = Ui.ActivityChart(series.Buckets);
        }
        return (Ui.VStack(14, blocks.ToArray()), Fill);
    }

    // MARK: Pieces

    private static UIElement TokenTiles(long input, long cached, long output) => Ui.Tiles(
        Ui.StatTile(Format.Tokens(input), L.Input),
        Ui.StatTile(Format.Tokens(cached), L.Cache),
        Ui.StatTile(Format.Tokens(output), L.Output));

    private static StackPanel Section(string title, UIElement content) =>
        Ui.VStack(6, Ui.Label(title, 11, Ui.T.Secondary, FontWeights.SemiBold), content);

    private static Grid Fact(string glyph, string text)
    {
        var icon = Ui.Icon(glyph, 10, Ui.T.Tertiary);
        icon.Width = 13;
        icon.FontWeight = FontWeights.Medium;
        return Ui.Row(new UIElement?[] { icon }, Ui.Label(MiddleTruncated(text, 52), 11, Ui.T.Text), Array.Empty<UIElement?>(), spacing: 6);
    }

    /// <summary>Long paths keep their start and their end.</summary>
    private static string MiddleTruncated(string text, int limit)
    {
        if (text.Length <= limit) return text;
        var head = (limit - 1) / 2;
        var tail = limit - 1 - head;
        return text[..head] + "…" + text[^tail..];
    }

    /// <summary>The figure of a tile from <see cref="Ui.StatTile"/>.</summary>
    private static TextBlock Figure(Border tile) => (TextBlock)((StackPanel)tile.Child).Children[0];

    // MARK: Win32

    private const int ExStyle = -20;
    private const int Transparent = 0x20;
    private const int ToolWindow = 0x80;
    private const int NoActivate = 0x08000000;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr handle, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLong(IntPtr handle, int index, int value);
}
