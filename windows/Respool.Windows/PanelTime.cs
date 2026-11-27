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
    private TimePeriod Period => (TimePeriod)Math.Clamp(Settings.TimePeriod, 0, 2);

    private void TimeSection()
    {
        var report = Library.Report(Period);
        var title = Period switch { TimePeriod.Week => L.WeekTitle, TimePeriod.Month => L.ThisMonth, _ => L.Today };
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        label.Children.Add(Ui.Label(title, 11, T.Secondary, FontWeights.Medium));
        if (report.Total >= 60) label.Children.Add(Ui.Label("  " + Format.Worked(report.Total), 11, T.Text, FontWeights.Medium));
        var period = Ui.Hover(label, () =>
        {
            Library.ChangeSettings(settings => settings.TimePeriod = (settings.TimePeriod + 1) % 3, reload: false);
            _timeShowAll = false;
            Rebuild();
        }, 10, T.Overlay(0.07), T.Overlay(0.11), new Thickness(7, 2, 7, 2)).Tip(L.ChangePeriod);
        period.Height = 20;
        _list.Children.Add(CollapsibleHeader(PanelSection.TimeSection, 0, period));
        if (IsCollapsed(PanelSection.TimeSection)) return;
        if (report.Rows.Count == 0)
        {
            _list.Children.Add(Ui.Label(L.NoTimeYet, 12, T.Secondary).Margin(8, 6));
            return;
        }
        var axis = Period == TimePeriod.Today ? DayAxis(report) : (0.0, 0.0);
        _list.Children.Add((Period == TimePeriod.Today ? DayTimeline(report, axis) : DayColumns(report)).Margin(8, 4, 8, 6));
        var peak = Math.Max(1, report.Rows.Max(row => row.Total));
        var rows = _timeShowAll ? report.Rows : report.Rows.Take(5).ToList();
        foreach (var row in rows) _list.Children.Add(TimeRow(row, peak, axis));
        if (!_timeShowAll && report.Rows.Count > 5)
        {
            _list.Children.Add(Ui.Hover(Ui.Label(L.MoreTimeRows(report.Rows.Count - 5), 12, T.Secondary), () => { _timeShowAll = true; Rebuild(); },
                5, null, Brushes.Transparent, new Thickness(8, 6, 8, 6)));
        }
    }

    /// <summary>From the hour of the first activity to the hour after now; at least four hours when the day allows.</summary>
    private static (double Start, double End) DayAxis(TimeReport report)
    {
        var first = report.Rows.SelectMany(row => row.Timed.Concat(row.Guessed)).Select(span => span.Start).DefaultIfEmpty(report.End).Min();
        double Floor(double seconds) { var date = Time.FromSeconds(seconds).LocalDateTime; return Time.Seconds(new DateTimeOffset(date.Date.AddHours(date.Hour))); }
        double Ceil(double seconds) { var floor = Floor(seconds); return floor < seconds ? floor + 3600 : floor; }
        var start = Floor(first);
        var end = Math.Max(Ceil(report.End), start + 3600);
        if (end - start < 4 * 3600) start = Math.Max(report.Start, end - 4 * 3600);
        return (start, end);
    }

    private FrameworkElement DayTimeline(TimeReport report, (double Start, double End) axis)
    {
        var span = Math.Max(axis.End - axis.Start, 1);
        var track = new Canvas { Height = 16, ClipToBounds = true };
        var holder = new Border { Height = 16, CornerRadius = new CornerRadius(5), Background = T.Overlay(0.07), Child = track, ClipToBounds = true };
        holder.Clip = null;
        // The day is cut wherever any project starts or stops; each slice stacks the projects busy in it.
        var spans = report.Rows.ToDictionary(row => row.Key, row => TimeMath.Merged(row.Timed.Concat(row.Guessed)));
        var cuts = spans.Values.SelectMany(list => list.SelectMany(item => new[] { item.Start, item.End })).Append(axis.Start).Append(axis.End)
            .Select(value => Math.Clamp(value, axis.Start, axis.End)).Distinct().OrderBy(value => value).ToList();
        void Paint()
        {
            track.Children.Clear();
            var width = track.ActualWidth;
            if (width <= 0) return;
            for (var index = 0; index + 1 < cuts.Count; index++)
            {
                var from = cuts[index];
                var to = cuts[index + 1];
                var middle = (from + to) / 2;
                var active = report.Rows.Where(row => spans[row.Key].Any(item => item.Start <= middle && item.End >= middle)).ToList();
                if (active.Count == 0) continue;
                var x = (from - axis.Start) / span * width;
                var w = Math.Max((to - from) / span * width + 0.5, 1.5);
                var share = 16.0 / active.Count;
                for (var layer = 0; layer < active.Count; layer++)
                {
                    var piece = new Border { Width = w, Height = share, Background = T.Solid(T.TimeColor(active[layer].Color)) };
                    Canvas.SetLeft(piece, x);
                    Canvas.SetTop(piece, layer * share);
                    track.Children.Add(piece);
                }
            }
        }
        track.SizeChanged += (_, _) => Paint();
        var hours = (int)Math.Round(span / 3600);
        var step = Math.Max(1, (int)Math.Ceiling(hours / 4.0));
        var labels = new Grid { Height = 11, Margin = new Thickness(0, 3, 0, 0) };
        var marks = new List<double>();
        for (var mark = axis.Start; mark <= axis.End + 1; mark += step * 3600) marks.Add(mark);
        labels.SizeChanged += (_, _) =>
        {
            labels.Children.Clear();
            for (var index = 0; index < marks.Count; index++)
            {
                var text = Ui.Label(Format.TimeOfDay(Time.FromSeconds(marks[index])), 9, T.Tertiary);
                var x = (marks[index] - axis.Start) / span * labels.ActualWidth;
                if (index == 0) { text.HorizontalAlignment = HorizontalAlignment.Left; text.Margin = new Thickness(Math.Max(0, x), 0, 0, 0); }
                else if (index == marks.Count - 1) { text.HorizontalAlignment = HorizontalAlignment.Right; text.Margin = new Thickness(0, 0, Math.Max(0, labels.ActualWidth - x), 0); }
                else { text.HorizontalAlignment = HorizontalAlignment.Left; text.Margin = new Thickness(Math.Max(0, x - 14), 0, 0, 0); }
                labels.Children.Add(text);
            }
        };
        return Ui.VStack(0, holder, labels);
    }

    private FrameworkElement DayColumns(TimeReport report)
    {
        var month = Period == TimePeriod.Month;
        var grid = new Grid { Height = 46 };
        var labels = new Grid { Margin = new Thickness(0, 3, 0, 0) };
        var peak = Math.Max(60, report.Days.Select(day => day.Total).DefaultIfEmpty(0).Max());
        var order = report.Rows.Select(row => row.Key).ToList();
        for (var index = 0; index < report.Days.Count; index++)
        {
            var day = report.Days[index];
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            labels.ColumnDefinitions.Add(new ColumnDefinition());
            FrameworkElement column;
            if (day.Total < 60)
            {
                column = new Border { Height = 2, CornerRadius = new CornerRadius(1.5), Background = T.Overlay(0.10), VerticalAlignment = VerticalAlignment.Bottom };
            }
            else
            {
                var height = Math.Max(4, 46 * day.Total / peak);
                var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
                // The busiest project sits at the bottom.
                foreach (var key in order.Where(day.Parts.ContainsKey).Reverse())
                {
                    var row = report.Rows.First(item => item.Key == key);
                    stack.Children.Add(new Border { Height = height * day.Parts[key] / day.Total, Background = T.Solid(T.TimeColor(row.Color)) });
                }
                column = new Border { Child = stack, Height = height, CornerRadius = new CornerRadius(month ? 1.5 : 3), VerticalAlignment = VerticalAlignment.Bottom, ClipToBounds = true };
                column.Clip = new RectangleGeometry(new Rect(0, 0, 1000, height), month ? 1.5 : 3, month ? 1.5 : 3);
                column.SizeChanged += (_, _) => column.Clip = new RectangleGeometry(new Rect(0, 0, column.ActualWidth, height), month ? 1.5 : 3, month ? 1.5 : 3);
            }
            column.Margin = new Thickness(month ? 1 : 3, 0, month ? 1 : 3, 0);
            column.ToolTip = $"{Format.ShortDay(day.Date)} · {Format.Worked(day.Total)}";
            Grid.SetColumn(column, index);
            grid.Children.Add(column);
            var text = month ? (day.Date.Day is 1 or 8 or 15 or 22 or 29 ? day.Date.Day.ToString() : "") : Format.Weekday(day.Date);
            var label = Ui.Label(text, 9, T.Tertiary);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            Grid.SetColumn(label, index);
            labels.Children.Add(label);
        }
        return Ui.VStack(0, grid, labels);
    }

    private FrameworkElement TimeRow(ProjectTime row, double peak, (double Start, double End) axis)
    {
        var timing = Library.IsTiming(row.Key);
        var color = T.TimeColor(row.Color);
        var button = Ui.IconButton(timing ? Theme.Glyph.Stop : Theme.Glyph.Play, () => Library.ToggleTimer(row.Key), timing ? L.StopTimer : L.StartTimer, 9, timing ? T.Accent : T.Secondary);
        button.Visibility = timing ? Visibility.Visible : Visibility.Hidden;
        var top = Ui.Row(new UIElement[] { Ui.Dot(7, T.Solid(color)), Ui.Label(row.Name, 13) }, null,
            new UIElement[] { button, Ui.Label(Format.Worked(row.Total), 11, T.Secondary) }, 7);

        FrameworkElement bar;
        if (Period == TimePeriod.Today)
        {
            var span = Math.Max(axis.End - axis.Start, 1);
            var canvas = new Canvas { Height = 4 };
            canvas.SizeChanged += (_, _) =>
            {
                canvas.Children.Clear();
                void Add(IEnumerable<Span> spans, Brush brush)
                {
                    foreach (var item in spans)
                    {
                        var x = (item.Start - axis.Start) / span * canvas.ActualWidth;
                        var piece = new Border { Width = Math.Max(1.5, item.Length / span * canvas.ActualWidth), Height = 4, Background = brush, CornerRadius = new CornerRadius(1.3) };
                        Canvas.SetLeft(piece, x);
                        canvas.Children.Add(piece);
                    }
                }
                Add(row.Guessed, T.Solid(color, 0.5));
                Add(row.Timed, T.Solid(color));
            };
            bar = new Border { Height = 4, CornerRadius = new CornerRadius(1.3), Background = T.Overlay(0.07), Child = canvas };
        }
        else
        {
            var grid = new Grid { Height = 4 };
            var automatic = new Border { CornerRadius = new CornerRadius(2), Background = T.Solid(color, 0.5), HorizontalAlignment = HorizontalAlignment.Left };
            var timer = new Border { CornerRadius = new CornerRadius(2), Background = T.Solid(color), HorizontalAlignment = HorizontalAlignment.Left };
            grid.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = T.Overlay(0.07) });
            grid.Children.Add(automatic);
            grid.Children.Add(timer);
            grid.SizeChanged += (_, _) =>
            {
                var width = Math.Max(3, grid.ActualWidth * row.Total / peak);
                automatic.Width = width;
                timer.Width = row.Manual >= 1 ? Math.Max(3, width * row.Manual / Math.Max(row.Total, 1)) : 0;
            };
            bar = grid;
            bar.Margin = new Thickness(14, 0, 0, 0);
        }
        var hover = Ui.Hover(Ui.VStack(5, top, bar), null, 7, null, null, new Thickness(8, 6, 8, 6))
            .Tip(L.TimeBreakdown(Format.Worked(row.Manual), Format.Worked(row.Automatic)));
        hover.MouseEnter += (_, _) => button.Visibility = Visibility.Visible;
        hover.MouseLeave += (_, _) => button.Visibility = timing ? Visibility.Visible : Visibility.Hidden;
        var last = Library.Current.LastTimeEntries.GetValueOrDefault(row.Key);
        hover.ContextMenu = Ui.Menu(
            Ui.Item(timing ? L.StopTimer : L.StartTimer, () => Library.ToggleTimer(row.Key)),
            last is not null ? Ui.Item(L.DeleteLastEntry(Format.Worked(last.Length)), () => Library.DeleteLastTimeEntry(row.Key)) : null);
        return hover;
    }
}
