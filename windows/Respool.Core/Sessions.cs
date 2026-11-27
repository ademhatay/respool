using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;

namespace Respool.Core;

/// <summary>One Claude Code session, as its transcript describes it.</summary>
public sealed record SessionInfo
{
    public required string Id { get; init; }
    public required string Path { get; init; }
    public string Cwd { get; init; } = "";
    public string? CustomTitle { get; init; }
    public string? AiTitle { get; init; }
    public string? FirstPrompt { get; init; }
    public string? LastPrompt { get; init; }
    public DateTimeOffset? FirstActivity { get; init; }
    public DateTimeOffset? LastActivity { get; init; }
    public int PromptCount { get; init; }
    public long Size { get; init; }

    /// <summary>The project, named after the folder the session was started in.</summary>
    public string ProjectName =>
        string.IsNullOrEmpty(Cwd) ? "Other" : System.IO.Path.GetFileName(Cwd.TrimEnd('/', '\\')) is { Length: > 0 } name ? name : Cwd;

    public string Title
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(CustomTitle)) return CustomTitle!;
            if (!string.IsNullOrWhiteSpace(AiTitle)) return AiTitle!;
            var prompt = (FirstPrompt ?? LastPrompt ?? "").Trim();
            var line = prompt.Split('\n', 2)[0].Trim();
            return line.Length == 0 ? "Untitled chat" : line.Length > 80 ? line[..80] : line;
        }
    }
}

/// <summary>
/// Finds and reads the transcripts under Claude Code's projects folder, read-only. What was
/// read is kept, so a later scan only reads the transcripts that changed.
/// </summary>
public sealed class SessionStore
{
    private const int MaxLineBytes = 512 * 1024;
    private readonly ConcurrentDictionary<string, (long Size, DateTime Modified, SessionInfo Info)> _cache = new();

    public string Folder { get; }

    public SessionStore(string? folder = null)
    {
        Folder = folder ?? DefaultFolder;
    }

    /// <summary><c>%USERPROFILE%\.claude\projects</c>, or <c>CLAUDE_CONFIG_DIR\projects</c> when that is set.</summary>
    public static string DefaultFolder
    {
        get
        {
            var config = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            var root = string.IsNullOrEmpty(config)
                ? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude")
                : config;
            return System.IO.Path.Combine(root, "projects");
        }
    }

    /// <summary>
    /// Every session with something in it, the most recent first. Null when the folder cannot
    /// be read (an unplugged drive, say), so the caller can keep what it showed before.
    /// </summary>
    public IReadOnlyList<SessionInfo>? Scan()
    {
        if (!Directory.Exists(Folder)) return null;
        string[] files;
        try
        {
            files = Directory.GetDirectories(Folder)
                .SelectMany(folder => Directory.EnumerateFiles(folder, "*.jsonl"))
                .Where(file => System.IO.Path.GetFileNameWithoutExtension(file).Length == 36)
                .ToArray();
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }

        var found = new ConcurrentBag<SessionInfo>();
        // Transcripts are read side by side; each is independent of the others.
        Parallel.ForEach(files, file =>
        {
            try
            {
                var details = new FileInfo(file);
                if (_cache.TryGetValue(file, out var cached) && cached.Size == details.Length && cached.Modified == details.LastWriteTimeUtc)
                {
                    found.Add(cached.Info);
                    return;
                }
                var info = Read(file, details.Length);
                _cache[file] = (details.Length, details.LastWriteTimeUtc, info);
                found.Add(info);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        });

        // The same session can sit in two folders after a move; the larger copy is kept.
        return found
            .Where(info => info.PromptCount > 0 || !string.IsNullOrEmpty(info.CustomTitle))
            .GroupBy(info => info.Id)
            .Select(group => group.MaxBy(info => info.Size)!)
            .OrderByDescending(info => info.LastActivity ?? DateTimeOffset.MinValue)
            .ToList();
    }

    private static readonly byte[] UserMarker = Encoding.UTF8.GetBytes("\"type\":\"user\"");
    private static readonly byte[] AssistantMarker = Encoding.UTF8.GetBytes("\"type\":\"assistant\"");
    private static readonly byte[] ToolResultMarker = Encoding.UTF8.GetBytes("\"type\":\"tool_result\"");
    private static readonly byte[] TextPartMarker = Encoding.UTF8.GetBytes("\"type\":\"text\"");
    private static readonly byte[] MetaPrefix = Encoding.UTF8.GetBytes("{\"type\":\"");
    private static readonly HashSet<string> WantedMeta = ["custom-title", "ai-title", "last-prompt"];

    private static readonly string[] MachinePrefixes =
    [
        "<local-command", "<command-name>", "<command-message>", "<command-args>", "<task-notification>",
        "<system-reminder>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>",
        "Caveat: The messages below", "[Request interrupted",
    ];

    /// <summary>Reads one transcript. Public so the check program can read a single file.</summary>
    public static SessionInfo Read(string path, long size)
    {
        string? cwd = null, customTitle = null, aiTitle = null, firstPrompt = null, lastPrompt = null;
        DateTimeOffset? first = null, last = null;
        var prompts = 0;

        var bytes = File.ReadAllBytes(path);
        var span = bytes.AsSpan();
        var position = 0;
        while (position < span.Length)
        {
            var end = span[position..].IndexOf((byte)'\n');
            if (end < 0) break;
            var line = span.Slice(position, end);
            position += end + 1;
            if (line.Length <= 2 || line.Length > MaxLineBytes) continue;

            var isMeta = line.StartsWith(MetaPrefix);
            var isUser = !isMeta && line.IndexOf(UserMarker) >= 0;
            if (!isMeta && !isUser && line.IndexOf(AssistantMarker) < 0) continue;
            // What a tool printed is a long user line with nothing the list needs.
            if (isUser && line.IndexOf(ToolResultMarker) >= 0 && line.IndexOf(TextPartMarker) < 0) continue;

            JsonDocument document;
            try { document = JsonDocument.Parse(bytes.AsMemory(position - end - 1, end)); }
            catch (JsonException) { continue; }
            using (document)
            {
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("type", out var typeElement)) continue;
                var type = typeElement.GetString();
                if (isMeta && type is not null && !WantedMeta.Contains(type)) continue;
                switch (type)
                {
                    case "custom-title": customTitle = String(root, "customTitle") ?? customTitle; break;
                    case "ai-title": aiTitle = String(root, "aiTitle") ?? aiTitle; break;
                    case "last-prompt": lastPrompt = Clip(String(root, "lastPrompt")) ?? lastPrompt; break;
                    case "user" or "assistant":
                        if (root.TryGetProperty("isSidechain", out var side) && side.ValueKind == JsonValueKind.True) break;
                        if (String(root, "timestamp") is { } stamp && DateTimeOffset.TryParse(stamp, out var time))
                        {
                            first ??= time;
                            if (last is null || time > last) last = time;
                        }
                        // The launch folder identifies the project; later ones drift as the agent moves.
                        cwd ??= String(root, "cwd") is { Length: > 0 } folder ? folder : null;
                        if (type != "user" || IsTrue(root, "isMeta") || IsTrue(root, "isCompactSummary")) break;
                        foreach (var text in Texts(root))
                        {
                            if (MachinePrefixes.Any(text.StartsWith)) continue;
                            prompts++;
                            firstPrompt ??= Clip(text);
                        }
                        break;
                }
            }
        }

        return new SessionInfo
        {
            Id = System.IO.Path.GetFileNameWithoutExtension(path),
            Path = path,
            Cwd = cwd ?? "",
            CustomTitle = customTitle,
            AiTitle = aiTitle,
            FirstPrompt = firstPrompt,
            LastPrompt = lastPrompt,
            FirstActivity = first,
            LastActivity = last,
            PromptCount = prompts,
            Size = size,
        };
    }

    private static IEnumerable<string> Texts(JsonElement root)
    {
        if (!root.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.Object) yield break;
        if (!message.TryGetProperty("content", out var content)) yield break;
        if (content.ValueKind == JsonValueKind.String)
        {
            if (content.GetString()?.Trim() is { Length: > 0 } text) yield return text;
            yield break;
        }
        if (content.ValueKind != JsonValueKind.Array) yield break;
        foreach (var part in content.EnumerateArray())
        {
            if (part.ValueKind == JsonValueKind.Object && String(part, "type") == "text" && String(part, "text")?.Trim() is { Length: > 0 } text)
                yield return text;
        }
    }

    private static string? String(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool IsTrue(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static string? Clip(string? text) => text is null ? null : text.Length > 400 ? text[..400] : text;
}

/// <summary>Searching the list, the way the macOS panel's title search works.</summary>
public static class SessionSearch
{
    /// <summary>
    /// The sessions whose title, project or prompts contain every word typed, in any case and
    /// with or without accents; titles that match come first.
    /// </summary>
    public static IReadOnlyList<SessionInfo> Filter(IEnumerable<SessionInfo> sessions, string query)
    {
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return sessions.ToList();
        var compare = System.Globalization.CultureInfo.InvariantCulture.CompareInfo;
        const System.Globalization.CompareOptions options =
            System.Globalization.CompareOptions.IgnoreCase | System.Globalization.CompareOptions.IgnoreNonSpace;
        bool Contains(string? text, string word) => text is not null && compare.IndexOf(text, word, options) >= 0;

        return sessions
            .Select(session => new
            {
                Session = session,
                InTitle = words.All(word => Contains(session.Title, word) || Contains(session.ProjectName, word)),
                Anywhere = words.All(word =>
                    Contains(session.Title, word) || Contains(session.ProjectName, word)
                    || Contains(session.FirstPrompt, word) || Contains(session.LastPrompt, word)),
            })
            .Where(hit => hit.Anywhere)
            .OrderByDescending(hit => hit.InTitle)
            .Select(hit => hit.Session)
            .ToList();
    }
}

/// <summary>Which sessions have a Claude Code process running now (<c>~/.claude/sessions/*.json</c>).</summary>
public static class LiveSessions
{
    public enum State { Working, Waiting, Idle }

    public static IReadOnlyDictionary<string, State> Load(string? folder = null)
    {
        folder ??= System.IO.Path.Combine(System.IO.Path.GetDirectoryName(SessionStore.DefaultFolder)!, "sessions");
        var live = new Dictionary<string, State>();
        if (!Directory.Exists(folder)) return live;
        foreach (var file in Directory.EnumerateFiles(folder, "*.json"))
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllBytes(file));
                var root = document.RootElement;
                if (!root.TryGetProperty("sessionId", out var id) || !root.TryGetProperty("pid", out var pid)) continue;
                if (!IsRunning(pid.GetInt32())) continue;
                var status = root.TryGetProperty("status", out var value) ? value.GetString() : null;
                live[id.GetString()!] = status switch { "busy" => State.Working, "waiting" => State.Waiting, _ => State.Idle };
            }
            catch (Exception exception) when (exception is IOException or JsonException or InvalidOperationException or FormatException) { }
        }
        return live;
    }

    private static bool IsRunning(int pid)
    {
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }
}

/// <summary>Short relative times for the list: "now", "5 min", "3 h", "yesterday", "4 d", "12 Nov".</summary>
public static class RelativeTime
{
    public static string Short(DateTimeOffset? date, DateTimeOffset? now = null)
    {
        if (date is null) return "";
        var current = now ?? DateTimeOffset.Now;
        var elapsed = current - date.Value;
        if (elapsed.TotalMinutes < 1) return "now";
        if (elapsed.TotalHours < 1) return $"{(int)elapsed.TotalMinutes} min";
        var local = date.Value.ToLocalTime();
        if (local.Date == current.ToLocalTime().Date) return $"{(int)elapsed.TotalHours} h";
        var days = (current.ToLocalTime().Date - local.Date).Days;
        if (days <= 1) return "yesterday";
        if (days < 7) return $"{days} d";
        return local.ToString(local.Year == current.Year ? "d MMM" : "MMM yyyy", System.Globalization.CultureInfo.InvariantCulture);
    }
}
