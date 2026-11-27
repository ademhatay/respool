using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Respool.Windows;

/// <summary>Paints the tray icon's menu in the panel's colors: rounded accent rows, a thin divider.</summary>
public sealed class TrayMenuRenderer : ToolStripRenderer
{
    private readonly Color _background;
    private readonly Color _text;
    private readonly Color _secondary;
    private readonly Color _border;
    private readonly Color _accent;

    public TrayMenuRenderer(Theme theme)
    {
        _background = theme.Dark ? Color.FromArgb(0x2E, 0x2E, 0x31) : Color.FromArgb(0xFA, 0xFA, 0xFB);
        _text = theme.Dark ? Color.FromArgb(0xEE, 0xEE, 0xF0) : Color.FromArgb(0x1D, 0x1D, 0x1F);
        _secondary = theme.Dark ? Color.FromArgb(0x8C, 0x8C, 0x90) : Color.FromArgb(0x80, 0x80, 0x85);
        _border = theme.Dark ? Color.FromArgb(0x44, 0x44, 0x48) : Color.FromArgb(0xDD, 0xDD, 0xE0);
        var accent = theme.AccentColor;
        _accent = Color.FromArgb(accent.R, accent.G, accent.B);
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        using var brush = new SolidBrush(_background);
        e.Graphics.FillRectangle(brush, e.AffectedBounds);
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        using var pen = new Pen(_border);
        var bounds = e.AffectedBounds;
        e.Graphics.DrawRectangle(pen, bounds.X, bounds.Y, bounds.Width - 1, bounds.Height - 1);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var bounds = new Rectangle(2, 0, e.Item.Width - 4, e.Item.Height);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Rounded(bounds, 5);
        using var brush = new SolidBrush(_accent);
        e.Graphics.FillPath(brush, path);
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = !e.Item.Enabled ? _secondary : e.Item.Selected ? Color.White : _text;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        var color = e.Item.Selected ? Color.White : _text;
        using var font = new Font("Segoe Fluent Icons", 8f);
        TextRenderer.DrawText(e.Graphics, "", font, e.ImageRectangle, color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        using var pen = new Pen(_border);
        var middle = e.Item.Height / 2;
        e.Graphics.DrawLine(pen, 8, middle, e.Item.Width - 8, middle);
    }

    private static GraphicsPath Rounded(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Y, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
