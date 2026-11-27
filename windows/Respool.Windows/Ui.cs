using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Respool.Windows;

/// <summary>
/// Small builders for the panel's pieces, so the views read like the macOS app's SwiftUI: a
/// label, an icon, a row that lights up under the pointer, a menu.
/// </summary>
public static class Ui
{
    public static Theme T { get; set; } = new(false);

    // MARK: Text

    public static TextBlock Label(string text, double size = 13, Brush? brush = null, FontWeight? weight = null, int lines = 1)
    {
        var label = new TextBlock
        {
            Text = text,
            FontSize = size,
            Foreground = brush ?? T.Text,
            FontWeight = weight ?? FontWeights.Normal,
            FontFamily = Theme.Font,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (lines == 1) label.TextWrapping = TextWrapping.NoWrap;
        else
        {
            label.TextWrapping = TextWrapping.Wrap;
            if (lines > 1) label.MaxHeight = Math.Ceiling(size * 1.36) * lines;
        }
        // Figures line up in columns.
        Typography.SetNumeralAlignment(label, FontNumeralAlignment.Tabular);
        return label;
    }

    public static TextBlock Icon(string glyph, double size = 11, Brush? brush = null)
    {
        var icon = new TextBlock
        {
            Text = glyph,
            FontFamily = Theme.Icons,
            FontSize = size,
            Foreground = brush ?? T.Secondary,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        return icon;
    }

    public static T2 Tip<T2>(this T2 element, string? tip) where T2 : FrameworkElement
    {
        if (!string.IsNullOrEmpty(tip)) element.ToolTip = tip;
        return element;
    }

    public static T2 Margin<T2>(this T2 element, double left, double top, double right, double bottom) where T2 : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static T2 Margin<T2>(this T2 element, double horizontal, double vertical) where T2 : FrameworkElement
    {
        element.Margin = new Thickness(horizontal, vertical, horizontal, vertical);
        return element;
    }

    // MARK: Layout

    public static StackPanel HStack(double spacing, params UIElement?[] children) => Stack(Orientation.Horizontal, spacing, children);
    public static StackPanel VStack(double spacing, params UIElement?[] children) => Stack(Orientation.Vertical, spacing, children);

    private static StackPanel Stack(Orientation orientation, double spacing, UIElement?[] children)
    {
        var stack = new StackPanel { Orientation = orientation };
        var first = true;
        foreach (var child in children)
        {
            if (child is null) continue;
            if (!first && child is FrameworkElement element)
            {
                var margin = element.Margin;
                element.Margin = orientation == Orientation.Horizontal
                    ? new Thickness(margin.Left + spacing, margin.Top, margin.Right, margin.Bottom)
                    : new Thickness(margin.Left, margin.Top + spacing, margin.Right, margin.Bottom);
            }
            stack.Children.Add(child);
            first = false;
        }
        return stack;
    }

    /// <summary>A row with a stretching middle: leading items, a filler, then trailing items.</summary>
    public static Grid Row(IEnumerable<UIElement?> leading, UIElement? middle, IEnumerable<UIElement?> trailing, double spacing = 8)
    {
        var grid = new Grid();
        var column = 0;
        void Add(UIElement? element, GridLength width)
        {
            if (element is null) return;
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            if (column > 0 && element is FrameworkElement framework)
            {
                var margin = framework.Margin;
                framework.Margin = new Thickness(margin.Left + spacing, margin.Top, margin.Right, margin.Bottom);
            }
            Grid.SetColumn(element, column++);
            grid.Children.Add(element);
        }
        foreach (var item in leading) Add(item, GridLength.Auto);
        Add(middle ?? new Border(), new GridLength(1, GridUnitType.Star));
        foreach (var item in trailing) Add(item, GridLength.Auto);
        return grid;
    }

    public static Border Box(UIElement? child, Brush? fill = null, double radius = 0, Thickness? padding = null)
    {
        return new Border
        {
            Child = child,
            Background = fill ?? Brushes.Transparent,
            CornerRadius = new CornerRadius(radius),
            Padding = padding ?? new Thickness(0),
        };
    }

    public static Border Hairline() => new() { Height = 1, Background = T.Overlay(0.08), SnapsToDevicePixels = true };

    public static Rectangle Dot(double size, Brush fill, double radius = -1) => new()
    {
        Width = size,
        Height = size,
        Fill = fill,
        RadiusX = radius < 0 ? size / 2 : radius,
        RadiusY = radius < 0 ? size / 2 : radius,
        VerticalAlignment = VerticalAlignment.Center,
    };

    // MARK: Interaction

    /// <summary>
    /// A rounded area that lights up under the pointer and runs <paramref name="click"/>. The
    /// fill can be given for a selected or expanded state.
    /// </summary>
    public static Border Hover(UIElement child, Action? click, double radius = 7, Brush? fill = null, Brush? hoverFill = null, Thickness? padding = null)
    {
        var resting = fill ?? Brushes.Transparent;
        var lit = hoverFill ?? T.Overlay(0.07);
        var border = new Border
        {
            Child = child,
            Background = resting,
            CornerRadius = new CornerRadius(radius),
            Padding = padding ?? new Thickness(0),
            Cursor = click is null ? null : Cursors.Hand,
        };
        border.MouseEnter += (_, _) => { if (fill is null || ReferenceEquals(fill, Brushes.Transparent)) border.Background = lit; };
        border.MouseLeave += (_, _) => border.Background = resting;
        if (click is not null)
        {
            var pressed = false;
            border.MouseLeftButtonDown += (_, e) => { pressed = true; e.Handled = true; };
            border.MouseLeftButtonUp += (_, e) =>
            {
                if (!pressed) return;
                pressed = false;
                e.Handled = true;
                click();
            };
            border.MouseLeave += (_, _) => pressed = false;
        }
        return border;
    }

    /// <summary>A borderless icon button, as the rows' hover buttons are.</summary>
    public static Border IconButton(string glyph, Action click, string? tip = null, double size = 11, Brush? brush = null, double width = 22, double height = 16)
    {
        var icon = Icon(glyph, size, brush ?? T.Secondary);
        var button = new Border
        {
            Width = width,
            Height = height,
            Background = Brushes.Transparent,
            Child = icon,
            Cursor = Cursors.Hand,
            CornerRadius = new CornerRadius(4),
        };
        button.MouseEnter += (_, _) => button.Background = T.Overlay(0.08);
        button.MouseLeave += (_, _) => button.Background = Brushes.Transparent;
        button.MouseLeftButtonDown += (_, e) => e.Handled = true;
        button.MouseLeftButtonUp += (_, e) => { e.Handled = true; click(); };
        return button.Tip(tip);
    }

    /// <summary>A small rounded text button, like the Mac's small bordered buttons.</summary>
    public static Border SmallButton(string text, Action click, string? tip = null, bool primary = false)
    {
        var label = Label(text, 11, primary ? T.White : T.Text, FontWeights.Medium);
        var button = new Border
        {
            Child = label,
            Padding = new Thickness(8, 2, 8, 2),
            MinHeight = 20,
            CornerRadius = new CornerRadius(5),
            Background = primary ? T.Accent : T.Overlay(0.09),
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var resting = button.Background;
        button.MouseEnter += (_, _) => button.Background = primary ? T.AccentAt(0.85) : T.Overlay(0.14);
        button.MouseLeave += (_, _) => button.Background = resting;
        button.MouseLeftButtonDown += (_, e) => e.Handled = true;
        button.MouseLeftButtonUp += (_, e) => { e.Handled = true; click(); };
        return button.Tip(tip);
    }

    public static Border Capsule(UIElement child, Brush fill, double height, double horizontalPadding)
    {
        return new Border
        {
            Child = child,
            Background = fill,
            Height = height,
            MinWidth = height,
            CornerRadius = new CornerRadius(height / 2),
            Padding = new Thickness(horizontalPadding, 0, horizontalPadding, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    // MARK: Fields

    /// <summary>A plain text field with a placeholder; Enter runs <paramref name="submit"/>.</summary>
    public static (Grid View, TextBox Box) Field(string placeholder, double size, Action<TextBox>? submit = null, string text = "")
    {
        var box = new TextBox
        {
            Text = text,
            FontSize = size,
            FontFamily = Theme.Font,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = T.Text,
            CaretBrush = T.Text,
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            SelectionBrush = T.Accent,
        };
        var hint = Label(placeholder, size, T.Placeholder);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(2, 0, 0, 0);
        hint.Visibility = text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) => hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (submit is not null)
        {
            box.KeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter) return;
                e.Handled = true;
                submit(box);
            };
        }
        var grid = new Grid();
        grid.Children.Add(hint);
        grid.Children.Add(box);
        return (grid, box);
    }

    /// <summary>A small on/off switch.</summary>
    public static FrameworkElement Switch(bool on, Action<bool> changed)
    {
        var track = new Border { Width = 32, Height = 18, CornerRadius = new CornerRadius(9), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center };
        var knob = new Ellipse { Width = 14, Height = 14, Fill = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(2, 0, 0, 0) };
        knob.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 3, ShadowDepth = 0.5, Opacity = 0.25 };
        track.Child = knob;
        var state = on;
        void Paint()
        {
            track.Background = state ? T.Accent : T.Overlay(0.16);
            knob.Margin = new Thickness(state ? 16 : 2, 0, 0, 0);
        }
        Paint();
        track.MouseLeftButtonDown += (_, e) => e.Handled = true;
        track.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            state = !state;
            Paint();
            changed(state);
        };
        return track;
    }

    /// <summary>A segmented picker; <paramref name="selected"/> may be -1 for none.</summary>
    public static Border Segmented(IReadOnlyList<string> titles, int selected, Action<int> pick)
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal };
        for (var index = 0; index < titles.Count; index++)
        {
            var at = index;
            var isOn = index == selected;
            var label = Label(titles[index], 11, isOn ? T.Text : T.Secondary, isOn ? FontWeights.SemiBold : FontWeights.Normal);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            var segment = new Border
            {
                Child = label,
                Padding = new Thickness(9, 0, 9, 0),
                Height = 20,
                CornerRadius = new CornerRadius(5),
                Background = isOn ? (T.Dark ? T.Overlay(0.18) : Brushes.White) : Brushes.Transparent,
                Cursor = Cursors.Hand,
            };
            segment.MouseLeftButtonDown += (_, e) => e.Handled = true;
            segment.MouseLeftButtonUp += (_, e) => { e.Handled = true; pick(at); };
            stack.Children.Add(segment);
        }
        return new Border { Child = stack, Background = T.Overlay(0.07), CornerRadius = new CornerRadius(7), Padding = new Thickness(2), VerticalAlignment = VerticalAlignment.Center };
    }

    /// <summary>A drop-down of choices.</summary>
    public static ComboBox Popup(IReadOnlyList<string> titles, int selected, Action<int> pick)
    {
        var box = new ComboBox { FontSize = 12, MinWidth = 120, VerticalAlignment = VerticalAlignment.Center };
        foreach (var title in titles) box.Items.Add(title);
        box.SelectedIndex = selected;
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) pick(box.SelectedIndex); };
        return box;
    }

    // MARK: Menus

    public static ContextMenu Menu(params object?[] items)
    {
        var menu = new ContextMenu();
        foreach (var item in items) if (item is not null) menu.Items.Add(item);
        return menu;
    }

    public static MenuItem Item(string title, Action click, bool enabled = true, bool? check = null)
    {
        var item = new MenuItem { Header = title, IsEnabled = enabled };
        if (check is { } on)
        {
            item.IsCheckable = false;
            item.IsChecked = on;
        }
        item.Click += (_, _) => click();
        return item;
    }

    public static MenuItem Submenu(string title, IEnumerable<object?> items)
    {
        var menu = new MenuItem { Header = title };
        foreach (var item in items) if (item is not null) menu.Items.Add(item);
        if (menu.Items.Count == 0) menu.IsEnabled = false;
        return menu;
    }

    public static Separator Divider() => new();

    /// <summary>Shows <paramref name="menu"/> under the pointer now.</summary>
    public static void Show(ContextMenu menu, UIElement target)
    {
        menu.PlacementTarget = target;
        menu.Placement = PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

    // MARK: Pieces shared by the panel, the card and the switcher

    /// <summary>A figure and what it counts, on a tinted tile.</summary>
    public static Border StatTile(string value, string label)
    {
        var figure = Label(value, 14, T.Text, FontWeights.SemiBold);
        var caption = Label(label, 10, T.Secondary);
        return new Border
        {
            Child = VStack(2, figure, caption),
            Padding = new Thickness(9, 7, 9, 7),
            CornerRadius = new CornerRadius(8),
            Background = T.Overlay(0.07),
        };
    }

    /// <summary>Tiles side by side, sharing the width.</summary>
    public static UniformGrid Tiles(params UIElement[] tiles)
    {
        var grid = new UniformGrid { Rows = 1 };
        for (var index = 0; index < tiles.Length; index++)
        {
            if (tiles[index] is FrameworkElement element) element.Margin = new Thickness(index == 0 ? 0 : 3, 0, index == tiles.Length - 1 ? 0 : 3, 0);
            grid.Children.Add(tiles[index]);
        }
        return grid;
    }

    /// <summary>Bars for how busy something was: one per slice, the tallest full height.</summary>
    public static Grid ActivityChart(IReadOnlyList<int> buckets, double height = 34)
    {
        var grid = new Grid { Height = height };
        var peak = Math.Max(1, buckets.Count == 0 ? 1 : buckets.Max());
        for (var index = 0; index < buckets.Count; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            var count = buckets[index];
            var bar = new Border
            {
                Height = count == 0 ? 2 : Math.Max(4, height * count / peak),
                Background = count == 0 ? T.Overlay(0.10) : T.Accent,
                CornerRadius = new CornerRadius(1.5),
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(1, 0, 1, 0),
            };
            Grid.SetColumn(bar, index);
            grid.Children.Add(bar);
        }
        return grid;
    }

    /// <summary>The live state of a running session: a spinner-like ring, an orange or a colored dot.</summary>
    public static FrameworkElement LiveMark(Respool.Core.LiveState state, bool finishedUnseen, bool selected)
    {
        if (state == Respool.Core.LiveState.Working)
        {
            var ring = new Ellipse
            {
                Width = 10,
                Height = 10,
                Stroke = selected ? T.White : T.Secondary,
                StrokeThickness = 1.6,
                StrokeDashArray = new DoubleCollection { 3, 2 },
                VerticalAlignment = VerticalAlignment.Center,
                RenderTransformOrigin = new Point(0.5, 0.5),
            };
            var rotate = new RotateTransform();
            ring.RenderTransform = rotate;
            rotate.BeginAnimation(RotateTransform.AngleProperty,
                new System.Windows.Media.Animation.DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.2)) { RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever });
            return ring;
        }
        var color = selected ? T.White
            : state == Respool.Core.LiveState.Waiting ? T.Solid(T.Orange)
            : finishedUnseen ? T.Solid(T.Green)
            : T.Accent;
        return Dot(7, color);
    }

    /// <summary>A small square in a tag's color.</summary>
    public static Rectangle TagMark(int color, bool selected = false) => Dot(7, selected ? T.White : T.Solid(T.TagColor(color)), 2);
}
