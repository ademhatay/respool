using System.Text;
using System.Text.Json;

namespace Respool.Core;

public sealed record IndexStats(int Total, int Updated, int Removed, int Messages, bool Unreachable);

/// <summary>
/// Keeps the index in step with Claude Code's transcripts, read-only. A transcript only ever
/// grows, so one that was read before is read on from where the last run stopped.
/// </summary>
public static class Indexer
{
    private const int MaxLineBytes = 512 * 1024;
    private const int MaxTextLength = 16_000;
    private const int PromptPrefix = 400;

    private sealed record FileInfoRow(string Id, string Path, long Size, double Modified);

    private sealed class Known
    {
        public required string Path;
        public long Size;
        public double Modified;
        public long Offset;
    }

    private sealed record Message(string Text, char Role, double? Time);

    /// <summary>What one run read from one transcript.</summary>
    private sealed class Accumulator
    {
        public string? Cwd, CustomTitle, AiTitle, LastPrompt, FirstPrompt, Branch, PrUrl, Model, Entrypoint, LastUsageId;
        public int? PrNumber;
        public long? ContextTokens;
        public double? FirstTime, LastTime;
        public int PromptCount;
        public long Input, Cached, Output;
        public readonly List<Message> Messages = new();

        public void Stamp(double time)
        {
            FirstTime ??= time;
            LastTime = Math.Max(LastTime ?? 0, time);
        }
    }

    public static IndexStats Run(Database db, string? folder = null, Action<int, int>? progress = null, Action? written = null)
    {
        var files = Discover(folder ?? Paths.Transcripts);
        if (files is null) return new IndexStats(0, 0, 0, 0, true);

        var known = new Dictionary<string, Known>();
        foreach (var row in db.Query("SELECT id, path, file_size, file_mtime, indexed_offset FROM sessions"))
        {
            known[row.GetString(0)] = new Known { Path = row.GetString(1), Size = row.Long(2), Modified = row.Double(3) ?? 0, Offset = row.Long(4) };
        }

        var pending = files.Where(file =>
                !known.TryGetValue(file.Id, out var old) || old.Path != file.Path || old.Size != file.Size || Math.Abs(old.Modified - file.Modified) > 0.001)
            .OrderByDescending(file => file.Size > 24 * 1024 * 1024)
            .ThenByDescending(file => file.Size > 24 * 1024 * 1024 ? file.Size : 0)
            .ThenByDescending(file => file.Modified)
            .ToList();

        int updated = 0, messages = 0, done = 0;
        var batch = new List<(FileInfoRow File, Accumulator Read, long Offset, bool Rebuild)>();
        var lastFlush = DateTime.UtcNow;

        void Flush()
        {
            if (batch.Count == 0) return;
            try
            {
                db.Transaction(() =>
                {
                    foreach (var item in batch) messages += Write(db, item.File, item.Read, item.Offset, item.Rebuild);
                });
                updated += batch.Count;
            }
            catch (Microsoft.Data.Sqlite.SqliteException)
            {
                // The offsets were not saved, so the next run reads these again.
            }
            batch.Clear();
            lastFlush = DateTime.UtcNow;
            written?.Invoke();
        }

        foreach (var file in pending)
        {
            known.TryGetValue(file.Id, out var old);
            var canAppend = old is not null && old.Path == file.Path && old.Offset > 0 && file.Size >= old.Offset;
            var start = canAppend ? old!.Offset : 0;
            try
            {
                var (read, offset) = Parse(file.Path, start);
                batch.Add((file, read, offset, start == 0 && old is not null));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            done++;
            progress?.Invoke(done, pending.Count);
            if (batch.Count >= 24 || (DateTime.UtcNow - lastFlush).TotalSeconds > 0.6) Flush();
        }
        Flush();

        // A transcript that is gone takes its rows with it, unless every one seems gone at
        // once, which is more likely an empty mount point than a clean-out.
        var removed = 0;
        var present = files.Select(file => file.Id).ToHashSet();
        var missing = known.Keys.Where(id => !present.Contains(id)).ToList();
        if (missing.Count > 0 && files.Count > 0)
        {
            db.Transaction(() =>
            {
                foreach (var id in missing)
                {
                    db.Run("DELETE FROM messages WHERE session_id = $1", id);
                    db.Run("DELETE FROM sessions WHERE id = $1", id);
                    removed++;
                }
            });
        }
        return new IndexStats(files.Count, updated, removed, messages, false);
    }

    /// <summary>Every transcript, one folder deep; null when the root cannot be listed.</summary>
    private static List<FileInfoRow>? Discover(string root)
    {
        string[] folders;
        try { folders = Directory.GetDirectories(root); }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }

        var byId = new Dictionary<string, FileInfoRow>();
        foreach (var folder in folders)
        {
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFiles(folder, "*.jsonl").ToList(); }
            catch (IOException) { continue; }
            catch (UnauthorizedAccessException) { continue; }
            foreach (var path in entries)
            {
                var id = Path.GetFileNameWithoutExtension(path);
                if (id.Length != 36) continue;
                try
                {
                    var info = new FileInfo(path);
                    var row = new FileInfoRow(id, path, info.Length, Time.Seconds(new DateTimeOffset(info.LastWriteTimeUtc)));
                    // The same session in two folders: the larger copy is kept.
                    if (!byId.TryGetValue(id, out var other) || row.Size > other.Size) byId[id] = row;
                }
                catch (IOException) { }
            }
        }
        return byId.Values.ToList();
    }

    private static int Write(Database db, FileInfoRow file, Accumulator read, long offset, bool rebuild)
    {
        if (rebuild)
        {
            db.Run("DELETE FROM messages WHERE session_id = $1", file.Id);
            db.Run("DELETE FROM sessions WHERE id = $1", file.Id);
        }
        foreach (var message in read.Messages)
        {
            db.Run("INSERT INTO messages(text, session_id, role, ts) VALUES($1, $2, $3, $4)",
                message.Text, file.Id, message.Role.ToString(), message.Time);
        }
        db.Run("""
            INSERT INTO sessions(id, path, cwd, custom_title, ai_title, last_prompt, first_prompt, first_ts, last_ts,
                entrypoint, branch, pr_url, pr_number, msg_count, file_size, file_mtime, indexed_offset,
                tok_input, tok_cached, tok_output, context_tokens, model)
            VALUES($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                cwd = COALESCE(sessions.cwd, excluded.cwd),
                custom_title = COALESCE(excluded.custom_title, sessions.custom_title),
                ai_title = COALESCE(excluded.ai_title, sessions.ai_title),
                last_prompt = COALESCE(excluded.last_prompt, sessions.last_prompt),
                first_prompt = COALESCE(sessions.first_prompt, excluded.first_prompt),
                first_ts = COALESCE(sessions.first_ts, excluded.first_ts),
                last_ts = MAX(COALESCE(excluded.last_ts, 0), COALESCE(sessions.last_ts, 0)),
                entrypoint = COALESCE(sessions.entrypoint, excluded.entrypoint),
                branch = COALESCE(excluded.branch, sessions.branch),
                pr_url = COALESCE(excluded.pr_url, sessions.pr_url),
                pr_number = COALESCE(excluded.pr_number, sessions.pr_number),
                msg_count = sessions.msg_count + excluded.msg_count,
                file_size = excluded.file_size,
                file_mtime = excluded.file_mtime,
                indexed_offset = excluded.indexed_offset,
                tok_input = sessions.tok_input + excluded.tok_input,
                tok_cached = sessions.tok_cached + excluded.tok_cached,
                tok_output = sessions.tok_output + excluded.tok_output,
                context_tokens = COALESCE(excluded.context_tokens, sessions.context_tokens),
                model = COALESCE(excluded.model, sessions.model)
            """,
            file.Id, file.Path, read.Cwd, read.CustomTitle, read.AiTitle, read.LastPrompt, read.FirstPrompt,
            read.FirstTime, read.LastTime, read.Entrypoint, read.Branch, read.PrUrl, read.PrNumber, read.PromptCount,
            file.Size, file.Modified, offset, read.Input, read.Cached, read.Output, read.ContextTokens, read.Model);
        return read.Messages.Count;
    }

    private static readonly byte[] MetaPrefix = Encoding.UTF8.GetBytes("{\"type\":\"");
    private static readonly byte[] UserMarker = Encoding.UTF8.GetBytes("\"type\":\"user\"");
    private static readonly byte[] AssistantMarker = Encoding.UTF8.GetBytes("\"type\":\"assistant\"");
    private static readonly byte[] ToolResultMarker = Encoding.UTF8.GetBytes("\"type\":\"tool_result\"");
    private static readonly byte[] TextMarker = Encoding.UTF8.GetBytes("\"type\":\"text\"");
    private static readonly byte[] TimestampMarker = Encoding.UTF8.GetBytes("\"timestamp\":\"");
    private static readonly HashSet<string> WantedMeta = ["custom-title", "ai-title", "last-prompt", "pr-link"];

    /// <summary>Reads a transcript from <paramref name="start"/>; returns what it found and where the last whole line ended.</summary>
    private static (Accumulator, long) Parse(string path, long start)
    {
        byte[] bytes;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            stream.Seek(start, SeekOrigin.Begin);
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            bytes = memory.ToArray();
        }
        var read = new Accumulator();
        var position = 0;
        while (position < bytes.Length)
        {
            var end = Array.IndexOf(bytes, (byte)'\n', position);
            // A line still being written is read next time, once it is whole.
            if (end < 0) break;
            var length = end - position;
            if (length > 2 && length <= MaxLineBytes) Line(read, bytes, position, length);
            position = end + 1;
        }
        return (read, start + position);
    }

    private static void Line(Accumulator read, byte[] bytes, int offset, int length)
    {
        var line = bytes.AsSpan(offset, length);
        if (line.StartsWith(MetaPrefix))
        {
            var rest = line[MetaPrefix.Length..];
            var quote = rest[..Math.Min(48, rest.Length)].IndexOf((byte)'"');
            if (quote < 0 || !WantedMeta.Contains(Encoding.UTF8.GetString(rest[..quote]))) return;
        }
        else
        {
            var isUser = line.IndexOf(UserMarker) >= 0;
            if (!isUser && line.IndexOf(AssistantMarker) < 0) return;
            // What a tool printed is long and only its time matters.
            if (isUser && line.IndexOf(ToolResultMarker) >= 0 && line.IndexOf(TextMarker) < 0)
            {
                var at = line.LastIndexOf(TimestampMarker);
                if (at >= 0)
                {
                    var stamp = line[(at + TimestampMarker.Length)..];
                    if (ParseTimestamp(stamp[..Math.Min(24, stamp.Length)]) is { } time) read.Stamp(time);
                }
                return;
            }
        }

        JsonDocument document;
        try { document = JsonDocument.Parse(bytes.AsMemory(offset, length)); }
        catch (JsonException) { return; }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || Text(root, "type") is not { } type) return;
            switch (type)
            {
                case "custom-title": read.CustomTitle = Text(root, "customTitle"); break;
                case "ai-title": read.AiTitle = Text(root, "aiTitle"); break;
                case "last-prompt": read.LastPrompt = Clip(Text(root, "lastPrompt"), PromptPrefix); break;
                case "pr-link":
                    read.PrUrl = Text(root, "prUrl");
                    read.PrNumber = root.TryGetProperty("prNumber", out var number) && number.ValueKind == JsonValueKind.Number ? number.GetInt32() : null;
                    break;
                case "user" or "assistant": HandleMessage(read, root, type == "user"); break;
            }
        }
    }

    private static readonly string[] MachinePrefixes =
    [
        "<local-command", "<command-name>", "<command-message>", "<command-args>", "<task-notification>",
        "<system-reminder>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>",
        "Caveat: The messages below", "[Request interrupted",
    ];

    public static bool IsTypedPrompt(string text) => !MachinePrefixes.Any(prefix => text.StartsWith(prefix, StringComparison.Ordinal));

    private static void HandleMessage(Accumulator read, JsonElement root, bool isUser)
    {
        if (IsTrue(root, "isSidechain")) return;
        double? time = Text(root, "timestamp") is { } stamp ? ParseTimestamp(Encoding.UTF8.GetBytes(stamp)) : null;
        if (time is { } moment) read.Stamp(moment);
        if (read.Cwd is null && Text(root, "cwd") is { Length: > 0 } cwd) read.Cwd = cwd;
        if (Text(root, "gitBranch") is { Length: > 0 } branch) read.Branch = branch;
        read.Entrypoint ??= Text(root, "entrypoint");
        if (isUser && (IsTrue(root, "isMeta") || IsTrue(root, "isCompactSummary"))) return;
        if (!root.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.Object) return;
        if (!isUser) RecordUsage(read, message);

        foreach (var raw in Texts(message))
        {
            var text = raw.Trim();
            if (text.Length == 0) continue;
            if (isUser)
            {
                if (!IsTypedPrompt(text)) continue;
                read.PromptCount++;
                read.FirstPrompt ??= Clip(text, PromptPrefix);
            }
            read.Messages.Add(new Message(Clip(text, MaxTextLength)!, isUser ? 'u' : 'a', time));
        }
    }

    private static void RecordUsage(Accumulator read, JsonElement message)
    {
        if (!message.TryGetProperty("usage", out var usage) || usage.ValueKind != JsonValueKind.Object) return;
        if (Text(message, "id") is not { } id || id == read.LastUsageId) return;
        read.LastUsageId = id;
        long Figure(string name) => usage.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var figure) ? figure : 0;
        var fresh = Figure("input_tokens") + Figure("cache_creation_input_tokens");
        var cached = Figure("cache_read_input_tokens");
        read.Input += fresh;
        read.Cached += cached;
        read.Output += Figure("output_tokens");
        if (fresh + cached > 0) read.ContextTokens = fresh + cached;
        if (Text(message, "model") is { } model && !model.StartsWith('<')) read.Model = model;
    }

    private static IEnumerable<string> Texts(JsonElement message)
    {
        if (!message.TryGetProperty("content", out var content)) yield break;
        if (content.ValueKind == JsonValueKind.String)
        {
            yield return content.GetString() ?? "";
            yield break;
        }
        if (content.ValueKind != JsonValueKind.Array) yield break;
        foreach (var part in content.EnumerateArray())
        {
            if (part.ValueKind == JsonValueKind.Object && Text(part, "type") == "text" && Text(part, "text") is { } text) yield return text;
        }
    }

    /// <summary><c>2026-09-07T06:50:05.161Z</c> as seconds since 1970, always read as UTC.</summary>
    public static double? ParseTimestamp(ReadOnlySpan<byte> text)
    {
        if (text.Length < 19) return null;
        int Digits(ReadOnlySpan<byte> part)
        {
            var value = 0;
            foreach (var digit in part)
            {
                if (digit < '0' || digit > '9') return -1;
                value = value * 10 + (digit - '0');
            }
            return value;
        }
        int year = Digits(text[..4]), month = Digits(text[5..7]), day = Digits(text[8..10]);
        int hour = Digits(text[11..13]), minute = Digits(text[14..16]), second = Digits(text[17..19]);
        if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31 || hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 60) return null;
        double seconds;
        try
        {
            seconds = new DateTimeOffset(year, month, Math.Min(day, DateTime.DaysInMonth(year, month)), hour, minute, Math.Min(second, 59), TimeSpan.Zero).ToUnixTimeSeconds();
        }
        catch (ArgumentOutOfRangeException) { return null; }
        if (text.Length >= 23 && text[19] == '.' && Digits(text[20..23]) is var millis and >= 0) seconds += millis / 1000.0;
        return seconds;
    }

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool IsTrue(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static string? Clip(string? text, int length) => text is null ? null : text.Length > length ? text[..length] : text;
}
