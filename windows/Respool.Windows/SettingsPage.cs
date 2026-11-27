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

/// <summary>
/// The Settings sub-page: shortcuts, where the panel sits and how chats open, the sections, time,
/// look and language, updates, backups, accounts and hidden projects.
/// </summary>
public sealed class SettingsPage
{
    private readonly IAppHost _host;
    private readonly Action _back;
    private readonly Action _showReleaseNotes;
    private readonly ScrollViewer _scroll;
    private readonly Grid _root;

    private ShortcutKind? _recording;
    /// <summary>Organization names being edited, by id; kept across rebuilds until saved.</summary>
    private readonly Dictionary<string, string> _drafts = new();

    public FrameworkElement View => _root;

    /// <summary>A shortcut is being recorded: the panel hands its keys to <see cref="HandleKey"/>.</summary>
    public bool IsRecording => _recording is not null;

    private Library Library => _host.Library;
    private Settings Settings => _host.Library.Settings;

    public SettingsPage(IAppHost host, Action back, Action showReleaseNotes)
    {
        _host = host;
        _back = back;
        _showReleaseNotes = showReleaseNotes;
        _scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
        };
        _root = new Grid();
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(SubPageHeader.Make(L.SettingsTitle, Back));
        Grid.SetRow(_scroll, 1);
        _root.Children.Add(_scroll);
        ReleaseNotesPage.Updated += Rebuild;
        Rebuild();
    }

    private void Back()
    {
        CancelRecording();
        _back();
    }

    /// <summary>Stops recording a shortcut and puts the old one back.</summary>
    public void CancelRecording()
    {
        if (_recording is not { } kind) return;
        _recording = null;
        _host.RestoreShortcut(kind);
        Rebuild();
    }

    // MARK: Building

    public void Rebuild()
    {
        var offset = _scroll.VerticalOffset;
        var stack = new StackPanel { Margin = new Thickness(12, 0, 12, 16) };
        void Add(UIElement? element)
        {
            if (element is null) return;
            if (stack.Children.Count > 0 && element is FrameworkElement framework)
            {
                var margin = framework.Margin;
                framework.Margin = new Thickness(margin.Left, margin.Top + 10, margin.Right, margin.Bottom);
            }
            stack.Children.Add(element);
        }

        // 1. Shortcuts
        Add(Group(
            Row(L.OpenPanelShortcut, ShortcutButton(ShortcutKind.Panel)),
            Row(L.QuickTaskShortcut, ShortcutButton(ShortcutKind.QuickTask)),
            Row(L.QuickNoteShortcut, ShortcutButton(ShortcutKind.QuickNote)),
            Row(L.SwitcherShortcut, ShortcutButton(ShortcutKind.Switcher))));

        // 2. Panel position
        string[] edges = ["right", "left", "top", "bottom"];
        Add(Group(Row(L.PanelPosition, Ui.Segmented(new[] { L.EdgeRight, L.EdgeLeft, L.EdgeTop, L.EdgeBottom },
            Array.IndexOf(edges, Settings.PanelEdge),
            index => Change(settings => settings.PanelEdge = edges[index], reload: false)))));

        // 3–6. Opening
        var methods = Opener.Installed;
        var general = Library.GeneralOpenMethod;
        var methodIndex = Math.Max(0, methods.ToList().IndexOf(general));
        var popup = Ui.Popup(methods.Select(method => method.Title()).ToList(), methodIndex,
            index => { if (methods[index] != Library.GeneralOpenMethod) Change(settings => settings.OpenMethod = methods[index].Key(), reload: false); });
        Add(Group(
            Row(L.OpenChatsIn, popup),
            Row(L.StaysOpen, Ui.Switch(Settings.StaysOpen, on => Change(settings => settings.StaysOpen = on, reload: false))),
            Opener.FirstEditor is not null
                ? Row(L.UsesEditorTerminal, Ui.Switch(Settings.UsesEditorTerminal, on =>
                {
                    Opener.UsesEditorTerminal = on;
                    Change(settings => settings.UsesEditorTerminal = on, reload: false);
                })).Tip(L.UsesEditorTerminalHelp)
                : null,
            Row(L.OpensOtherAccounts, Ui.Switch(Settings.OpensOtherAccountsInTerminal, on => Change(settings => settings.OpensOtherAccountsInTerminal = on, reload: false))),
            Opener.HasWindowsTerminal
                ? Row(L.OpensInTabs, Ui.Switch(Settings.OpensInTabs, on =>
                {
                    Opener.UsesTabs = on;
                    Change(settings => settings.OpensInTabs = on, reload: false);
                }))
                : null));

        // 7. Login and welcome
        Add(Group(
            Row(L.LaunchAtLogin, Ui.Switch(_host.LaunchesAtLogin, on =>
            {
                if (!_host.SetLaunchesAtLogin(on)) _host.Notice(L.LoginItemFailed);
                Rebuild();
            })),
            Row(L.WelcomeRow, Ui.SmallButton(L.View, _host.ShowWelcome))));

        // 8. Notifications
        Add(Group(Row(L.Notifications, Ui.Switch(Settings.NotificationsEnabled, on => Change(settings => settings.NotificationsEnabled = on, reload: false)))));

        // 9. Sections
        Add(SectionsCaption());
        Add(SectionsEditor());

        // 10. Day's summary
        Add(Group(Row(L.DayEndSetting, Ui.Switch(Settings.ShowsDayEnd, on => Change(settings => settings.ShowsDayEnd = on, reload: false)))));

        // 11. Time
        Add(Group(
            Row(L.FollowWork, Ui.Switch(Settings.StartsTimerAutomatically, on => Change(settings => settings.StartsTimerAutomatically = on, reload: false))),
            Row(L.AutomaticTime, Ui.Switch(Settings.TracksTimeAutomatically, on => Change(settings => settings.TracksTimeAutomatically = on, reload: true))),
            Settings.TracksTimeAutomatically
                ? Row(L.IdleGap, Ui.Segmented(Settings.IdleGapChoices.Select(minutes => L.Minutes(minutes)).ToList(),
                    Array.IndexOf(Settings.IdleGapChoices, Settings.IdleGap),
                    index => Change(settings => settings.IdleGapMinutes = Settings.IdleGapChoices[index], reload: true)))
                : null));

        // 12. Theme and language
        string[] appearances = ["", "light", "dark"];
        string[] languages = ["", "tr", "en"];
        Add(Group(
            Row(L.ThemeTitle, Ui.Segmented(new[] { L.SystemLanguage, L.ThemeLight, L.ThemeDark },
                Math.Max(0, Array.IndexOf(appearances, Settings.Appearance)),
                index =>
                {
                    if (Settings.Appearance == appearances[index]) return;
                    Library.ChangeSettings(settings => settings.Appearance = appearances[index], reload: false);
                    _host.ApplyTheme();
                    Rebuild();
                })),
            Row(L.LanguageTitle, Ui.Segmented(new[] { L.SystemLanguage, "Türkçe", "English" },
                Math.Max(0, Array.IndexOf(languages, Settings.Language)),
                index =>
                {
                    if (Settings.Language == languages[index]) return;
                    Library.ChangeSettings(settings => settings.Language = languages[index], reload: false);
                    _host.Relaunch();
                }))));

        // 13. Version and updates
        Add(Group(
            Row(L.VersionTitle(Updates.Installed), VersionControls()),
            Row(L.ReleaseNotes, Ui.SmallButton(L.View, ShowReleaseNotes)),
            Row(L.CheckAutomatically, Ui.Switch(Settings.ChecksForUpdates, on =>
            {
                Change(settings => settings.ChecksForUpdates = on, reload: false);
                if (on) _ = ReleaseNotesPage.CheckIfDue(Library);
            }))));

        // 14. Backups
        var backups = Library.Backups;
        if (backups.Count > 0)
        {
            Add(Group(Row(L.Backups(backups.Count, Format.Bytes(backups.Bytes)),
                Ui.SmallButton(L.Show, () => Opener.RevealFolder(Retention.Folder), L.ShowInFinder))));
        }

        // 15–16. Accounts
        Add(Group(Row(L.ShowAccounts, Ui.Switch(Settings.ShowsOrganizations, on => Change(settings =>
        {
            settings.ShowsOrganizations = on;
            if (!on) settings.OrganizationFilter = null;
        }, reload: true)))));
        if (Settings.ShowsOrganizations)
        {
            var organizations = Library.Current.Organizations;
            if (organizations.Count > 1)
            {
                Add(Caption(L.AccountNames));
                Add(OrganizationEditor(organizations));
            }
            else
            {
                var single = Ui.Label(L.OneOrganization, 11, Ui.T.Secondary, lines: 0);
                single.Margin = new Thickness(4, 0, 4, 0);
                Add(single);
            }
        }

        // 17. Hidden projects
        var hidden = Library.HiddenProjectList;
        if (hidden.Count > 0)
        {
            Add(Caption(L.HiddenProjects));
            Add(Group(hidden.Select(project =>
            {
                var key = project.Key;
                return (UIElement?)Row(project.Name, Ui.SmallButton(L.BringBack, () => { Library.Unhide(key); Rebuild(); }), 34);
            }).ToArray()));
        }

        _scroll.Content = stack;
        _scroll.ScrollToVerticalOffset(offset);
        _scroll.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => _scroll.ScrollToVerticalOffset(offset));
    }

    private void Change(Action<Settings> change, bool reload)
    {
        Library.ChangeSettings(change, reload);
        Rebuild();
    }

    private void ShowReleaseNotes()
    {
        CancelRecording();
        _showReleaseNotes();
    }

    // MARK: Pieces

    private static Border Group(params UIElement?[] rows)
    {
        var stack = new StackPanel();
        foreach (var row in rows) if (row is not null) stack.Children.Add(row);
        return Ui.Box(stack, Ui.T.Overlay(0.06), 9);
    }

    private static FrameworkElement Row(string title, UIElement control, double height = 40)
    {
        var label = Ui.Label(title, 13, Ui.T.Text);
        var row = Ui.Row(new UIElement?[] { label }, null, new UIElement?[] { control }, 8);
        row.MinHeight = height;
        row.Margin = new Thickness(12, 0, 12, 0);
        if (control is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
        return row;
    }

    private static TextBlock Caption(string text)
    {
        var caption = Ui.Label(text, 11, Ui.T.Secondary, FontWeights.SemiBold);
        caption.Margin = new Thickness(4, 0, 4, 0);
        return caption;
    }

    // MARK: Shortcuts

    private FrameworkElement ShortcutButton(ShortcutKind kind)
    {
        var recording = _recording == kind;
        var label = _host.ShortcutLabel(kind);
        var text = Ui.Label(recording ? L.PressKeys : label.Length == 0 ? L.NotAssigned : label, 12,
            recording ? Ui.T.Accent : Ui.T.Text, FontWeights.Medium);
        text.HorizontalAlignment = HorizontalAlignment.Center;
        var button = new Border
        {
            Child = text,
            MinWidth = 96,
            Height = 24,
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(6),
            Background = recording ? Ui.T.Overlay(0.04) : Ui.T.Overlay(0.09),
            BorderBrush = recording ? Ui.T.AccentAt(0.8) : null,
            BorderThickness = new Thickness(recording ? 1.5 : 0),
            Cursor = Cursors.Hand,
            ToolTip = recording ? L.EscToCancel : L.ChangeShortcut,
        };
        button.MouseLeftButtonDown += (_, e) => e.Handled = true;
        button.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            ToggleRecording(kind);
        };
        return button;
    }

    private void ToggleRecording(ShortcutKind kind)
    {
        if (_recording == kind)
        {
            CancelRecording();
            return;
        }
        if (_recording is { } other) _host.RestoreShortcut(other);
        _recording = kind;
        _host.SuspendShortcut(kind);
        Rebuild();
    }

    /// <summary>
    /// A key while a shortcut is being recorded: Esc cancels, a key without Ctrl, Alt or Win is
    /// refused, anything else becomes the new shortcut. True when the key was used.
    /// </summary>
    public bool HandleKey(System.Windows.Input.KeyEventArgs e)
    {
        if (_recording is not { } kind) return false;
        e.Handled = true;
        var key = e.Key switch
        {
            Key.System => e.SystemKey,
            Key.ImeProcessed => e.ImeProcessedKey,
            Key.DeadCharProcessed => e.DeadCharProcessedKey,
            _ => e.Key,
        };
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
            or Key.LWin or Key.RWin or Key.None or Key.CapsLock or Key.NumLock or Key.Scroll) return true;
        if (key == Key.Escape)
        {
            CancelRecording();
            return true;
        }
        var modifiers = Keyboard.Modifiers;
        if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin)) modifiers |= ModifierKeys.Windows;
        if ((modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) == 0)
        {
            _host.Notice(L.ShortcutNeedsModifier);
            return true;
        }
        uint flags = 0;
        var parts = new List<string>();
        if (modifiers.HasFlag(ModifierKeys.Control)) { flags |= 2; parts.Add("Ctrl"); }
        if (modifiers.HasFlag(ModifierKeys.Alt)) { flags |= 1; parts.Add("Alt"); }
        if (modifiers.HasFlag(ModifierKeys.Shift)) { flags |= 4; parts.Add("Shift"); }
        if (modifiers.HasFlag(ModifierKeys.Windows)) { flags |= 8; parts.Add("Win"); }
        parts.Add(KeyName(key));
        var label = string.Join("+", parts);
        var shortcut = new Shortcut(flags, (uint)KeyInterop.VirtualKeyFromKey(key), label);
        _recording = null;
        if (!_host.SetShortcut(kind, shortcut)) _host.Notice(L.ShortcutTaken(label));
        Rebuild();
        return true;
    }

    private static string KeyName(Key key)
    {
        if (key >= Key.A && key <= Key.Z) return key.ToString();
        if (key >= Key.D0 && key <= Key.D9) return ((char)('0' + (key - Key.D0))).ToString();
        if (key >= Key.NumPad0 && key <= Key.NumPad9) return "Num " + (key - Key.NumPad0);
        if (key >= Key.F1 && key <= Key.F24) return "F" + (key - Key.F1 + 1);
        return key switch
        {
            Key.Space => "Space",
            Key.Enter => "Enter",
            Key.Tab => "Tab",
            Key.Back => "Backspace",
            Key.Delete => "Delete",
            Key.Insert => "Insert",
            Key.Left => "Left",
            Key.Right => "Right",
            Key.Up => "Up",
            Key.Down => "Down",
            Key.Home => "Home",
            Key.End => "End",
            Key.PageUp => "PageUp",
            Key.PageDown => "PageDown",
            Key.OemComma => ",",
            Key.OemPeriod => ".",
            Key.OemMinus => "-",
            Key.OemPlus => "=",
            Key.Oem1 => ";",
            Key.Oem2 => "/",
            Key.Oem3 => "`",
            Key.Oem4 => "[",
            Key.Oem5 => "\\",
            Key.Oem6 => "]",
            Key.Oem7 => "'",
            Key.Oem102 => "<",
            Key.Multiply => "Num *",
            Key.Add => "Num +",
            Key.Subtract => "Num -",
            Key.Divide => "Num /",
            Key.Decimal => "Num .",
            Key.PrintScreen => "PrintScreen",
            Key.Pause => "Pause",
            _ => key.ToString(),
        };
    }

    // MARK: Sections

    private FrameworkElement SectionsCaption()
    {
        var title = Ui.Label(L.SectionsTitle, 11, Ui.T.Secondary, FontWeights.SemiBold);
        var resetText = Ui.Label(L.ResetOrder, 11, Ui.T.Secondary);
        var reset = Ui.Hover(resetText, () => Change(settings =>
        {
            settings.SectionOrder = PanelSection.All.ToList();
            settings.HiddenSections.Clear();
            settings.ShowsTodos = true;
            settings.ShowsWeek = true;
            settings.ShowsTime = true;
        }, reload: false), radius: 4, padding: new Thickness(4, 1, 4, 1));
        var row = Ui.Row(new UIElement?[] { title }, null, new UIElement?[] { reset });
        row.Margin = new Thickness(4, 0, 0, 0);
        return row;
    }

    private bool IsShown(string section) => section switch
    {
        PanelSection.Todos => Settings.ShowsTodos,
        PanelSection.Week => Settings.ShowsWeek,
        PanelSection.TimeSection => Settings.ShowsTime,
        _ => !Settings.HiddenSections.Contains(section),
    };

    private static void SetShown(Settings settings, string section, bool on)
    {
        switch (section)
        {
            case PanelSection.Todos: settings.ShowsTodos = on; break;
            case PanelSection.Week: settings.ShowsWeek = on; break;
            case PanelSection.TimeSection: settings.ShowsTime = on; break;
            default:
                settings.HiddenSections.Remove(section);
                if (!on) settings.HiddenSections.Add(section);
                break;
        }
    }

    private Border SectionsEditor()
    {
        var order = Settings.SectionOrder;
        var rows = new List<UIElement?>();
        foreach (var section in order)
        {
            var shown = IsShown(section);
            var grip = Ui.Icon("", 12, Ui.T.Tertiary);
            grip.Width = 16;
            var name = Ui.Label(PanelSection.Title(section), 13, shown ? Ui.T.Text : Ui.T.Tertiary);
            var toggle = Ui.Switch(shown, on => Change(settings => SetShown(settings, section, on), reload: false));
            toggle.Margin = new Thickness(4, 0, 0, 0);
            var content = Ui.Row(new UIElement?[] { grip, name }, null, new UIElement?[] { toggle }, 8);
            content.MinHeight = 36;
            rows.Add(DraggableSection(section, content));
        }
        rows.Add(Row(L.CompactRows, Ui.Switch(Settings.Compact, on => Change(settings => settings.Compact = on, reload: false))));
        return Group(rows.ToArray());
    }

    private const string SectionDrag = "Respool.Section";

    /// <summary>
    /// A section's row that is dragged into a new place: dropped on the upper half of another
    /// row it goes before it, on the lower half after it. A line shows where it will land.
    /// </summary>
    private FrameworkElement DraggableSection(string section, FrameworkElement content)
    {
        var row = new Border
        {
            Child = content,
            Padding = new Thickness(12, 0, 12, 0),
            Background = Brushes.Transparent,
            BorderBrush = Ui.T.Accent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.SizeAll,
            AllowDrop = true,
        };
        var start = (Point?)null;
        row.PreviewMouseLeftButtonDown += (_, e) => start = e.GetPosition(row);
        row.PreviewMouseLeftButtonUp += (_, _) => start = null;
        row.MouseMove += (_, e) =>
        {
            if (start is not { } from || e.LeftButton != MouseButtonState.Pressed) return;
            if ((e.GetPosition(row) - from).Length < 4) return;
            start = null;
            row.Opacity = 0.45;
            DragDrop.DoDragDrop(row, new DataObject(SectionDrag, section), DragDropEffects.Move);
            row.Opacity = 1;
        };
        bool Accepts(DragEventArgs e) => e.Data.GetData(SectionDrag) is string moved && moved != section;
        bool After(DragEventArgs e) => e.GetPosition(row).Y > row.ActualHeight / 2;
        row.DragOver += (_, e) =>
        {
            var ok = Accepts(e);
            e.Effects = ok ? DragDropEffects.Move : DragDropEffects.None;
            row.BorderThickness = ok ? (After(e) ? new Thickness(0, 0, 0, 2) : new Thickness(0, 2, 0, 0)) : new Thickness(0);
            e.Handled = true;
        };
        row.DragLeave += (_, _) => row.BorderThickness = new Thickness(0);
        row.Drop += (_, e) =>
        {
            row.BorderThickness = new Thickness(0);
            if (!Accepts(e) || e.Data.GetData(SectionDrag) is not string moved) return;
            var after = After(e);
            e.Handled = true;
            Change(settings =>
            {
                var order = settings.SectionOrder;
                order.Remove(moved);
                var index = order.IndexOf(section);
                if (index < 0) { order.Add(moved); return; }
                order.Insert(after ? index + 1 : index, moved);
            }, reload: false);
        };
        return row;
    }

    // MARK: Version

    private FrameworkElement VersionControls()
    {
        var state = ReleaseNotesPage.CheckState;
        var checking = state == ReleaseNotesPage.Checking;
        UIElement? status = null;
        if (checking) status = Ui.Label(L.Checking, 11, Ui.T.Secondary);
        else if (state == ReleaseNotesPage.Failed) status = Ui.Label(L.CheckFailed, 11, Ui.T.Secondary);
        else if (ReleaseNotesPage.Available is { } release)
        {
            var text = Ui.Label(L.UpdateAvailable(release.Version), 11, Ui.T.Accent, FontWeights.Medium);
            status = Ui.Hover(text, ShowReleaseNotes, radius: 4, padding: new Thickness(4, 1, 4, 1)).Tip(L.ReleaseNotes);
        }
        else if (ReleaseNotesPage.Releases is not null) status = Ui.Label(L.UpToDate, 11, Ui.T.Secondary);

        var check = Ui.SmallButton(L.CheckNow, () =>
        {
            if (ReleaseNotesPage.CheckState != ReleaseNotesPage.Checking) _ = ReleaseNotesPage.CheckAsync(Library);
        });
        if (checking)
        {
            check.Opacity = 0.4;
            check.IsHitTestVisible = false;
        }
        return Ui.HStack(8, status, check);
    }

    // MARK: Accounts

    private Border OrganizationEditor(IReadOnlyList<Organization> organizations)
    {
        var stack = new StackPanel();
        var save = Ui.SmallButton(L.SaveNames, () => SaveNames(organizations));
        save.HorizontalAlignment = HorizontalAlignment.Right;
        save.Margin = new Thickness(0, 6, 0, 0);
        void Refresh() => save.Visibility = IsEdited(organizations) ? Visibility.Visible : Visibility.Collapsed;

        for (var index = 0; index < organizations.Count; index++)
        {
            var organization = organizations[index];
            var id = organization.Id;
            var (field, box) = Ui.Field(L.AccountName, 12, _ => SaveNames(organizations), _drafts.GetValueOrDefault(id) ?? organization.Name);
            box.TextChanged += (_, _) =>
            {
                if (box.Text == organization.Name) _drafts.Remove(id);
                else _drafts[id] = box.Text;
                Refresh();
            };
            var state = Ui.Label(L.AccountState(organization.SessionCount, organization.IsCurrent), 11, Ui.T.Tertiary);
            var row = Ui.Row(Array.Empty<UIElement?>(), field, new UIElement?[] { state }, 8);
            var box2 = Ui.Box(row, Ui.T.Overlay(0.07), 8, new Thickness(10, 0, 10, 0));
            box2.MinHeight = 30;
            if (index > 0) box2.Margin = new Thickness(0, 4, 0, 0);
            stack.Children.Add(box2);
        }
        stack.Children.Add(save);
        Refresh();
        return Ui.Box(stack);
    }

    private bool IsEdited(IReadOnlyList<Organization> organizations) =>
        organizations.Any(organization => _drafts.TryGetValue(organization.Id, out var text) && text.Trim() != organization.Name);

    private void SaveNames(IReadOnlyList<Organization> organizations)
    {
        var edits = organizations
            .Where(organization => _drafts.TryGetValue(organization.Id, out var text) && text.Trim() != organization.Name)
            .Select(organization => (organization, _drafts[organization.Id]))
            .ToList();
        _drafts.Clear();
        foreach (var (organization, name) in edits) Library.Rename(organization, name);
        Rebuild();
    }
}
