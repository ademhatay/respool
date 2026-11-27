using System.Text;
using System.Text.RegularExpressions;

namespace Respool.Core;

/// <summary>A session that wants the user: waiting for an answer, or finished since last looked.</summary>
public sealed record Announcement(string SessionId, SessionRecord? Session, LiveSession Live);

/// <summary>
/// The data behind the panel: the index, the user's own pins, tasks, notes, tags and timer, and
/// what is running now. Reads happen on background threads; every method that changes data
/// saves it and builds a new snapshot. Not tied to any UI framework.
/// </summary>
public sealed class Library : IDisposable
{
    public const int ProjectPreviewCount = 8;
    public const double FinishThreshold = 8;
    public const int DayEndHour = 17;

    private readonly Database _indexDb;
    private readonly Database _readDb;
    private readonly Database _userDb;
    private readonly object _indexLock = new();
    private readonly object _readLock = new();
    private readonly object _userLock = new();
    private readonly Action<Action> _post;

    public Settings Settings { get; }
    public Snapshot Current { get; private set; } = Snapshot.Empty;
    public bool HasLoaded { get; private set; }
    public (int Done, int Total)? Indexing { get; private set; }
    public bool Unreachable { get; private set; }
    public int SessionCount => Current.Sessions.Count;
    public (int Count, long Bytes) Backups { get; private set; }

    /// <summary>Not saved: a tag picked to filter by.</summary>
    public long? TagFilter { get; private set; }

    /// <summary>Raised on the UI thread after a new snapshot is in place.</summary>
    public event Action? Changed;
    /// <summary>Raised on the UI thread when live states change.</summary>
    public event Action? LiveChanged;
    /// <summary>Raised on the UI thread for a short message in the footer.</summary>
    public event Action<string>? Notice;
    /// <summary>Raised on the UI thread when a session starts waiting or finishes.</summary>
    public event Action<Announcement>? Attention;
    /// <summary>Raised on the UI thread while indexing, with how far it got.</summary>
    public event Action? Progress;

    public IReadOnlyDictionary<string, LiveSession> Live { get; private set; } = new Dictionary<string, LiveSession>();
    /// <summary>Sessions that finished or started waiting since the panel was last opened.</summary>
    public HashSet<string> AttentionSet { get; } = new();
    private readonly Dictionary<string, DateTimeOffset> _workingSince = new();
    private bool _hasLiveBaseline;
    private string? _followedProject;
    private DateTimeOffset _lastWork = DateTimeOffset.MinValue;
    private HashSet<string> _previouslyWorking = new();

    public Library(Settings settings, Action<Action> post, string? databasePath = null)
    {
        Settings = settings;
        _post = post;
        var path = databasePath ?? Paths.Database;
        _indexDb = Schema.Open(path);
        _readDb = new Database(path);
        _userDb = new Database(path);
        RestoreTimer();
    }

    public void Dispose()
    {
        RecordHeartbeat();
        _indexDb.Dispose();
        _readDb.Dispose();
        _userDb.Dispose();
    }

    // MARK: Loading

    private int _refreshing;

    /// <summary>Indexes what changed in the background, then reloads.</summary>
    public void Refresh()
    {
        if (Interlocked.Exchange(ref _refreshing, 1) == 1) return;
        Task.Run(() =>
        {
            try
            {
                var lastReload = DateTime.UtcNow;
                var count = 0;
                IndexStats stats;
                lock (_indexLock)
                {
                    stats = Indexer.Run(_indexDb,
                        progress: (done, total) =>
                        {
                            if (++count % 4 != 0 && done != total) return;
                            _post(() => { Indexing = (done, total); Progress?.Invoke(); });
                        },
                        written: () =>
                        {
                            if ((DateTime.UtcNow - lastReload).TotalSeconds < 1) return;
                            lastReload = DateTime.UtcNow;
                            ReloadNow();
                        });
                    ProjectResolver.Refresh(_indexDb);
                }
                _post(() => { Indexing = null; Unreachable = stats.Unreachable; });
                ReloadNow();
            }
            finally
            {
                Interlocked.Exchange(ref _refreshing, 0);
            }
        });
    }

    private Arrangement CurrentArrangement() => new(
        Settings.ShowsOrganizations ? Settings.OrganizationFilter : null,
        TagFilter,
        Settings.ShowsOrganizations,
        (ProjectSort)Settings.ProjectSort,
        Settings.HidesSingleSessionProjects,
        Settings.HidesInactiveProjects,
        Settings.HiddenProjects.ToHashSet(),
        Settings.TracksTimeAutomatically,
        Settings.IdleGap * 60.0);

    /// <summary>Builds a new snapshot in the background and puts it in place.</summary>
    public void Reload() => Task.Run(ReloadNow);

    private void ReloadNow()
    {
        var arrangement = CurrentArrangement();
        Snapshot snapshot;
        try
        {
            lock (_readLock) snapshot = SnapshotBuilder.Build(_readDb, arrangement, LiveSessions.Load(), DesktopSessions.Load());
        }
        catch (Microsoft.Data.Sqlite.SqliteException)
        {
            return;
        }
        var backups = Retention.CountBackups();
        _post(() =>
        {
            if (arrangement.TagFilter != TagFilter) return;
            Apply(snapshot);
            Backups = backups;
        });
    }

    /// <summary>The same, waiting for it. For start-up and the check program.</summary>
    public void ReloadSync()
    {
        Snapshot snapshot;
        lock (_readLock) snapshot = SnapshotBuilder.Build(_readDb, CurrentArrangement(), LiveSessions.Load(), DesktopSessions.Load());
        Apply(snapshot);
        Backups = Retention.CountBackups();
    }

    /// <summary>Indexes and resolves projects, waiting for it.</summary>
    public IndexStats IndexSync()
    {
        lock (_indexLock)
        {
            var stats = Indexer.Run(_indexDb);
            ProjectResolver.Refresh(_indexDb);
            Unreachable = stats.Unreachable;
            return stats;
        }
    }

    private void Apply(Snapshot snapshot)
    {
        Current = snapshot;
        if (TagFilter is { } tag && snapshot.Tags.All(item => item.Id != tag)) TagFilter = null;
        if (Settings.OrganizationFilter is { } organization && snapshot.Organizations.All(item => item.Id != organization))
        {
            Settings.OrganizationFilter = null;
            Settings.Save();
        }
        if (!snapshot.Hidden.SetEquals(Settings.HiddenProjects))
        {
            Settings.HiddenProjects = snapshot.Hidden.OrderBy(key => key, StringComparer.Ordinal).ToList();
            Settings.Save();
        }
        HasLoaded = true;
        IngestLive(snapshot.Live);
        Changed?.Invoke();
    }

    public void SetTagFilter(long? tag)
    {
        TagFilter = TagFilter == tag ? null : tag;
        Reload();
    }

    public SessionRecord? Session(string id) => Current.ById.GetValueOrDefault(id);

    /// <summary>Saves a change to the settings and builds a new snapshot.</summary>
    public void ChangeSettings(Action<Settings> change, bool reload = true)
    {
        change(Settings);
        Settings.Save();
        // A change that does not alter the data still alters what is drawn (a folded section,
        // the month calendar), so the views are told either way.
        if (reload) Reload();
        else Changed?.Invoke();
    }

    // MARK: Writing the user's data

    private bool Write(Action<Database> body)
    {
        var ok = true;
        try
        {
            lock (_userLock) _userDb.Transaction(() => body(_userDb));
        }
        catch (Microsoft.Data.Sqlite.SqliteException)
        {
            ok = false;
            Notice?.Invoke(L.CouldNotSave);
        }
        Reload();
        return ok;
    }

    private static double Now => Time.Seconds(DateTimeOffset.Now);

    // Pins

    public bool IsPinned(string id) => Current.Pinned.Any(pin => pin.Id == id);

    public void TogglePin(string id)
    {
        var pinned = IsPinned(id);
        Write(db =>
        {
            if (pinned) db.Run("DELETE FROM pins WHERE session_id = $1", id);
            else db.Run("INSERT OR REPLACE INTO pins(session_id, position) VALUES($1, (SELECT COALESCE(MAX(position), 0) + 1 FROM pins))", id);
        });
    }

    public void MovePin(string id, string target, bool after)
    {
        var order = Current.Pinned.Select(pin => pin.Id).Where(other => other != id).ToList();
        var index = order.IndexOf(target);
        if (index < 0) return;
        order.Insert(after ? index + 1 : index, id);
        Write(db =>
        {
            for (var position = 0; position < order.Count; position++) db.Run("UPDATE pins SET position = $1 WHERE session_id = $2", position + 1, order[position]);
        });
    }

    // Tasks

    public void AddTask(string text, string sessionId)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        Write(db => db.Run("INSERT INTO tasks(session_id, text, done, created) VALUES($1, $2, 0, $3)", sessionId, trimmed, Now));
    }

    /// <summary>A to-do on a day, attached to a session or project when a link is given.</summary>
    public void AddTodo(string text, string? due, TaskLink? link)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        var session = link is TaskLink.ToSession toSession ? toSession.Id : "";
        var project = link is TaskLink.ToProject toProject ? toProject.Key : null;
        Write(db => db.Run("INSERT INTO tasks(session_id, text, done, created, due, project_key) VALUES($1, $2, 0, $3, $4, $5)",
            session, trimmed, Now, due, project));
    }

    public void Toggle(TaskItem task) =>
        Write(db => db.Run("UPDATE tasks SET done = $1, done_at = $2 WHERE id = $3", !task.Done, task.Done ? null : Now, task.Id));

    public void Delete(TaskItem task) => Write(db => db.Run("DELETE FROM tasks WHERE id = $1", task.Id));

    public void SetDue(TaskItem task, string? day) => Write(db => db.Run("UPDATE tasks SET due = $1 WHERE id = $2", day, task.Id));

    public void Link(TaskItem task, string? projectKey) =>
        Write(db => db.Run("UPDATE tasks SET project_key = $1, session_id = '' WHERE id = $2", projectKey, task.Id));

    /// <summary>Moves an open task next to another in the same list.</summary>
    public void MoveTask(TaskItem task, IReadOnlyList<TaskItem> list, TaskItem target, bool after)
    {
        var open = list.Where(item => !item.Done && item.Id != task.Id).ToList();
        var index = open.FindIndex(item => item.Id == target.Id);
        if (index < 0) return;
        var at = after ? index + 1 : index;
        double? previous = at > 0 ? open[at - 1].Rank : null;
        double? next = at < open.Count ? open[at].Rank : null;
        var rank = (previous, next) switch
        {
            ({ } a, { } b) => (a + b) / 2,
            ({ } a, null) => a + 1,
            (null, { } b) => b - 1,
            _ => 1,
        };
        var fits = (previous is null || rank > previous) && (next is null || rank < next);
        open.Insert(at, task);
        Write(db =>
        {
            if (fits)
            {
                db.Run("UPDATE tasks SET position = $1 WHERE id = $2", rank, task.Id);
                return;
            }
            for (var position = 0; position < open.Count; position++) db.Run("UPDATE tasks SET position = $1 WHERE id = $2", position + 1, open[position].Id);
        });
    }

    public IEnumerable<TaskItem> TasksOn(string day) => Current.Tasks.Where(task => task.Due == day);

    public IReadOnlyList<TaskItem> OverdueTasks =>
        Current.Tasks.Where(task => !task.Done && task.Due is { } due && string.CompareOrdinal(due, Format.Today) < 0)
            .OrderBy(task => task.Due, StringComparer.Ordinal).ThenBy(task => task.Id).ToList();

    public IReadOnlyList<TaskItem> UndatedTasks
    {
        get
        {
            var pinned = Current.Pinned.Select(pin => pin.Id).ToHashSet();
            return Current.Tasks.Where(task => task.Due is null && !pinned.Contains(task.SessionId)).ToList();
        }
    }

    public int OpenListedTaskCount
    {
        get
        {
            var pinned = Current.Pinned.Select(pin => pin.Id).ToHashSet();
            return Current.Tasks.Count(task => !task.Done && (task.Due is not null || !pinned.Contains(task.SessionId)));
        }
    }

    public int OpenTaskCount(string day) => Current.Tasks.Count(task => !task.Done && task.Due == day);

    /// <summary>What a task is attached to, for its detail line.</summary>
    public TaskLink? LinkOf(TaskItem task)
    {
        if (task.SessionId.Length > 0 && Session(task.SessionId) is { } session) return new TaskLink.ToSession(session.Id, session.Title);
        if (task.ProjectKey is { } key && Current.AllProjects.FirstOrDefault(project => project.Key == key || project.MergedKeys.Contains(key)) is { } found)
            return new TaskLink.ToProject(found.Key, found.Name);
        return null;
    }

    public IReadOnlyList<TaskItem> TasksOf(ProjectGroup project)
    {
        var keys = project.MergedKeys.Append(project.Key).ToHashSet();
        var sessions = project.Sessions.Select(session => session.Id).ToHashSet();
        return Current.Tasks.Where(task => !task.Done && ((task.ProjectKey is { } key && keys.Contains(key)) || sessions.Contains(task.SessionId))).ToList();
    }

    // Notes

    public void AddNote(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        Write(db => db.Run("INSERT INTO notes(text, created) VALUES($1, $2)", trimmed, Now));
    }

    public void Delete(NoteItem note) => Write(db => db.Run("DELETE FROM notes WHERE id = $1", note.Id));

    public void MakeTask(NoteItem note, string day) => Write(db =>
    {
        db.Run("INSERT INTO tasks(session_id, text, done, created, due) VALUES('', $1, 0, $2, $3)", note.Text, Now, day);
        db.Run("DELETE FROM notes WHERE id = $1", note.Id);
    });

    // Tags

    public IReadOnlyList<Tag> TagsOf(SessionRecord session) => Current.Tags.Where(tag => session.TagIds.Contains(tag.Id)).ToList();

    public void Toggle(Tag tag, SessionRecord session)
    {
        var has = session.TagIds.Contains(tag.Id);
        Write(db =>
        {
            if (has) db.Run("DELETE FROM session_tags WHERE session_id = $1 AND tag_id = $2", session.Id, tag.Id);
            else db.Run("INSERT OR IGNORE INTO session_tags(session_id, tag_id) VALUES($1, $2)", session.Id, tag.Id);
        });
    }

    /// <summary>Renames and recolors a tag, or makes a new one and puts it on a session.</summary>
    public void SaveTag(long? id, string name, int color, string? sessionId)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) return;
        Write(db =>
        {
            if (id is { } existing)
            {
                db.Run("UPDATE tags SET name = $1, color = $2 WHERE id = $3", trimmed, color, existing);
                return;
            }
            db.Run("INSERT OR IGNORE INTO tags(name, color) VALUES($1, $2)", trimmed, color);
            if (sessionId is not null)
                db.Run("INSERT OR IGNORE INTO session_tags(session_id, tag_id) SELECT $1, id FROM tags WHERE name = $2", sessionId, trimmed);
        });
    }

    public void Recolor(Tag tag, int color) => Write(db => db.Run("UPDATE tags SET color = $1 WHERE id = $2", color, tag.Id));

    public void Delete(Tag tag)
    {
        if (TagFilter == tag.Id) TagFilter = null;
        Write(db =>
        {
            db.Run("DELETE FROM session_tags WHERE tag_id = $1", tag.Id);
            db.Run("DELETE FROM tags WHERE id = $1", tag.Id);
        });
    }

    // Names

    public void Rename(SessionRecord session, string name)
    {
        var trimmed = name.Trim();
        if (trimmed == session.Title) return;
        Write(db =>
        {
            if (trimmed.Length == 0 || trimmed == session.OriginalTitle) db.Run("DELETE FROM session_names WHERE session_id = $1", session.Id);
            else db.Run("INSERT OR REPLACE INTO session_names(session_id, name) VALUES($1, $2)", session.Id, trimmed);
        });
    }

    public void Rename(ProjectGroup project, string name)
    {
        var trimmed = name.Trim();
        if (trimmed == project.Name) return;
        Write(db =>
        {
            if (trimmed.Length == 0) db.Run("DELETE FROM project_names WHERE key = $1", project.Key);
            else db.Run("INSERT OR REPLACE INTO project_names(key, name) VALUES($1, $2)", project.Key, trimmed);
        });
    }

    public void Rename(Organization organization, string name)
    {
        var trimmed = name.Trim();
        if (trimmed == organization.Name) return;
        Write(db =>
        {
            if (trimmed.Length == 0) db.Run("DELETE FROM organization_names WHERE id = $1", organization.Id);
            else db.Run("INSERT OR REPLACE INTO organization_names(id, name) VALUES($1, $2)", organization.Id, trimmed);
        });
    }

    // Projects

    public void Merge(ProjectGroup project, ProjectGroup target)
    {
        if (Settings.ExpandedProjects.Contains(project.Key) && !Settings.ExpandedProjects.Contains(target.Key))
        {
            Settings.ExpandedProjects.Add(target.Key);
            Settings.Save();
        }
        Write(db => db.Run("INSERT OR REPLACE INTO project_merges(key, target) VALUES($1, $2)", project.Key, target.Key));
    }

    public void Separate(ProjectGroup project) => Write(db =>
    {
        foreach (var key in project.MergedKeys) db.Run("DELETE FROM project_merges WHERE key = $1", key);
    });

    public void Hide(ProjectGroup project) => ChangeSettings(settings =>
    {
        if (!settings.HiddenProjects.Contains(project.Key)) settings.HiddenProjects.Add(project.Key);
    });

    public void Unhide(string key) => ChangeSettings(settings => settings.HiddenProjects.Remove(key));

    public IReadOnlyList<ProjectGroup> HiddenProjectList =>
        Current.AllProjects.Where(project => Current.Hidden.Contains(project.Key)).OrderBy(project => project.Name, NaturalComparer.Instance).ToList();

    public void SetOpenMethod(OpenMethod? method, ProjectGroup project) => Write(db =>
    {
        foreach (var key in project.MergedKeys.Append(project.Key)) db.Run("DELETE FROM project_open WHERE key = $1", key);
        if (method is { } chosen) db.Run("INSERT INTO project_open(key, method) VALUES($1, $2)", project.Key, chosen.Key());
    });

    // MARK: Time

    public bool IsTiming(string key) => Current.RunningTimer?.ProjectKey == key;

    public TimeReport Report(TimePeriod period) => Current.TimeReports.GetValueOrDefault(period) ?? TimeReport.Empty;

    public double TimeFor(string key, TimePeriod period) => Report(period).Rows.FirstOrDefault(row => row.Key == key)?.Total ?? 0;

    public void StartTimer(string key)
    {
        if (IsTiming(key)) return;
        var now = Now;
        Write(db =>
        {
            CloseTimers(db, now);
            db.Run("INSERT INTO time_entries(project_key, started, ended, open) VALUES($1, $2, $2, 1)", key, now);
        });
    }

    public void StopTimer(DateTimeOffset? at = null)
    {
        if (Current.RunningTimer is not { } timer) return;
        var end = Math.Max(Time.Seconds(at ?? DateTimeOffset.Now), Time.Seconds(timer.Started));
        Write(db => CloseTimers(db, end));
    }

    public void ToggleTimer(string key)
    {
        if (IsTiming(key)) StopTimer(); else StartTimer(key);
    }

    private static void CloseTimers(Database db, double at)
    {
        db.Run("UPDATE time_entries SET ended = $1, open = 0 WHERE open = 1", at);
        // A stretch of a few seconds was a slip.
        db.Run("DELETE FROM time_entries WHERE open = 0 AND ended - started < 10");
    }

    public void DeleteLastTimeEntry(string key)
    {
        if (Current.LastTimeEntries.GetValueOrDefault(key) is not { } entry) return;
        Write(db => db.Run("DELETE FROM time_entries WHERE id = $1 AND open = 0", entry.Id));
    }

    /// <summary>A timer left open: it goes on if the app was gone a moment, else it ends at its last heartbeat.</summary>
    private void RestoreTimer()
    {
        lock (_userLock)
        {
            _userDb.Run("UPDATE time_entries SET open = 0 WHERE open = 1 AND ended < $1", Now - 150);
            _userDb.Run("DELETE FROM time_entries WHERE open = 0 AND ended - started < 10");
        }
    }

    /// <summary>Every 30 seconds while a timer runs, so a crash loses little.</summary>
    public void RecordHeartbeat()
    {
        if (Current.RunningTimer is not { } timer) return;
        try
        {
            lock (_userLock) _userDb.Run("UPDATE time_entries SET ended = $1 WHERE id = $2 AND open = 1", Now, timer.Id);
        }
        catch (Microsoft.Data.Sqlite.SqliteException) { }
        catch (ObjectDisposedException) { }
    }

    // MARK: Summaries

    public sealed record DayEnd(double Worked, int Chats, int Prompts, IReadOnlyList<ProjectTime> Projects);

    public DaySummary? TodaySummary => Current.Week.FirstOrDefault(day => day.Day == Format.Today);

    public DayEnd DaySummaryFigures
    {
        get
        {
            var today = TodaySummary;
            var report = Report(TimePeriod.Today);
            return new DayEnd(report.Total, today?.Work.Count ?? 0, today?.Prompts ?? 0, report.Rows);
        }
    }

    public bool ShowsDayEndCard
    {
        get
        {
            if (!Settings.ShowsDayEnd || Settings.DayEndDismissed == Format.Today || DateTime.Now.Hour < DayEndHour) return false;
            var figures = DaySummaryFigures;
            return figures.Worked >= 60 || figures.Prompts > 0;
        }
    }

    public void DismissDayEndCard() => ChangeSettings(settings => settings.DayEndDismissed = Format.Today, reload: false);

    public string DaySummaryText
    {
        get
        {
            var figures = DaySummaryFigures;
            var lines = new List<string> { L.SummaryHeading(Format.Day(DateTime.Now), Format.Worked(figures.Worked)) };
            lines.AddRange(figures.Projects.Select(row => $"- {row.Name}: {Format.Worked(row.Total)}"));
            if (TodaySummary is { } today)
            {
                lines.Add("");
                lines.Add(L.SummaryChats);
                lines.AddRange(today.Work.Take(10).Select(work => $"- {work.Session.Title} ({work.Session.ProjectName})"));
            }
            return string.Join("\n", lines);
        }
    }

    // MARK: Retention

    public int? DaysLeft(SessionRecord session)
    {
        if (Current.Desktop.Records.ContainsKey(session.Id) || session.LastActivity is not { } last) return null;
        return (int)Math.Ceiling(Retention.Days - (DateTimeOffset.Now - last).TotalDays);
    }

    public (int Days, bool BackedUp)? Expiry(SessionRecord session)
    {
        if (Live.ContainsKey(session.Id) || DaysLeft(session) is not { } days || days < 0 || days > Retention.WarningWindow) return null;
        return (days, Retention.IsBackedUp(session.Id));
    }

    public IReadOnlyList<SessionRecord> UnbackedExpiringSessions =>
        Current.Sessions.Where(session => Expiry(session) is { BackedUp: false })
            .OrderBy(session => DaysLeft(session)).ThenBy(session => session.Id, StringComparer.Ordinal).ToList();

    public void BackUp(IEnumerable<SessionRecord> sessions)
    {
        var done = sessions.Count(Retention.BackUp);
        Backups = Retention.CountBackups();
        Notice?.Invoke(done == 0 ? L.BackupFailed : L.BackedUpChats(done));
        Changed?.Invoke();
    }

    // MARK: Search

    /// <summary>Title and project matches first, then matches inside the conversations, with an excerpt.</summary>
    public IReadOnlyList<SearchHit> Search(string text)
    {
        var sessions = Current.Sessions;
        var compare = System.Globalization.CultureInfo.InvariantCulture.CompareInfo;
        const System.Globalization.CompareOptions options = System.Globalization.CompareOptions.IgnoreCase | System.Globalization.CompareOptions.IgnoreNonSpace;
        bool Contains(string value) => compare.IndexOf(value, text, options) >= 0;

        var hits = sessions.Where(session => Contains(session.Title) || Contains(session.ProjectName))
            .OrderByDescending(session => session.LastActivity ?? DateTimeOffset.MinValue).Take(20)
            .Select(session => new SearchHit(session, null, null)).ToList();
        var query = FtsQuery(text);
        if (query is null) return hits;
        var byId = Current.ById;
        var index = hits.Select((hit, position) => (hit.Session.Id, position)).ToDictionary(item => item.Id, item => item.position);
        try
        {
            lock (_readLock)
            {
                foreach (var row in _readDb.Query(
                    "SELECT session_id, snippet(messages, 0, char(2), char(3), '…', 14), rowid FROM messages WHERE messages MATCH $1 ORDER BY rank LIMIT 400", query))
                {
                    var id = row.GetString(0);
                    if (!byId.TryGetValue(id, out var session)) continue;
                    var snippet = ParseSnippet(row.Text(1) ?? "");
                    if (index.TryGetValue(id, out var position))
                    {
                        if (hits[position].Snippet is null) hits[position] = hits[position] with { Snippet = snippet, MatchRow = row.GetInt64(2) };
                    }
                    else if (hits.Count < 60)
                    {
                        index[id] = hits.Count;
                        hits.Add(new SearchHit(session, snippet, row.GetInt64(2)));
                    }
                }
            }
        }
        catch (Microsoft.Data.Sqlite.SqliteException) { }
        return hits;
    }

    /// <summary>Every word quoted, the last one as a prefix: <c>"foo" "ba"*</c>.</summary>
    public static string? FtsQuery(string text)
    {
        var tokens = Regex.Split(text.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(token => token.Length > 0).ToList();
        if (tokens.Count == 0) return null;
        return string.Join(" ", tokens.Select((token, index) => index == tokens.Count - 1 ? $"\"{token}\"*" : $"\"{token}\""));
    }

    public static Snippet ParseSnippet(string raw)
    {
        var text = new StringBuilder();
        var matches = new List<(int, int)>();
        int? open = null;
        var space = false;
        foreach (var character in raw)
        {
            if (character == '\u0002')
            {
                if (space) { text.Append(' '); space = false; }
                open = text.Length;
                continue;
            }
            if (character == '\u0003')
            {
                if (open is { } start && text.Length > start) matches.Add((start, text.Length));
                open = null;
                continue;
            }
            if (character is '#' or '*' or '`' or '|') continue;
            if (char.IsWhiteSpace(character))
            {
                space = text.Length > 0;
                continue;
            }
            if (space) { text.Append(' '); space = false; }
            text.Append(character);
        }
        return new Snippet(text.ToString(), matches);
    }

    // MARK: Outline

    private static readonly Regex Pasted = new("<pasted_content[^>]*>.*?(</pasted_content[^>]*>|$)", RegexOptions.Singleline | RegexOptions.Compiled);

    public static string OutlineText(string text)
    {
        var cleaned = Pasted.Replace(text, L.PastedContent).Trim();
        return cleaned.Length > 1200 ? cleaned[..1200] : cleaned;
    }

    /// <summary>Everything the user typed in a session, opening on the prompt nearest a matched row.</summary>
    public SessionOutline Outline(SessionRecord session, long? near = null)
    {
        var entries = new List<OutlineEntry>();
        lock (_readLock)
        {
            foreach (var row in _readDb.Query("SELECT rowid, text, ts FROM messages WHERE session_id = $1 AND role = 'u' ORDER BY rowid", session.Id))
            {
                entries.Add(new OutlineEntry(row.GetInt64(0), OutlineText(row.GetString(1)), row.Date(2)));
            }
        }
        long? focus = near is { } target ? entries.LastOrDefault(entry => entry.Id <= target)?.Id ?? entries.FirstOrDefault()?.Id : null;
        return new SessionOutline(session, entries, focus);
    }

    // MARK: Activity

    public const int ActivityBuckets = 30;

    public ActivitySeries Activity(SessionRecord session)
    {
        var stamps = new List<double>();
        lock (_readLock)
        {
            foreach (var row in _readDb.Query("SELECT ts FROM messages WHERE session_id = $1 AND ts > 0", session.Id))
                if (row.Double(0) is { } stamp) stamps.Add(stamp);
        }
        stamps.Sort();
        var buckets = new int[ActivityBuckets];
        if (stamps.Count == 0) return new ActivitySeries("session:" + session.Id, buckets, "", "", 0);
        var first = stamps[0];
        var span = Math.Max(stamps[^1] - first, 1);
        foreach (var stamp in stamps) buckets[Math.Min((int)((stamp - first) / span * ActivityBuckets), ActivityBuckets - 1)]++;
        return new ActivitySeries("session:" + session.Id, buckets,
            Format.ShortDate(Time.FromSeconds(first)), Format.ShortDate(Time.FromSeconds(stamps[^1])),
            TimeMath.Length(TimeMath.Blocks(stamps, Settings.IdleGap * 60.0)));
    }

    public ActivitySeries Activity(ProjectGroup project)
    {
        var ids = project.Sessions.Select(session => session.Id).ToHashSet();
        var end = Time.Seconds(new DateTimeOffset(DateTime.Today.AddDays(1)));
        var start = end - 30 * 86_400;
        var stamps = new List<double>();
        var buckets = new int[ActivityBuckets];
        lock (_readLock)
        {
            foreach (var row in _readDb.Query("SELECT session_id, ts, role FROM messages WHERE ts > 0"))
            {
                if (!ids.Contains(row.GetString(0)) || row.Double(1) is not { } stamp) continue;
                stamps.Add(stamp);
                if (row.Text(2) == "u" && stamp >= start && stamp < end) buckets[Math.Min((int)((stamp - start) / 86_400), ActivityBuckets - 1)]++;
            }
        }
        stamps.Sort();
        var keys = project.MergedKeys.Append(project.Key).ToHashSet();
        var timer = Current.TimerSpans.Where(pair => keys.Contains(pair.Key)).SelectMany(pair => pair.Value);
        var worked = TimeMath.Length(TimeMath.Merged(TimeMath.Blocks(stamps, Settings.IdleGap * 60.0).Concat(timer)));
        return new ActivitySeries("project:" + project.Key, buckets, L.DaysAgo(30), L.Today.ToLower(L.Culture), worked);
    }

    // MARK: Live sessions

    /// <summary>Reads what is running now and announces what changed. Call every few seconds.</summary>
    public void RefreshLive() => Task.Run(() =>
    {
        var live = LiveSessions.Load();
        _post(() => IngestLive(live));
    });

    private void IngestLive(IReadOnlyDictionary<string, LiveSession> current)
    {
        var now = DateTimeOffset.Now;
        RememberHosts(current, now);
        FollowWork(current, now);
        var before = Live;
        var changed = before.Count != current.Count || current.Any(pair => !before.TryGetValue(pair.Key, out var old) || old != pair.Value);
        if (!_hasLiveBaseline)
        {
            _hasLiveBaseline = true;
            foreach (var session in current.Values.Where(session => session.State == LiveState.Working)) _workingSince[session.SessionId] = now;
        }
        else
        {
            foreach (var session in current.Values)
            {
                var previous = before.GetValueOrDefault(session.SessionId)?.State;
                switch (session.State)
                {
                    case LiveState.Working:
                        _workingSince.TryAdd(session.SessionId, now);
                        changed |= AttentionSet.Remove(session.SessionId);
                        break;
                    case LiveState.Waiting:
                        _workingSince.Remove(session.SessionId);
                        if (previous != LiveState.Waiting) Announce(session);
                        break;
                    default:
                        if (previous == LiveState.Working && _workingSince.TryGetValue(session.SessionId, out var since) && (now - since).TotalSeconds >= FinishThreshold)
                            Announce(session);
                        _workingSince.Remove(session.SessionId);
                        break;
                }
            }
            foreach (var gone in before.Keys.Where(id => !current.ContainsKey(id)).ToList())
            {
                changed |= AttentionSet.Remove(gone);
                _workingSince.Remove(gone);
            }
        }
        Live = current;
        if (changed) LiveChanged?.Invoke();
    }

    private void Announce(LiveSession session)
    {
        AttentionSet.Add(session.SessionId);
        if (Settings.NotificationsEnabled) Attention?.Invoke(new Announcement(session.SessionId, Session(session.SessionId), session));
    }

    /// <summary>Sessions waiting for an answer, or finished since last looked; newest first.</summary>
    public IReadOnlyList<SessionRecord> NeedsYou
    {
        get
        {
            var ids = Live.Values.Where(session => session.State == LiveState.Waiting).Select(session => session.SessionId).Union(AttentionSet);
            return ids.Select(Session).OfType<SessionRecord>()
                .Where(session => !Current.Hidden.Contains(session.ProjectKey))
                .OrderByDescending(session => session.LastActivity ?? DateTimeOffset.MinValue).ThenByDescending(session => session.Id, StringComparer.Ordinal)
                .ToList();
        }
    }

    /// <summary>Opening the panel counts as having seen the finished ones.</summary>
    public void PanelDidOpen()
    {
        AttentionSet.RemoveWhere(id => Live.GetValueOrDefault(id)?.State != LiveState.Waiting);
        Refresh();
    }

    public void Seen(string id) => AttentionSet.Remove(id);

    private readonly Dictionary<string, OpenMethod> _hostsSeen = new();

    private void RememberHosts(IReadOnlyDictionary<string, LiveSession> current, DateTimeOffset now)
    {
        foreach (var session in current.Values)
        {
            if (session.Host is not { } host) continue;
            if (Current.SessionHosts.GetValueOrDefault(session.SessionId) == host && Current.SessionHosts.ContainsKey(session.SessionId)) continue;
            if (_hostsSeen.TryGetValue(session.SessionId, out var seen) && seen == host) continue;
            _hostsSeen[session.SessionId] = host;
            var id = session.SessionId;
            Task.Run(() =>
            {
                try
                {
                    lock (_userLock) _userDb.Run("INSERT OR REPLACE INTO session_hosts(session_id, method, seen) VALUES($1, $2, $3)", id, host.Key(), Time.Seconds(now));
                }
                catch (Microsoft.Data.Sqlite.SqliteException) { }
            });
        }
    }

    /// <summary>The timer that starts and stops by itself, following the sessions at work.</summary>
    private void FollowWork(IReadOnlyDictionary<string, LiveSession> current, DateTimeOffset now)
    {
        string? ProjectOf(string id) => Session(id) is { } session && !Current.Hidden.Contains(session.ProjectKey) ? session.ProjectKey : null;
        var workingIds = current.Values.Where(session => session.State == LiveState.Working).Select(session => session.SessionId).OrderBy(id => id, StringComparer.Ordinal).ToList();
        var working = workingIds.Select(ProjectOf).OfType<string>().ToHashSet();
        var started = workingIds.Where(id => !_previouslyWorking.Contains(id)).Select(ProjectOf).OfType<string>().Distinct().ToList();
        _previouslyWorking = workingIds.ToHashSet();
        if (!Settings.StartsTimerAutomatically) return;

        if (Current.RunningTimer is not { } timer)
        {
            if (started.Count == 0) return;
            _followedProject = started[0];
            _lastWork = now;
            StartTimer(started[0]);
            return;
        }
        if (working.Contains(timer.ProjectKey)) _lastWork = now;
        if (_followedProject != timer.ProjectKey) return;
        if (!working.Contains(timer.ProjectKey) && started.FirstOrDefault(key => key != timer.ProjectKey) is { } other)
        {
            _followedProject = other;
            _lastWork = now;
            StartTimer(other);
        }
        else if ((now - _lastWork).TotalSeconds > Settings.IdleGap * 60.0)
        {
            _followedProject = null;
            StopTimer(_lastWork);
        }
    }

    // MARK: Opening

    public OpenMethod OpenMethodFor(ProjectGroup project) =>
        Current.ProjectOpenMethods.GetValueOrDefault(project.Key) is var chosen && Current.ProjectOpenMethods.ContainsKey(project.Key) && Opener.IsInstalled(chosen)
            ? chosen : GeneralOpenMethod;

    public OpenMethod GeneralOpenMethod => OpenMethods.Parse(Settings.OpenMethod) is { } method && Opener.IsInstalled(method) ? method : OpenMethod.Automatic;

    private OpenMethod ProjectChoice(string key) =>
        Current.ProjectOpenMethods.TryGetValue(key, out var chosen) && Opener.IsInstalled(chosen) ? chosen : GeneralOpenMethod;

    /// <summary>Where a session opens: its project's choice, else where it was seen running, and so on.</summary>
    public OpenMethod OpenMethodFor(SessionRecord session)
    {
        var chosen = ProjectChoice(session.ProjectKey);
        if (chosen != OpenMethod.Automatic) return chosen;
        if (Current.SessionHosts.TryGetValue(session.Id, out var host) && Opener.IsInstalled(host)) return host;
        if (Current.Desktop.Records.ContainsKey(session.Id)) return OpenMethod.Automatic;
        if (session.Entrypoint == "claude-vscode" && Opener.IsInstalled(OpenMethod.VsCode)) return OpenMethod.VsCode;
        if (Current.ProjectHosts.TryGetValue(session.ProjectKey, out var projectHost) && projectHost != OpenMethod.Desktop && Opener.IsInstalled(projectHost)) return projectHost;
        return OpenMethod.Automatic;
    }

    public OpenMethod StartMethod(string projectKey)
    {
        var chosen = ProjectChoice(projectKey);
        if (chosen != OpenMethod.Automatic) return chosen;
        if (Current.ProjectHosts.TryGetValue(projectKey, out var host) && host != OpenMethod.Desktop && Opener.IsInstalled(host)) return host;
        return OpenMethod.Automatic;
    }

    public string? DesktopId(string id) => Live.GetValueOrDefault(id)?.DesktopId ?? Current.Desktop.Records.GetValueOrDefault(id)?.DesktopId;

    public bool IsInOtherOrganization(string id) =>
        !Live.ContainsKey(id) && Current.CurrentOrganization is { } current
        && Current.Desktop.Records.TryGetValue(id, out var record) && record.Organization != current;

    /// <summary>The app a session's row shows: where it runs, or where it would open.</summary>
    public OpenMethod Destination(SessionRecord session)
    {
        if (Live.TryGetValue(session.Id, out var live)) return live.DesktopId is not null ? OpenMethod.Desktop : live.Host ?? OpenMethod.Terminal;
        var method = OpenMethodFor(session);
        if (method is OpenMethod.Automatic or OpenMethod.Desktop && IsInOtherOrganization(session.Id) && Settings.OpensOtherAccountsInTerminal) return OpenMethod.Terminal;
        if (method == OpenMethod.Automatic) return Current.Desktop.Records.ContainsKey(session.Id) ? OpenMethod.Desktop : OpenMethod.Terminal;
        return method;
    }
}
