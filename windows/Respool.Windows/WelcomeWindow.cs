using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using Respool.Core;

namespace Respool.Windows;

/// <summary>
/// The first-run window: what Respool found, a few choices, and a button to begin.
/// </summary>
public sealed class WelcomeWindow : Window
{
    private const double SheetWidth = 440;
    private const double ShadowMargin = 24;

    private readonly IAppHost _host;
    private readonly Action _done;
    private readonly Border _group = new();
    private ComboBox? _popup;
    private bool _finished;

    private static readonly string[] Edges = ["right", "left", "top", "bottom"];

    public WelcomeWindow(IAppHost host, Action done)
    {
        _host = host;
        _done = done;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = SheetWidth + ShadowMargin * 2;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Title = L.WelcomeTitle;
        Opacity = 0;

        Content = Build();
        Place();
        PreviewKeyDown += OnKey;
        Loaded += (_, _) =>
        {
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.18)));
            Activate();
        };
    }

    private UIElement Build()
    {
        var t = Ui.T;
        var library = _host.Library;

        var icon = new Image { Width = 72, Height = 72, Source = AppIcon(), HorizontalAlignment = HorizontalAlignment.Center };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);

        var title = Ui.Label(L.WelcomeTitle, 20, t.Text, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.Margin = new Thickness(0, 10, 0, 0);

        var line = Ui.Label(L.WelcomeLine, 13, t.Secondary, lines: 0);
        line.TextAlignment = TextAlignment.Center;
        line.HorizontalAlignment = HorizontalAlignment.Center;
        line.Margin = new Thickness(0, 5, 0, 0);

        var stack = new StackPanel();
        stack.Children.Add(icon);
        stack.Children.Add(title);
        stack.Children.Add(line);

        if (library.SessionCount > 0)
        {
            var found = Ui.Label(L.WelcomeFound(library.SessionCount, library.Current.Projects.Count), 11, t.Tertiary);
            found.HorizontalAlignment = HorizontalAlignment.Center;
            found.Margin = new Thickness(0, 6, 0, 0);
            stack.Children.Add(found);
        }

        _group.Margin = new Thickness(0, 20, 0, 0);
        _group.CornerRadius = new CornerRadius(9);
        _group.Background = t.Overlay(0.06);
        FillGroup();
        stack.Children.Add(_group);

        var startLabel = Ui.Label(L.WelcomeStart, 13, t.White, FontWeights.SemiBold);
        startLabel.HorizontalAlignment = HorizontalAlignment.Center;
        var start = new Border
        {
            Child = startLabel,
            Height = 34,
            CornerRadius = new CornerRadius(9),
            Background = t.Accent,
            Cursor = Cursors.Hand,
            Margin = new Thickness(0, 16, 0, 0),
        };
        start.MouseEnter += (_, _) => start.Background = t.AccentAt(0.85);
        start.MouseLeave += (_, _) => start.Background = t.Accent;
        start.MouseLeftButtonDown += (_, e) => e.Handled = true;
        start.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            Finish();
        };
        stack.Children.Add(start);

        var body = new Border { Padding = new Thickness(26, 26, 26, 22), Child = stack };
        var sheet = Sheets.Make(body, 20, ShadowMargin, SheetWidth);
        // Moved by its background.
        sheet.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        };
        return sheet;
    }

    /// <summary>The settings group; built again when a choice changes how it looks.</summary>
    private void FillGroup()
    {
        var t = Ui.T;
        var library = _host.Library;
        var settings = library.Settings;
        var rows = new List<UIElement>();

        // The panel's shortcut, as registered now.
        var shortcut = _host.ShortcutLabel(ShortcutKind.Panel);
        var key = new Border
        {
            Child = Ui.Label(shortcut.Length > 0 ? shortcut : L.NotAssigned, 12, shortcut.Length > 0 ? t.Text : t.Secondary),
            Padding = new Thickness(8, 0, 8, 0),
            Height = 22,
            CornerRadius = new CornerRadius(6),
            Background = t.Overlay(0.09),
            VerticalAlignment = VerticalAlignment.Center,
        };
        rows.Add(SettingRow(L.OpenPanelShortcut, key));

        // Where the panel sits.
        var edge = Array.IndexOf(Edges, settings.PanelEdge);
        rows.Add(SettingRow(L.PanelPosition, Ui.Segmented(new[] { L.EdgeRight, L.EdgeLeft, L.EdgeTop, L.EdgeBottom }, edge, index =>
        {
            library.ChangeSettings(s => s.PanelEdge = Edges[index], reload: false);
            FillGroup();
        })));

        // Where chats open.
        var methods = Opener.Installed;
        var current = library.GeneralOpenMethod;
        _popup = Ui.Popup(methods.Select(method => method.Title()).ToList(), Math.Max(0, methods.ToList().IndexOf(current)), index =>
        {
            var method = methods[index];
            if (method.Key() == library.Settings.OpenMethod) return;
            library.ChangeSettings(s => s.OpenMethod = method.Key());
        });
        rows.Add(SettingRow(L.OpenChatsIn, _popup));

        // Start at login.
        rows.Add(SettingRow(L.LaunchAtLogin, Ui.Switch(_host.LaunchesAtLogin, on =>
        {
            if (!_host.SetLaunchesAtLogin(on))
            {
                _host.Notice(L.LoginItemFailed);
                FillGroup();
            }
        })));

        var stack = new StackPanel();
        for (var index = 0; index < rows.Count; index++)
        {
            if (index > 0)
            {
                var hairline = Ui.Hairline();
                hairline.Margin = new Thickness(12, 0, 12, 0);
                stack.Children.Add(hairline);
            }
            stack.Children.Add(rows[index]);
        }
        _group.Child = stack;
    }

    private static UIElement SettingRow(string title, UIElement control)
    {
        var row = Ui.Row(Array.Empty<UIElement?>(), Ui.Label(title, 13, Ui.T.Text), new UIElement?[] { control }, spacing: 12);
        row.MinHeight = 38;
        row.Margin = new Thickness(12, 4, 12, 4);
        return row;
    }

    // MARK: Placing and closing

    /// <summary>Centered on the screen under the pointer, a little above the middle.</summary>
    private void Place()
    {
        var area = WorkAreas.UnderCursor();
        if (Content is FrameworkElement sheet) sheet.Measure(new Size(Width, double.PositiveInfinity));
        var height = Content is FrameworkElement measured ? measured.DesiredSize.Height : 480;
        Left = area.Left + (area.Width - Width) / 2;
        var top = area.Top + (area.Height - height) / 2 - area.Height * 0.06;
        Top = Math.Max(area.Top, top);
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (_popup is { IsDropDownOpen: true }) return;
        if (e.Key is Key.Escape or Key.Enter)
        {
            e.Handled = true;
            Finish();
        }
    }

    private void Finish()
    {
        if (_finished) return;
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (_finished) return;
        _finished = true;
        _host.Library.ChangeSettings(settings => settings.DidOnboard = true, reload: false);
        _done();
    }

    // MARK: The icon

    private static ImageSource? AppIcon()
    {
        try
        {
            var info = Application.GetResourceStream(new Uri("pack://application:,,,/Respool.ico"));
            if (info?.Stream is { } stream)
            {
                using (stream) return Largest(stream);
            }
        }
        catch (Exception exception) when (exception is IOException or UriFormatException or NotSupportedException or InvalidOperationException) { }

        try
        {
            using var embedded = typeof(WelcomeWindow).Assembly.GetManifestResourceStream("Respool.ico");
            if (embedded is not null) return Largest(embedded);
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException or FileFormatException) { }

        try
        {
            var path = Environment.ProcessPath;
            if (path is null) return null;
            using var icon = System.Drawing.Icon.ExtractIcon(path, 0, 256) ?? System.Drawing.Icon.ExtractAssociatedIcon(path);
            if (icon is null) return null;
            var source = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or ExternalException) { }
        return null;
    }

    /// <summary>The biggest picture in an .ico.</summary>
    private static BitmapSource Largest(Stream stream)
    {
        var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var frame = decoder.Frames.OrderByDescending(frame => frame.PixelWidth).First();
        frame.Freeze();
        return frame;
    }
}
