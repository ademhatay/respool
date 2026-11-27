namespace Respool.Core;

/// <summary>One Claude Code session, as the index knows it.</summary>
public sealed record SessionRecord
{
    public required string Id { get; init; }
    public required string Path { get; init; }
    public string Cwd { get; init; } = "";
    public string? CustomTitle { get; init; }
    public string? AiTitle { get; init; }
    /// <summary>A name given in Respool only. The transcript is never touched.</summary>
    public string? LocalName { get; init; }
    public string? FirstPrompt { get; init; }
    public string? LastPrompt { get; init; }
    public DateTimeOffset? LastActivity { get; init; }
    public DateTimeOffset? FirstActivity { get; init; }
    public int? PrNumber { get; init; }
    public string? PrUrl { get; init; }
    /// <summary>How many prompts were typed.</summary>
    public int MessageCount { get; init; }
    public string? Branch { get; init; }
    public long FileSize { get; init; }
    public long InputTokens { get; init; }
    public long CachedTokens { get; init; }
    public long OutputTokens { get; init; }
    public long? ContextTokens { get; init; }
    public string? Model { get; init; }
    /// <summary>"cli", "claude-desktop", "claude-vscode".</summary>
    public string? Entrypoint { get; init; }
    public string ProjectKey { get; init; } = "";
    public string ProjectName { get; init; } = "";
    public IReadOnlyList<long> TagIds { get; init; } = Array.Empty<long>();
    public string? OrganizationId { get; init; }
    public string? OrganizationName { get; init; }
    public bool InOtherOrganization { get; init; }

    public string Title
    {
        get
        {
            if (!string.IsNullOrEmpty(LocalName)) return LocalName!;
            return OriginalTitle;
        }
    }

    /// <summary>The title the session would have without a name given in Respool.</summary>
    public string OriginalTitle
    {
        get
        {
            if (!string.IsNullOrEmpty(CustomTitle)) return CustomTitle!;
            if (!string.IsNullOrEmpty(AiTitle)) return AiTitle!;
            var prompt = (FirstPrompt ?? LastPrompt ?? "").Trim();
            var line = prompt.Split('\n', 2)[0].Trim();
            return line.Length == 0 ? L.UntitledChat : line.Length > 80 ? line[..80] : line;
        }
    }

    public bool HasCustomTitle => !string.IsNullOrEmpty(CustomTitle) || !string.IsNullOrEmpty(LocalName);

    public long TokenUse => InputTokens + CachedTokens + OutputTokens;

    /// <summary>The project, plus the organization when the session lives in one that is not open.</summary>
    public string PlaceLabel => InOtherOrganization && OrganizationName is not null ? $"{ProjectName} · {OrganizationName}" : ProjectName;
}

public sealed record Tag(long Id, string Name, int Color);

public sealed record Organization(string Id, string Name, bool IsCurrent, int SessionCount);

public sealed record TaskItem
{
    public required long Id { get; init; }
    public string SessionId { get; init; } = "";
    public required string Text { get; init; }
    public bool Done { get; init; }
    public DateTimeOffset? DoneAt { get; init; }
    /// <summary>The day the task is planned for, as <c>yyyy-MM-dd</c>.</summary>
    public string? Due { get; init; }
    public string? ProjectKey { get; init; }
    public double Created { get; init; }
    public double? Position { get; init; }

    public double Rank => Position ?? Created;
}

/// <summary>What a new task will be attached to.</summary>
public abstract record TaskLink(string Title)
{
    public sealed record ToSession(string Id, string SessionTitle) : TaskLink(SessionTitle);
    public sealed record ToProject(string Key, string Name) : TaskLink(Name);
}

public sealed record PinnedSession(SessionRecord Session, IReadOnlyList<TaskItem> Tasks)
{
    public string Id => Session.Id;
    public int OpenCount => Tasks.Count(task => !task.Done);
}

public sealed record DayWork(SessionRecord Session, int Prompts);

public sealed record DaySummary(string Day, IReadOnlyList<DayWork> Work)
{
    public int Prompts => Work.Sum(work => work.Prompts);
}

public sealed record ProjectGroup(string Key, string Name, IReadOnlyList<SessionRecord> Sessions, IReadOnlyList<string> Folders, IReadOnlyList<string> MergedKeys)
{
    public DateTimeOffset? LastActivity => Sessions.Count > 0 ? Sessions[0].LastActivity : null;
    public long TokenUse => Sessions.Sum(session => session.TokenUse);
}

public enum ProjectSort { Activity, Name, Sessions, Tokens }

public static class ProjectSorting
{
    public static string Title(this ProjectSort sort) => sort switch
    {
        ProjectSort.Name => L.SortName,
        ProjectSort.Sessions => L.SortSessions,
        ProjectSort.Tokens => L.SortTokens,
        _ => L.SortActivity,
    };

    /// <summary>Largest figure first; ties by name, then key, so the list never shuffles.</summary>
    public static IEnumerable<ProjectGroup> Sorted(this IEnumerable<ProjectGroup> projects, ProjectSort sort) =>
        projects.OrderByDescending(project => Figure(project, sort))
            .ThenBy(project => project.Name, NaturalComparer.Instance)
            .ThenBy(project => project.Key, StringComparer.Ordinal);

    private static double Figure(ProjectGroup project, ProjectSort sort) => sort switch
    {
        ProjectSort.Activity => project.LastActivity is { } date ? Time.Seconds(date) : double.NegativeInfinity,
        ProjectSort.Sessions => project.Sessions.Count,
        ProjectSort.Tokens => project.TokenUse,
        _ => 0,
    };
}

/// <summary>Finder-like ordering: case-insensitive, numbers by value.</summary>
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    public int Compare(string? x, string? y) => StrCmpLogicalW(x ?? "", y ?? "");

    [System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int StrCmpLogicalW(string x, string y);
}

public sealed record Snippet(string Text, IReadOnlyList<(int Start, int End)> Matches);

public sealed record SearchHit(SessionRecord Session, Snippet? Snippet, long? MatchRow);

public sealed record OutlineEntry(long Id, string Text, DateTimeOffset? Date);

public sealed record SessionOutline(SessionRecord Session, IReadOnlyList<OutlineEntry> Entries, long? Focus);

public sealed record NoteItem(long Id, string Text, DateTimeOffset? Created);

public sealed record ActivitySeries(string Key, IReadOnlyList<int> Buckets, string StartLabel, string EndLabel, double? Worked);

public enum PanelTab { Today, Chats, Time }

public static class PanelSection
{
    public const string Waiting = "waiting";
    /// <summary>The chats prompts were typed in today, on the Today tab.</summary>
    public const string TodayChats = "todaychats";
    public const string Todos = "todos";
    public const string Notes = "notes";
    public const string Pinned = "pinned";
    public const string Recent = "recent";
    public const string Week = "week";
    public const string TimeSection = "time";
    public const string Projects = "projects";

    public static readonly string[] All = [Waiting, TodayChats, Todos, Notes, Pinned, Recent, TimeSection, Week, Projects];

    public static PanelTab Tab(string section) => section switch
    {
        Waiting or TodayChats or Todos or Notes => PanelTab.Today,
        TimeSection or Week => PanelTab.Time,
        _ => PanelTab.Chats,
    };

    public static string Title(string section) => section switch
    {
        Waiting => L.WaitingTitle,
        TodayChats => L.TodayChatsTitle,
        Todos => L.TodosTitle,
        Notes => L.NotesTitle,
        Pinned => L.PinnedTitle,
        Recent => L.RecentTitle,
        TimeSection => L.TimeTitle,
        Week => L.WeekTitle,
        _ => L.ProjectsTitle,
    };
}

// MARK: Time tracking

/// <summary>A stretch of time, as seconds since 1970.</summary>
public readonly record struct Span(double Start, double End)
{
    public double Length => Math.Max(End - Start, 0);
}

public enum TimePeriod { Today, Week, Month }

public sealed record ProjectTime(string Key, string Name, double Manual, double Automatic, double Total, int? Color)
{
    /// <summary>For today only: when the timer ran and when the prompts suggest work.</summary>
    public IReadOnlyList<Span> Timed { get; init; } = Array.Empty<Span>();
    public IReadOnlyList<Span> Guessed { get; init; } = Array.Empty<Span>();
}

public sealed record DayTime(string Day, DateTime Date, IReadOnlyDictionary<string, double> Parts)
{
    public double Total => Parts.Values.Sum();
}

public sealed record TimeReport(IReadOnlyList<ProjectTime> Rows, double Total, double Start, double End, IReadOnlyList<DayTime> Days)
{
    public static readonly TimeReport Empty = new(Array.Empty<ProjectTime>(), 0, 0, 0, Array.Empty<DayTime>());
}

public sealed record RunningTimer(long Id, string ProjectKey, string ProjectName, DateTimeOffset Started);

public sealed record TimeEntry(long Id, double Length);

public static class TimeMath
{
    /// <summary>Moments closer together than <paramref name="gap"/> are one stretch. Stamps must be sorted.</summary>
    public static List<Span> Blocks(IEnumerable<double> stamps, double gap)
    {
        var spans = new List<Span>();
        foreach (var stamp in stamps)
        {
            if (spans.Count > 0 && stamp - spans[^1].End <= gap)
                spans[^1] = spans[^1] with { End = Math.Max(spans[^1].End, stamp) };
            else
                spans.Add(new Span(stamp, stamp));
        }
        return spans;
    }

    /// <summary>The same time with overlaps joined, in order.</summary>
    public static List<Span> Merged(IEnumerable<Span> spans)
    {
        var result = new List<Span>();
        foreach (var span in spans.Where(span => span.End > span.Start).OrderBy(span => span.Start))
        {
            if (result.Count > 0 && span.Start <= result[^1].End)
                result[^1] = result[^1] with { End = Math.Max(result[^1].End, span.End) };
            else
                result.Add(span);
        }
        return result;
    }

    public static List<Span> Clipped(IEnumerable<Span> spans, double from, double to) =>
        spans.Select(span => new Span(Math.Max(span.Start, from), Math.Min(span.End, to)))
            .Where(span => span.End > span.Start).ToList();

    public static double Length(IEnumerable<Span> spans) => spans.Sum(span => span.Length);
}

// MARK: Opening sessions

/// <summary>Where a session is opened. The name is what is saved.</summary>
public enum OpenMethod
{
    /// <summary>The Claude app for a session it tracks, a terminal for the rest.</summary>
    Automatic,
    Desktop,
    /// <summary>Windows Terminal when installed, else a console window.</summary>
    Terminal,
    VsCode,
    Cursor,
    Zed,
}

public static class OpenMethods
{
    public static string Title(this OpenMethod method) => method switch
    {
        OpenMethod.Automatic => L.OpenAutomatic,
        OpenMethod.Desktop => "Claude",
        OpenMethod.Terminal => "Terminal",
        OpenMethod.VsCode => "VS Code",
        OpenMethod.Cursor => "Cursor",
        _ => "Zed",
    };

    public static bool IsEditor(this OpenMethod method) => method is OpenMethod.VsCode or OpenMethod.Cursor or OpenMethod.Zed;

    /// <summary>The saved names of the macOS app map onto these; iTerm becomes Terminal.</summary>
    public static OpenMethod? Parse(string? text) => text switch
    {
        "automatic" => OpenMethod.Automatic,
        "desktop" => OpenMethod.Desktop,
        "terminal" or "iterm" => OpenMethod.Terminal,
        "vscode" => OpenMethod.VsCode,
        "cursor" => OpenMethod.Cursor,
        "zed" => OpenMethod.Zed,
        _ => null,
    };

    public static string Key(this OpenMethod method) => method switch
    {
        OpenMethod.Automatic => "automatic",
        OpenMethod.Desktop => "desktop",
        OpenMethod.Terminal => "terminal",
        OpenMethod.VsCode => "vscode",
        OpenMethod.Cursor => "cursor",
        _ => "zed",
    };
}

/// <summary>Keys for the rows of the panel, so a selection survives a reload.</summary>
public static class RowKey
{
    public static string Pin(string id) => "pin:" + id;
    public static string Recent(string id) => "recent:" + id;
    public static string Project(string id) => "project:" + id;
    public static string Day(string day, string id) => "day:" + day + ":" + id;
    public static string Hit(string id) => "hit:" + id;
    public static string Tagged(string id) => "tagged:" + id;
    public static string Waiting(string id) => "waiting:" + id;
    public static string Today(string id) => "today:" + id;
    public static string Page(string id) => "page:" + id;

    public static string SessionId(string key)
    {
        var parts = key.Split(':', 3);
        return parts[^1];
    }
}
