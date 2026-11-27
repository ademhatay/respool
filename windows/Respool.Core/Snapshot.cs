namespace Respool.Core;

/// <summary>Everything the panel shows, read from the index in one go.</summary>
public sealed class Snapshot
{
    public IReadOnlyList<SessionRecord> Sessions { get; init; } = Array.Empty<SessionRecord>();
    public IReadOnlyDictionary<string, SessionRecord> ById { get; init; } = new Dictionary<string, SessionRecord>();
    public IReadOnlyList<PinnedSession> Pinned { get; init; } = Array.Empty<PinnedSession>();
    public IReadOnlyList<SessionRecord> Recent { get; init; } = Array.Empty<SessionRecord>();
    /// <summary>The projects as listed: hidden ones left out, filtered and sorted.</summary>
    public IReadOnlyList<ProjectGroup> Projects { get; init; } = Array.Empty<ProjectGroup>();
    /// <summary>Every project, by last activity.</summary>
    public IReadOnlyList<ProjectGroup> AllProjects { get; init; } = Array.Empty<ProjectGroup>();
    public IReadOnlyList<Tag> Tags { get; init; } = Array.Empty<Tag>();
    public IReadOnlyList<TaskItem> Tasks { get; init; } = Array.Empty<TaskItem>();
    public IReadOnlyList<NoteItem> Notes { get; init; } = Array.Empty<NoteItem>();
    public IReadOnlyList<DaySummary> Week { get; init; } = Array.Empty<DaySummary>();
    public IReadOnlyList<Organization> Organizations { get; init; } = Array.Empty<Organization>();
    public IReadOnlyList<SessionRecord>? Tagged { get; init; }
    public IReadOnlySet<string> Hidden { get; init; } = new HashSet<string>();
    public IReadOnlyDictionary<TimePeriod, TimeReport> TimeReports { get; init; } = new Dictionary<TimePeriod, TimeReport>();
    public RunningTimer? RunningTimer { get; init; }
    public IReadOnlyDictionary<string, TimeEntry> LastTimeEntries { get; init; } = new Dictionary<string, TimeEntry>();
    /// <summary>All the timer's stretches by project, for the project card.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<Span>> TimerSpans { get; init; } = new Dictionary<string, IReadOnlyList<Span>>();
    public IReadOnlyDictionary<string, OpenMethod> SessionHosts { get; init; } = new Dictionary<string, OpenMethod>();
    public IReadOnlyDictionary<string, OpenMethod> ProjectHosts { get; init; } = new Dictionary<string, OpenMethod>();
    public IReadOnlyDictionary<string, OpenMethod> ProjectOpenMethods { get; init; } = new Dictionary<string, OpenMethod>();
    public DesktopSnapshot Desktop { get; init; } = DesktopSnapshot.Empty;
    public IReadOnlyDictionary<string, LiveSession> Live { get; init; } = new Dictionary<string, LiveSession>();
    public string? CurrentOrganization { get; init; }

    public static readonly Snapshot Empty = new();

    public ProjectGroup? Project(string key) => AllProjects.FirstOrDefault(project => project.Key == key);
}

/// <summary>What a snapshot is built for: the filters and choices that change what it holds.</summary>
public sealed record Arrangement(
    string? OrganizationFilter,
    long? TagFilter,
    bool ShowsOrganizations,
    ProjectSort Sort,
    bool HideSingle,
    bool HideInactive,
    IReadOnlySet<string> Hidden,
    bool AutomaticTime,
    double IdleGap);

public static class SnapshotBuilder
{
    public const int RecentCount = 6;
    public static int TimeColors = 8;

    public static Snapshot Build(Database db, Arrangement arrangement, IReadOnlyDictionary<string, LiveSession> live, DesktopSnapshot desktop)
    {
        var now = DateTimeOffset.Now;
        var nowSeconds = Time.Seconds(now);

        // Projects: each folder's identity, joined by name to a repository and through merges.
        var identities = new Dictionary<string, (string Key, string Name)>();
        foreach (var row in db.Query("SELECT cwd, key, name FROM cwd_projects")) identities[row.GetString(0)] = (row.GetString(1), row.GetString(2));
        var merges = new Dictionary<string, string>();
        foreach (var row in db.Query("SELECT key, target FROM project_merges")) merges[row.GetString(0)] = row.GetString(1);
        var customNames = new Dictionary<string, string>();
        foreach (var row in db.Query("SELECT key, name FROM project_names")) customNames[row.GetString(0)] = row.GetString(1);

        var defaultNames = new Dictionary<string, string>();
        var gitKeyByName = new Dictionary<string, string?>();
        foreach (var (key, name) in identities.Values)
        {
            defaultNames.TryAdd(key, name);
            if (!key.StartsWith("git:", StringComparison.Ordinal)) continue;
            var normal = ProjectResolver.Normalize(name);
            if (gitKeyByName.TryGetValue(normal, out var other) && other != key) gitKeyByName[normal] = null;
            else gitKeyByName[normal] = key;
        }

        string FinalKey(string key)
        {
            if (key.StartsWith("name:", StringComparison.Ordinal) && gitKeyByName.TryGetValue(key[5..], out var git) && git is not null) key = git;
            for (var hop = 0; hop < 8 && merges.TryGetValue(key, out var target); hop++) key = target;
            return key;
        }

        // Sessions.
        var records = new List<SessionRecord>();
        foreach (var row in db.Query("""
            SELECT id, path, cwd, custom_title, ai_title, first_prompt, last_prompt, last_ts, pr_number, pr_url, msg_count,
                   first_ts, branch, file_size, tok_input, tok_cached, tok_output, context_tokens, model, entrypoint
            FROM sessions WHERE msg_count > 0 OR (custom_title IS NOT NULL AND custom_title != '') ORDER BY last_ts DESC
            """))
        {
            var cwd = row.Text(2) ?? "";
            var identity = identities.TryGetValue(cwd, out var known)
                ? known
                : ProjectResolver.Fallback(cwd.Length == 0 ? L.OtherProject : cwd, false) is var fallback ? (fallback.Key, fallback.Name) : default;
            defaultNames.TryAdd(identity.Key, identity.Name);
            var projectKey = FinalKey(identity.Key);
            var last = row.Double(7);
            var first = row.Double(11);
            records.Add(new SessionRecord
            {
                Id = row.GetString(0),
                Path = row.GetString(1),
                Cwd = cwd,
                CustomTitle = row.Text(3),
                AiTitle = row.Text(4),
                FirstPrompt = row.Text(5),
                LastPrompt = row.Text(6),
                LastActivity = last > 0 ? Time.FromSeconds(last.Value) : null,
                PrNumber = (int?)row.OptionalLong(8),
                PrUrl = row.Text(9),
                MessageCount = (int)row.Long(10),
                FirstActivity = first > 0 ? Time.FromSeconds(first.Value) : null,
                Branch = row.Text(12),
                FileSize = row.Long(13),
                InputTokens = row.Long(14),
                CachedTokens = row.Long(15),
                OutputTokens = row.Long(16),
                ContextTokens = row.OptionalLong(17),
                Model = row.Text(18),
                Entrypoint = row.Text(19),
                ProjectKey = projectKey,
            });
        }
        string ProjectName(string key) => customNames.TryGetValue(key, out var custom) ? custom : defaultNames.TryGetValue(key, out var plain) ? plain : key;

        // Organizations, as the desktop app files the sessions.
        var organizationNames = new Dictionary<string, string>();
        foreach (var row in db.Query("SELECT id, name FROM organization_names")) organizationNames[row.GetString(0)] = row.GetString(1);
        var signedIn = ClaudeAccount.Organization();
        var current = desktop.CurrentOrganization;
        var counts = new Dictionary<string, int>();
        foreach (var record in records)
        {
            if (desktop.Records.TryGetValue(record.Id, out var filed)) counts[filed.Organization] = counts.GetValueOrDefault(filed.Organization) + 1;
        }
        var organizations = counts.Keys
            .OrderByDescending(id => id == current).ThenByDescending(id => counts[id]).ThenBy(id => id, StringComparer.Ordinal)
            .Select((id, index) => new Organization(id,
                organizationNames.TryGetValue(id, out var custom) ? custom
                    : signedIn is { } account && account.Id == id ? account.Name
                    : L.AccountNumber(index + 1),
                id == current, counts[id]))
            .ToList();
        var organizationById = organizations.ToDictionary(organization => organization.Id);

        // Tags and the names given in Respool.
        var tags = db.Query("SELECT id, name, color FROM tags ORDER BY name COLLATE NOCASE")
            .Select(row => new Tag(row.GetInt64(0), row.GetString(1), (int)row.Long(2))).ToList();
        var tagsBySession = new Dictionary<string, List<long>>();
        foreach (var row in db.Query("SELECT session_id, tag_id FROM session_tags ORDER BY tag_id"))
        {
            var id = row.GetString(0);
            if (!tagsBySession.TryGetValue(id, out var list)) tagsBySession[id] = list = new List<long>();
            list.Add(row.GetInt64(1));
        }
        var localNames = new Dictionary<string, string>();
        foreach (var row in db.Query("SELECT session_id, name FROM session_names")) localNames[row.GetString(0)] = row.GetString(1);

        var sessions = new List<SessionRecord>(records.Count);
        foreach (var record in records)
        {
            string? organizationId = desktop.Records.TryGetValue(record.Id, out var filed) ? filed.Organization : null;
            if (arrangement.ShowsOrganizations && arrangement.OrganizationFilter is { } filter && counts.ContainsKey(filter)
                && organizationId is not null && organizationId != filter) continue;
            sessions.Add(record with
            {
                ProjectName = ProjectName(record.ProjectKey),
                OrganizationId = organizationId,
                OrganizationName = arrangement.ShowsOrganizations && organizationId is not null && organizationById.TryGetValue(organizationId, out var organization) ? organization.Name : null,
                InOtherOrganization = current is not null && organizationId is not null && organizationId != current && !live.ContainsKey(record.Id),
                TagIds = tagsBySession.TryGetValue(record.Id, out var tagIds) ? tagIds : Array.Empty<long>(),
                LocalName = localNames.GetValueOrDefault(record.Id),
            });
        }
        var byId = sessions.ToDictionary(session => session.Id);

        IReadOnlyList<SessionRecord>? tagged = arrangement.TagFilter is { } tagFilter && tags.Any(tag => tag.Id == tagFilter)
            ? sessions.Where(session => session.TagIds.Contains(tagFilter)).ToList()
            : null;

        // Projects.
        var mergedInto = new Dictionary<string, List<string>>();
        foreach (var key in merges.Keys)
        {
            var target = FinalKey(key);
            if (!mergedInto.TryGetValue(target, out var list)) mergedInto[target] = list = new List<string>();
            list.Add(key);
        }
        var allProjects = sessions.GroupBy(session => session.ProjectKey)
            .Select(group => new ProjectGroup(group.Key, group.First().ProjectName, group.ToList(),
                group.Select(session => session.Cwd).Where(cwd => cwd.Length > 0).Distinct().OrderBy(cwd => cwd, StringComparer.Ordinal).ToList(),
                mergedInto.TryGetValue(group.Key, out var merged) ? merged.OrderBy(key => key, StringComparer.Ordinal).ToList() : new List<string>()))
            .Sorted(ProjectSort.Activity).ToList();
        var allKeys = allProjects.Select(project => project.Key).ToHashSet();
        var hidden = arrangement.Hidden.Where(allKeys.Contains).ToHashSet();

        // Tasks: open ones, and finished ones for a day.
        var tasks = db.Query("""
            SELECT id, session_id, text, done, done_at, due, project_key, position, created FROM tasks
            WHERE done = 0 OR done_at > $1 ORDER BY done, COALESCE(position, created), id
            """, nowSeconds - 86_400)
            .Select(row => new TaskItem
            {
                Id = row.GetInt64(0),
                SessionId = row.Text(1) ?? "",
                Text = row.GetString(2),
                Done = row.Flag(3),
                DoneAt = row.Date(4),
                Due = row.Text(5),
                ProjectKey = row.Text(6),
                Position = row.Double(7),
                Created = row.Double(8) ?? 0,
            }).ToList();
        var tasksBySession = tasks.Where(task => task.SessionId.Length > 0).GroupBy(task => task.SessionId)
            .ToDictionary(group => group.Key, group => (IReadOnlyList<TaskItem>)group.ToList());

        var pinned = db.Query("SELECT session_id FROM pins ORDER BY position").Select(row => row.GetString(0))
            .Where(byId.ContainsKey)
            .Select(id => new PinnedSession(byId[id], tasksBySession.GetValueOrDefault(id) ?? Array.Empty<TaskItem>()))
            .ToList();
        var pinnedIds = pinned.Select(pin => pin.Id).ToHashSet();
        var recent = sessions.Where(session => !pinnedIds.Contains(session.Id) && !hidden.Contains(session.ProjectKey)).Take(RecentCount).ToList();

        var monthAgo = now.AddDays(-30);
        var projects = allProjects.Where(project => !hidden.Contains(project.Key))
            .Where(project => !arrangement.HideSingle || project.Sessions.Count >= 2)
            .Where(project => !arrangement.HideInactive || (project.LastActivity is { } last && last >= monthAgo))
            .Sorted(arrangement.Sort).ToList();

        var notes = db.Query("SELECT id, text, created FROM notes ORDER BY id DESC")
            .Select(row => new NoteItem(row.GetInt64(0), row.GetString(1), row.Date(2))).ToList();

        var openMethods = new Dictionary<string, OpenMethod>();
        foreach (var row in db.Query("SELECT key, method FROM project_open"))
        {
            if (OpenMethods.Parse(row.Text(1)) is { } method) openMethods[FinalKey(row.GetString(0))] = method;
        }
        var sessionHosts = new Dictionary<string, OpenMethod>();
        var projectHosts = new Dictionary<string, OpenMethod>();
        foreach (var row in db.Query("SELECT session_id, method FROM session_hosts ORDER BY seen"))
        {
            if (OpenMethods.Parse(row.Text(1)) is not { } method) continue;
            var id = row.GetString(0);
            sessionHosts[id] = method;
            if (byId.TryGetValue(id, out var session)) projectHosts[session.ProjectKey] = method;
        }

        string NameOf(string key) => allProjects.FirstOrDefault(project => project.Key == key)?.Name ?? ProjectName(key);
        var time = AddTime(db, arrangement, byId, hidden, FinalKey, NameOf, now);

        return new Snapshot
        {
            Sessions = sessions,
            ById = byId,
            Pinned = pinned,
            Recent = recent,
            Projects = projects,
            AllProjects = allProjects,
            Tags = tags,
            Tasks = tasks,
            Notes = notes,
            Week = Week(db, byId, hidden, now),
            Organizations = organizations,
            Tagged = tagged,
            Hidden = hidden,
            TimeReports = time.Reports,
            RunningTimer = time.Running,
            LastTimeEntries = time.LastEntries,
            TimerSpans = time.TimerSpans,
            SessionHosts = sessionHosts,
            ProjectHosts = projectHosts,
            ProjectOpenMethods = openMethods,
            Desktop = desktop,
            Live = live,
            CurrentOrganization = current,
        };
    }

    // MARK: Week

    public static DateTime StartOfWeek(DateTime day)
    {
        var offset = ((int)day.DayOfWeek + 6) % 7;
        return day.Date.AddDays(-offset);
    }

    private static IReadOnlyList<DaySummary> Week(Database db, IReadOnlyDictionary<string, SessionRecord> byId, IReadOnlySet<string> hidden, DateTimeOffset now)
    {
        var monday = StartOfWeek(now.LocalDateTime);
        var perDay = new Dictionary<string, Dictionary<string, int>>();
        foreach (var row in db.Query("SELECT session_id, ts FROM messages WHERE role = 'u' AND ts >= $1", Time.Seconds(new DateTimeOffset(monday))))
        {
            if (row.Double(1) is not { } stamp) continue;
            var day = Format.DayKey(Time.FromSeconds(stamp));
            if (!perDay.TryGetValue(day, out var counts)) perDay[day] = counts = new Dictionary<string, int>();
            var id = row.GetString(0);
            counts[id] = counts.GetValueOrDefault(id) + 1;
        }
        var today = Format.DayKey(now.LocalDateTime);
        var result = new List<DaySummary>();
        for (var offset = 0; offset < 7; offset++)
        {
            var day = Format.DayKey(monday.AddDays(offset));
            if (string.CompareOrdinal(day, today) > 0) break;
            if (!perDay.TryGetValue(day, out var counts)) continue;
            var work = counts.Where(pair => byId.TryGetValue(pair.Key, out var session) && !hidden.Contains(session.ProjectKey))
                .Select(pair => new DayWork(byId[pair.Key], pair.Value))
                .OrderByDescending(work => work.Prompts).ThenBy(work => work.Session.Id, StringComparer.Ordinal).ToList();
            if (work.Count > 0) result.Add(new DaySummary(day, work));
        }
        result.Reverse();
        return result;
    }

    // MARK: Time

    private sealed record TimeResult(
        IReadOnlyDictionary<TimePeriod, TimeReport> Reports,
        RunningTimer? Running,
        IReadOnlyDictionary<string, TimeEntry> LastEntries,
        IReadOnlyDictionary<string, IReadOnlyList<Span>> TimerSpans);

    public static double PeriodStart(TimePeriod period, DateTime now) => Time.Seconds(new DateTimeOffset(period switch
    {
        TimePeriod.Week => StartOfWeek(now),
        TimePeriod.Month => new DateTime(now.Year, now.Month, 1),
        _ => now.Date,
    }));

    private static TimeResult AddTime(Database db, Arrangement arrangement, IReadOnlyDictionary<string, SessionRecord> byId,
        IReadOnlySet<string> hidden, Func<string, string> finalKey, Func<string, string> nameOf, DateTimeOffset now)
    {
        var nowSeconds = Time.Seconds(now);
        var local = now.LocalDateTime;
        var starts = Enum.GetValues<TimePeriod>().ToDictionary(period => period, period => PeriodStart(period, local));
        var earliest = starts.Values.Min();

        var manual = new Dictionary<string, List<Span>>();
        RunningTimer? running = null;
        var lastEntries = new Dictionary<string, TimeEntry>();
        foreach (var row in db.Query("SELECT id, project_key, started, ended, open FROM time_entries ORDER BY id"))
        {
            var key = finalKey(row.GetString(1));
            var started = row.GetDouble(2);
            var ended = row.GetDouble(3);
            Span span;
            if (row.Flag(4))
            {
                running = new RunningTimer(row.GetInt64(0), key, nameOf(key), Time.FromSeconds(started));
                span = new Span(started, nowSeconds);
            }
            else
            {
                lastEntries[key] = new TimeEntry(row.GetInt64(0), ended - started);
                span = new Span(started, ended);
            }
            if (!manual.TryGetValue(key, out var list)) manual[key] = list = new List<Span>();
            list.Add(span);
        }

        var automatic = new Dictionary<string, List<Span>>();
        if (arrangement.AutomaticTime)
        {
            var stamps = new Dictionary<string, List<double>>();
            foreach (var row in db.Query("SELECT session_id, ts FROM messages WHERE ts >= $1", earliest))
            {
                if (row.Double(1) is not { } stamp || stamp > nowSeconds) continue;
                if (!byId.TryGetValue(row.GetString(0), out var session)) continue;
                if (!stamps.TryGetValue(session.ProjectKey, out var list)) stamps[session.ProjectKey] = list = new List<double>();
                list.Add(stamp);
            }
            foreach (var (key, list) in stamps)
            {
                list.Sort();
                automatic[key] = TimeMath.Blocks(list, arrangement.IdleGap);
            }
        }

        var keys = manual.Keys.Union(automatic.Keys).Where(key => !hidden.Contains(key)).ToList();
        var mergedManual = keys.ToDictionary(key => key, key => TimeMath.Merged(manual.GetValueOrDefault(key) ?? new List<Span>()));
        var both = keys.ToDictionary(key => key, key => TimeMath.Merged(mergedManual[key].Concat(automatic.GetValueOrDefault(key) ?? new List<Span>())));
        var colors = keys.Select(key => (Key: key, Length: TimeMath.Length(TimeMath.Clipped(both[key], earliest, nowSeconds))))
            .OrderByDescending(item => item.Length).ThenBy(item => item.Key, StringComparer.Ordinal)
            .Select((item, index) => (item.Key, Index: index)).ToDictionary(item => item.Key, item => item.Index < TimeColors ? item.Index : (int?)null);

        var reports = new Dictionary<TimePeriod, TimeReport>();
        foreach (var period in Enum.GetValues<TimePeriod>())
        {
            var from = starts[period];
            var rows = new List<(ProjectTime Row, List<Span> Both)>();
            foreach (var key in keys)
            {
                var timed = TimeMath.Clipped(mergedManual[key], from, nowSeconds);
                var guessed = TimeMath.Clipped(automatic.GetValueOrDefault(key) ?? new List<Span>(), from, nowSeconds);
                var union = TimeMath.Merged(timed.Concat(guessed));
                var total = TimeMath.Length(union);
                if (total < 60 && running?.ProjectKey != key) continue;
                var row = new ProjectTime(key, nameOf(key), TimeMath.Length(timed), TimeMath.Length(guessed), total, colors.GetValueOrDefault(key));
                if (period == TimePeriod.Today) row = row with { Timed = timed, Guessed = guessed };
                rows.Add((row, union));
            }
            rows.Sort((a, b) => a.Row.Total != b.Row.Total ? b.Row.Total.CompareTo(a.Row.Total) : string.CompareOrdinal(a.Row.Key, b.Row.Key));
            var days = new List<DayTime>();
            if (period != TimePeriod.Today)
            {
                var first = Time.FromSeconds(from).LocalDateTime.Date;
                var last = period == TimePeriod.Week ? first.AddDays(7) : first.AddMonths(1);
                for (var day = first; day < last; day = day.AddDays(1))
                {
                    var dayStart = Time.Seconds(new DateTimeOffset(day));
                    var dayEnd = Time.Seconds(new DateTimeOffset(day.AddDays(1)));
                    var parts = new Dictionary<string, double>();
                    if (dayStart <= nowSeconds)
                    {
                        foreach (var (row, union) in rows)
                        {
                            var length = TimeMath.Length(TimeMath.Clipped(union, dayStart, dayEnd));
                            if (length > 0) parts[row.Key] = length;
                        }
                    }
                    days.Add(new DayTime(Format.DayKey(day), day, parts));
                }
            }
            reports[period] = new TimeReport(rows.Select(item => item.Row).ToList(),
                TimeMath.Length(TimeMath.Merged(rows.SelectMany(item => item.Both))), from, nowSeconds, days);
        }
        var timerSpans = mergedManual.ToDictionary(pair => pair.Key, pair => (IReadOnlyList<Span>)pair.Value);
        return new TimeResult(reports, running, lastEntries, timerSpans);
    }
}
