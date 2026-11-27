using System.Text.Json;
using System.Text.Json.Serialization;

namespace Respool.Core;

/// <summary>A global shortcut: Windows modifier flags (MOD_ALT 1, MOD_CONTROL 2, MOD_SHIFT 4, MOD_WIN 8) and a virtual key.</summary>
public sealed record Shortcut(uint Modifiers, uint Key, string Label);

/// <summary>
/// The preferences, kept in <c>%APPDATA%\Respool\settings.json</c>. The names and defaults are
/// the macOS app's.
/// </summary>
public sealed class Settings
{
    public string PanelTab { get; set; } = "chats";
    public List<string> SectionOrder { get; set; } = PanelSection.All.ToList();
    public List<string> HiddenSections { get; set; } = new();
    public bool ShowsTodos { get; set; } = true;
    public bool ShowsWeek { get; set; } = true;
    public bool ShowsTime { get; set; } = true;
    public List<string> CollapsedSections { get; set; } = new();
    public bool Compact { get; set; }
    public bool ShowsDayEnd { get; set; } = true;
    public string DayEndDismissed { get; set; } = "";
    public List<string> ExpandedProjects { get; set; } = new();
    public bool CalendarExpanded { get; set; }
    public int ProjectSort { get; set; }
    public bool HidesSingleSessionProjects { get; set; }
    public bool HidesInactiveProjects { get; set; }
    public List<string> HiddenProjects { get; set; } = new();
    public int TimePeriod { get; set; }
    public bool TracksTimeAutomatically { get; set; } = true;
    public int IdleGapMinutes { get; set; } = 15;
    public bool StartsTimerAutomatically { get; set; }
    public string OpenMethod { get; set; } = "automatic";
    public bool OpensInTabs { get; set; } = true;
    public bool OpensOtherAccountsInTerminal { get; set; } = true;
    public bool StaysOpen { get; set; }
    public bool ShowsOrganizations { get; set; }
    public string? OrganizationFilter { get; set; }
    public string PanelEdge { get; set; } = "right";
    /// <summary>"x,y,width,height" in device-independent units, for the free position.</summary>
    public string? PanelFrame { get; set; }
    public bool NotificationsEnabled { get; set; } = true;
    public bool ChecksForUpdates { get; set; }
    public double LastUpdateCheck { get; set; }
    public string Appearance { get; set; } = "";
    public string Language { get; set; } = "";
    public bool DidOnboard { get; set; }

    public Shortcut? PanelShortcut { get; set; } = new(1 | 4, 0x20, "Alt+Shift+Space");
    public Shortcut? TaskShortcut { get; set; } = new(1 | 4, 0x54, "Alt+Shift+T");
    public Shortcut? NoteShortcut { get; set; } = new(1 | 4, 0x4E, "Alt+Shift+N");
    public Shortcut? SwitcherShortcut { get; set; } = new(1 | 4, 0x4F, "Alt+Shift+O");

    public static readonly int[] IdleGapChoices = [5, 10, 15, 30];

    [JsonIgnore] public int IdleGap => IdleGapChoices.Contains(IdleGapMinutes) ? IdleGapMinutes : 15;

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    [JsonIgnore] public string? FilePath { get; private set; }

    public static Settings Load(string? path = null)
    {
        path ??= Path.Combine(Paths.Support, "settings.json");
        Settings settings;
        try { settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Options) ?? new Settings(); }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { settings = new Settings(); }
        settings.FilePath = path;
        settings.Tidy();
        return settings;
    }

    /// <summary>Sections the saved order lacks go back in at their usual place; unknown ones go.</summary>
    private void Tidy()
    {
        var order = SectionOrder.Where(section => PanelSection.All.Contains(section)).Distinct().ToList();
        for (var index = 0; index < PanelSection.All.Length; index++)
        {
            var section = PanelSection.All[index];
            if (!order.Contains(section)) order.Insert(Math.Min(index, order.Count), section);
        }
        SectionOrder = order;
    }

    public void Save()
    {
        if (FilePath is null) return;
        try
        {
            var temporary = FilePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, Options));
            File.Move(temporary, FilePath, overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
