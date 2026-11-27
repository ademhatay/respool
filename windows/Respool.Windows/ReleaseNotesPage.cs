using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using Respool.Core;

namespace Respool.Windows;

/// <summary>
/// The release notes sub-page: one card per published release, newest first. It also keeps the
/// update check's state, which Settings shows too.
/// </summary>
public sealed class ReleaseNotesPage
{
    public const string Checking = "checking";
    public const string Failed = "failed";

    /// <summary>The releases fetched last, newest first; null until a check succeeds.</summary>
    public static IReadOnlyList<Release>? Releases { get; set; }

    /// <summary><see cref="Checking"/> while a check runs, <see cref="Failed"/> for 11 s after one failed, else null.</summary>
    public static string? CheckState { get; set; }

    /// <summary>Raised on the UI thread when a check starts or ends, so the pages can redraw.</summary>
    public static event Action? Updated;

    private static DispatcherTimer? _failureTimer;

    /// <summary>The newest release when it is newer than the installed one.</summary>
    public static Release? Available => Updates.Available(Releases);

    /// <summary>
    /// Fetches the releases, unless a check is already running. Saves the time of the check.
    /// Call on the UI thread.
    /// </summary>
    public static async Task CheckAsync(Library library)
    {
        if (CheckState == Checking) return;
        _failureTimer?.Stop();
        CheckState = Checking;
        Updated?.Invoke();
        var releases = await Updates.FetchAsync();
        if (releases is null)
        {
            CheckState = Failed;
            _failureTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(11) };
            _failureTimer.Tick += (_, _) =>
            {
                _failureTimer?.Stop();
                if (CheckState != Failed) return;
                CheckState = null;
                Updated?.Invoke();
            };
            _failureTimer.Start();
        }
        else
        {
            Releases = releases;
            CheckState = null;
            library.ChangeSettings(settings => settings.LastUpdateCheck = Time.Seconds(DateTimeOffset.Now), reload: false);
        }
        Updated?.Invoke();
    }

    /// <summary>The daily check, when it is turned on and the last one is a day old.</summary>
    public static Task CheckIfDue(Library library)
    {
        var settings = library.Settings;
        if (!settings.ChecksForUpdates) return Task.CompletedTask;
        if (Time.Seconds(DateTimeOffset.Now) - settings.LastUpdateCheck < 24 * 3600 && Releases is not null) return Task.CompletedTask;
        return CheckAsync(library);
    }

    private readonly IAppHost _host;
    private readonly ScrollViewer _scroll;
    private readonly Grid _root;

    public FrameworkElement View => _root;

    public ReleaseNotesPage(IAppHost host, Action back)
    {
        _host = host;
        _scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        _root = new Grid();
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = SubPageHeader.Make(L.ReleaseNotes, back);
        _root.Children.Add(header);
        Grid.SetRow(_scroll, 1);
        _root.Children.Add(_scroll);
        Updated += Rebuild;
        _root.IsVisibleChanged += (_, e) =>
        {
            if (e.NewValue is true) OpenedNow();
        };
        Rebuild();
    }

    /// <summary>Opening the page checks when nothing is loaded yet.</summary>
    private void OpenedNow()
    {
        if (Releases is null && CheckState is null) _ = CheckAsync(_host.Library);
    }

    public void Rebuild()
    {
        var offset = _scroll.VerticalOffset;
        var stack = new StackPanel { Margin = new Thickness(12, 0, 12, 16) };
        var releases = Releases;
        if (releases is null || releases.Count == 0)
        {
            var text = CheckState == Checking ? L.Checking
                : CheckState == Failed ? L.CheckFailed
                : releases is null ? L.Checking
                : L.NoReleases;
            var empty = Ui.Label(text, 12, Ui.T.Secondary);
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Margin = new Thickness(0, 48, 0, 0);
            stack.Children.Add(empty);
        }
        else
        {
            var available = Available;
            var first = true;
            foreach (var release in releases)
            {
                var card = Card(release, available is not null && Updates.IsNewer(release.Version, Updates.Installed));
                if (!first) card.Margin = new Thickness(0, 10, 0, 0);
                stack.Children.Add(card);
                first = false;
            }
        }
        _scroll.Content = stack;
        _scroll.ScrollToVerticalOffset(offset);
    }

    private static Border Card(Release release, bool isNew)
    {
        var version = Ui.Label(release.Version, 13, Ui.T.Text, FontWeights.SemiBold);
        FrameworkElement? badge = null;
        if (isNew) badge = Badge(L.NewBadge, Ui.T.AccentColor);
        else if (release.Version == Updates.Installed) badge = Badge(L.InstalledBadge, ((SolidColorBrush)Ui.T.Secondary).Color);
        var date = release.Date is { } when ? Ui.Label(Format.ReleaseDate(when), 11, Ui.T.Tertiary) : null;
        var header = Ui.Row(new UIElement?[] { version, badge }, null, new UIElement?[] { date }, 6);

        var body = Ui.VStack(8, header);
        foreach (var line in Lines(release.Notes)) body.Children.Add(Spaced(line, 8));
        if (isNew)
        {
            var button = Ui.SmallButton(L.OpenOnGitHub, () => OpenUrl(release.Url));
            button.HorizontalAlignment = HorizontalAlignment.Left;
            body.Children.Add(Spaced(button, 8));
        }
        return Ui.Box(body, Ui.T.Overlay(0.06), 9, new Thickness(12));
    }

    private static FrameworkElement Spaced(FrameworkElement element, double top)
    {
        var margin = element.Margin;
        element.Margin = new Thickness(margin.Left, margin.Top + top, margin.Right, margin.Bottom);
        return element;
    }

    private static Border Badge(string text, Color color)
    {
        var label = Ui.Label(text, 10, Ui.T.Solid(color), FontWeights.Medium);
        return Ui.Capsule(label, Ui.T.Solid(color, 0.14), 16, 6);
    }

    /// <summary>The notes line by line: bullets, headings and paragraphs; blank lines go.</summary>
    private static IEnumerable<FrameworkElement> Lines(string notes)
    {
        foreach (var raw in notes.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("- ") || line.StartsWith("* "))
            {
                var dot = Ui.Label("•", 12, Ui.T.Tertiary);
                dot.VerticalAlignment = VerticalAlignment.Top;
                var text = Inline(line[2..].Trim(), FontWeights.Normal);
                var grid = new Grid();
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                text.Margin = new Thickness(7, 0, 0, 0);
                Grid.SetColumn(text, 1);
                grid.Children.Add(dot);
                grid.Children.Add(text);
                yield return grid;
            }
            else if (line.StartsWith('#'))
            {
                yield return Inline(line.TrimStart('#').Trim(), FontWeights.SemiBold);
            }
            else
            {
                yield return Inline(line, FontWeights.Normal);
            }
        }
    }

    /// <summary>A wrapping line with the inline Markdown the notes use: **bold**, *italic*, `code`, [links](url).</summary>
    private static TextBlock Inline(string text, FontWeight weight)
    {
        var block = Ui.Label("", 12, Ui.T.Text, weight, lines: 0);
        block.TextTrimming = TextTrimming.None;
        block.VerticalAlignment = VerticalAlignment.Top;
        block.Inlines.Clear();
        var index = 0;
        var plain = new System.Text.StringBuilder();
        void Flush()
        {
            if (plain.Length == 0) return;
            block.Inlines.Add(new Run(plain.ToString()));
            plain.Clear();
        }
        while (index < text.Length)
        {
            if (Span(text, index, "**", out var bold, out var next) || Span(text, index, "__", out bold, out next))
            {
                Flush();
                block.Inlines.Add(new Bold(new Run(bold)));
                index = next;
            }
            else if (Span(text, index, "`", out var code, out next))
            {
                Flush();
                block.Inlines.Add(new Run(code) { FontFamily = new FontFamily("Cascadia Mono, Consolas"), Background = Ui.T.Overlay(0.07) });
                index = next;
            }
            else if ((text[index] == '*' || text[index] == '_') && Span(text, index, text[index].ToString(), out var italic, out next) && italic.Trim().Length == italic.Length)
            {
                Flush();
                block.Inlines.Add(new Italic(new Run(italic)));
                index = next;
            }
            else if (text[index] == '[' && Link(text, index, out var label, out var url, out next))
            {
                Flush();
                var link = new Hyperlink(new Run(label)) { Foreground = Ui.T.Accent, TextDecorations = null, Cursor = System.Windows.Input.Cursors.Hand };
                link.Click += (_, _) => OpenUrl(url);
                block.Inlines.Add(link);
                index = next;
            }
            else
            {
                plain.Append(text[index]);
                index++;
            }
        }
        Flush();
        return block;
    }

    private static bool Span(string text, int index, string mark, out string inner, out int next)
    {
        inner = "";
        next = index;
        if (string.CompareOrdinal(text, index, mark, 0, mark.Length) != 0) return false;
        var end = text.IndexOf(mark, index + mark.Length, StringComparison.Ordinal);
        if (end <= index + mark.Length) return false;
        inner = text[(index + mark.Length)..end];
        next = end + mark.Length;
        return true;
    }

    private static bool Link(string text, int index, out string label, out string url, out int next)
    {
        label = url = "";
        next = index;
        var close = text.IndexOf("](", index, StringComparison.Ordinal);
        if (close < 0) return false;
        var end = text.IndexOf(')', close + 2);
        if (end < 0) return false;
        label = text[(index + 1)..close];
        url = text[(close + 2)..end];
        next = end + 1;
        return url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || url.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
    }

    internal static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { }
        catch (InvalidOperationException) { }
    }
}

/// <summary>The header Settings and the release notes share: a back button and the title.</summary>
internal static class SubPageHeader
{
    public static FrameworkElement Make(string title, Action back)
    {
        var button = Ui.IconButton(Theme.Glyph.ChevronLeft, back, L.Back, 12, Ui.T.Secondary, 24, 24);
        var label = Ui.Label(title, 14, Ui.T.Text, FontWeights.SemiBold);
        var row = Ui.HStack(4, button, label);
        return new Border
        {
            Child = row,
            MinHeight = 38,
            Padding = new Thickness(12, 12, 12, 8),
            Background = Brushes.Transparent,
        };
    }
}
