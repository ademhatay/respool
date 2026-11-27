using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Respool.Core;

namespace Respool.Windows;

/// <summary>
/// The colors and type of the macOS app, light or dark. "P(a)" in the spec is <see cref="Overlay"/>:
/// black at a given opacity in light mode, white in dark.
/// </summary>
public sealed class Theme
{
    public bool Dark { get; }

    public Brush Background { get; }
    public Brush Card { get; }
    public Brush Text { get; }
    public Brush Secondary { get; }
    public Brush Tertiary { get; }
    public Brush Placeholder { get; }
    public Brush Accent { get; }
    public Color AccentColor { get; }
    public Brush White { get; } = Freeze(new SolidColorBrush(Colors.White));
    public Brush Clear { get; } = Brushes.Transparent;

    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private readonly Dictionary<double, Brush> _overlays = new();

    public Theme(bool dark)
    {
        Dark = dark;
        AccentColor = SystemAccent() ?? (dark ? Color.FromRgb(0x0A, 0x84, 0xFF) : Color.FromRgb(0x00, 0x7A, 0xFF));
        Accent = Freeze(new SolidColorBrush(AccentColor));
        Background = Solid(dark ? Color.FromRgb(0x28, 0x28, 0x2A) : Color.FromRgb(0xF4, 0xF4, 0xF5));
        Card = Solid(dark ? Color.FromRgb(0x2E, 0x2E, 0x31) : Color.FromRgb(0xFA, 0xFA, 0xFB));
        Text = Solid(dark ? Color.FromArgb(0xDA, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xD9, 0, 0, 0));
        Secondary = Solid(dark ? Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x80, 0, 0, 0));
        Tertiary = Solid(dark ? Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x42, 0, 0, 0));
        // Windows draws text thinner than the Mac, so a field's hint needs more contrast than the tertiary color.
        Placeholder = Solid(dark ? Color.FromArgb(0x73, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x6B, 0, 0, 0));
    }

    /// <summary>The theme chosen in Settings, or the Windows apps setting.</summary>
    public static Theme For(string appearance) => new(appearance switch
    {
        "dark" => true,
        "light" => false,
        _ => Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int value && value == 0,
    });

    /// <summary>Black or white at an opacity, as the panel's fills are.</summary>
    public Brush Overlay(double opacity)
    {
        if (_overlays.TryGetValue(opacity, out var brush)) return brush;
        var alpha = (byte)Math.Round(opacity * 255);
        brush = Solid(Dark ? Color.FromArgb(alpha, 255, 255, 255) : Color.FromArgb(alpha, 0, 0, 0));
        _overlays[opacity] = brush;
        return brush;
    }

    public Brush AccentAt(double opacity) => Solid(Color.FromArgb((byte)Math.Round(opacity * 255), AccentColor.R, AccentColor.G, AccentColor.B));

    // System colors, light / dark.
    public Color Red => Dark ? Rgb(0xFF453A) : Rgb(0xFF3B30);
    public Color Orange => Dark ? Rgb(0xFF9F0A) : Rgb(0xFF9500);
    public Color Yellow => Dark ? Rgb(0xFFD60A) : Rgb(0xFFCC00);
    public Color Green => Dark ? Rgb(0x30D158) : Rgb(0x34C759);
    public Color Blue => Dark ? Rgb(0x0A84FF) : Rgb(0x007AFF);
    public Color Purple => Dark ? Rgb(0xBF5AF2) : Rgb(0xAF52DE);
    public Color Pink => Dark ? Rgb(0xFF375F) : Rgb(0xFF2D55);
    public Color Teal => Dark ? Rgb(0x40C8E0) : Rgb(0x30B0C7);
    public Color Indigo => Dark ? Rgb(0x5E5CE6) : Rgb(0x5856D6);
    public Color Gray => Dark ? Rgb(0x98989D) : Rgb(0x8E8E93);

    /// <summary>Tag colors: red, orange, yellow, green, blue, purple, gray.</summary>
    public Color TagColor(int index) => index switch { 0 => Red, 1 => Orange, 2 => Yellow, 3 => Green, 4 => Blue, 5 => Purple, _ => Gray };

    /// <summary>Project colors on the time charts, busiest first; gray once they run out.</summary>
    public Color TimeColor(int? index) => index switch { 0 => Blue, 1 => Orange, 2 => Green, 3 => Purple, 4 => Pink, 5 => Teal, 6 => Yellow, 7 => Indigo, _ => Gray };

    public static int TimePaletteCount => 8;

    public Brush Solid(Color color) => Freeze(new SolidColorBrush(color));
    public Brush Solid(Color color, double opacity) => Freeze(new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), color.R, color.G, color.B)));

    private static Color Rgb(int value) => Color.FromRgb((byte)(value >> 16), (byte)(value >> 8 & 0xFF), (byte)(value & 0xFF));

    private static T Freeze<T>(T brush) where T : Freezable
    {
        brush.Freeze();
        return brush;
    }

    private static Color? SystemAccent()
    {
        try
        {
            if (Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor", null) is int abgr)
            {
                return Color.FromRgb((byte)(abgr & 0xFF), (byte)(abgr >> 8 & 0xFF), (byte)(abgr >> 16 & 0xFF));
            }
        }
        catch (System.Security.SecurityException) { }
        return null;
    }

    /// <summary>Segoe Fluent Icons glyphs standing in for the SF Symbols the Mac uses.</summary>
    public static class Glyph
    {
        public const string Search = "";
        public const string Clear = "";
        public const string More = "";
        public const string Today = "";
        public const string Chats = "";
        public const string Clock = "";
        public const string ChevronRight = "";
        public const string ChevronLeft = "";
        public const string ChevronUp = "";
        public const string ChevronDown = "";
        public const string Folder = "";
        public const string FolderOpen = "";
        public const string Pin = "";
        public const string Unpin = "";
        public const string List = "";
        public const string Find = "";
        public const string Add = "";
        public const string Play = "";
        public const string Stop = "";
        public const string Terminal = "";
        public const string Info = "";
        public const string Close = "";
        public const string Circle = "";
        public const string Check = "";
        public const string CheckCircle = "";
        public const string Warning = "";
        public const string Download = "";
        public const string Note = "";
        public const string Copy = "";
        public const string Moon = "";
        public const string Filter = "";
        public const string Chat = "";
        public const string Branch = "";
        public const string Processor = "";
        public const string PullRequest = "";
        public const string Settings = "";
        public const string Tag = "";
    }
}
