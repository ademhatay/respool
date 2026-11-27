using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Respool.Core;

public enum LiveState { Working, Waiting, Idle }

/// <summary>A Claude Code process that is running now.</summary>
public sealed record LiveSession(string SessionId, int Pid, LiveState State, string? WaitingFor, string? DesktopId, OpenMethod? Host)
{
    public bool IsInTerminal => DesktopId is null;
}

/// <summary>Which sessions have a Claude Code process running (<c>~/.claude/sessions/*.json</c>).</summary>
public static class LiveSessions
{
    public static IReadOnlyDictionary<string, LiveSession> Load(string? folder = null)
    {
        folder ??= Path.Combine(Paths.ClaudeRoot, "sessions");
        var live = new Dictionary<string, LiveSession>();
        if (!Directory.Exists(folder)) return live;
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(folder, "*.json").ToList(); }
        catch (IOException) { return live; }
        foreach (var file in files)
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllBytes(file));
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object) continue;
                if (!root.TryGetProperty("sessionId", out var id) || id.ValueKind != JsonValueKind.String) continue;
                if (!root.TryGetProperty("pid", out var pidElement) || !pidElement.TryGetInt32(out var pid)) continue;
                if (!IsRunning(pid)) continue;
                var status = Text(root, "status");
                var state = status switch { "busy" => LiveState.Working, "waiting" => LiveState.Waiting, _ => LiveState.Idle };
                var desktopId = Text(root, "hostSessionId");
                live[id.GetString()!] = new LiveSession(id.GetString()!, pid, state, Text(root, "waitingFor"), desktopId,
                    desktopId is not null ? OpenMethod.Desktop : HostOf(pid));
            }
            catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { }
        }
        return live;
    }

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool IsRunning(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return true; }
    }

    private static readonly Dictionary<int, OpenMethod?> HostCache = new();

    /// <summary>The app a process runs in: the first ancestor that is an editor or a terminal.</summary>
    public static OpenMethod? HostOf(int pid)
    {
        lock (HostCache)
        {
            if (HostCache.TryGetValue(pid, out var cached)) return cached;
        }
        OpenMethod? found = null;
        var current = pid;
        for (var level = 0; level < 12 && current > 4; level++)
        {
            var parent = ProcessTree.Parent(current);
            if (parent is null) break;
            var name = ProcessTree.Name(parent.Value)?.ToLowerInvariant();
            found = name switch
            {
                "code" or "code - insiders" => OpenMethod.VsCode,
                "cursor" => OpenMethod.Cursor,
                "zed" => OpenMethod.Zed,
                "claude" => OpenMethod.Desktop,
                "windowsterminal" or "conhost" or "openconsole" => OpenMethod.Terminal,
                _ => null,
            };
            if (found is not null) break;
            current = parent.Value;
        }
        lock (HostCache) HostCache[pid] = found;
        return found;
    }

    /// <summary>Brings the window of the app a session runs in to the front.</summary>
    public static bool ActivateHost(int pid)
    {
        var current = pid;
        for (var level = 0; level < 12 && current > 4; level++)
        {
            try
            {
                using var process = Process.GetProcessById(current);
                if (process.MainWindowHandle != IntPtr.Zero && ProcessTree.Activate(process.MainWindowHandle)) return true;
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            if (ProcessTree.Parent(current) is not { } parent) break;
            current = parent;
        }
        // A tab in Windows Terminal: its window belongs to WindowsTerminal.exe, not to an ancestor.
        foreach (var terminal in Process.GetProcessesByName("WindowsTerminal"))
        {
            using (terminal)
            {
                if (terminal.MainWindowHandle != IntPtr.Zero && ProcessTree.Activate(terminal.MainWindowHandle)) return true;
            }
        }
        return false;
    }
}

/// <summary>Parent processes and window activation, through the Win32 API.</summary>
public static class ProcessTree
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct BasicInformation
    {
        public IntPtr Reserved1, PebBaseAddress, Reserved2a, Reserved2b, UniqueProcessId, InheritedFromUniqueProcessId;
    }

    [System.Runtime.InteropServices.DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr handle, int infoClass, ref BasicInformation info, int size, out int returned);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    public static int? Parent(int pid)
    {
        if (!OperatingSystem.IsWindows()) return null;
        try
        {
            using var process = Process.GetProcessById(pid);
            var info = new BasicInformation();
            var status = NtQueryInformationProcess(process.Handle, 0, ref info, System.Runtime.InteropServices.Marshal.SizeOf(info), out _);
            return status == 0 ? info.InheritedFromUniqueProcessId.ToInt32() : null;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }

    public static string? Name(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.ProcessName;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException) { return null; }
    }

    public static bool Activate(IntPtr window)
    {
        if (!OperatingSystem.IsWindows()) return false;
        if (IsIconic(window)) ShowWindow(window, 9 /* SW_RESTORE */);
        return SetForegroundWindow(window);
    }
}

/// <summary>A session the Claude desktop app tracks.</summary>
public sealed record DesktopRecord(string DesktopId, string Organization);

public sealed record DesktopSnapshot(IReadOnlyDictionary<string, DesktopRecord> Records, string? CurrentOrganization)
{
    public static readonly DesktopSnapshot Empty = new(new Dictionary<string, DesktopRecord>(), null);
}

/// <summary>
/// The sessions the Claude desktop app keeps, read from its <c>claude-code-sessions</c> folder:
/// <c>&lt;account&gt;\&lt;organization&gt;\local_*.json</c>.
/// </summary>
public static class DesktopSessions
{
    private static readonly Regex DesktopId = new("\"sessionId\"\\s*:\\s*\"(local_[0-9a-f-]+)\"", RegexOptions.Compiled);
    private static readonly Regex CliId = new("\"cliSessionId\"\\s*:\\s*\"([0-9a-f-]{36})\"", RegexOptions.Compiled);

    /// <summary>The Store version keeps it under Claude-Data; the installer version under Roaming.</summary>
    public static IEnumerable<string> Roots()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var data = Path.Combine(local, "Claude-Data");
        if (Directory.Exists(data))
        {
            foreach (var folder in Directory.EnumerateDirectories(data, "claude_*"))
            {
                var root = Path.Combine(folder, "claude-code-sessions");
                if (Directory.Exists(root)) yield return root;
            }
        }
        var roaming = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "claude-code-sessions");
        if (Directory.Exists(roaming)) yield return roaming;
    }

    public static DesktopSnapshot Load()
    {
        var records = new Dictionary<string, DesktopRecord>();
        string? current = null;
        var newest = DateTime.MinValue;
        try
        {
            foreach (var root in Roots())
            {
                foreach (var account in Directory.EnumerateDirectories(root))
                {
                    foreach (var organization in Directory.EnumerateDirectories(account))
                    {
                        var name = Path.GetFileName(organization);
                        foreach (var file in Directory.EnumerateFiles(organization, "local_*.json"))
                        {
                            var head = Head(file);
                            if (head is null) continue;
                            var desktop = DesktopId.Match(head);
                            var cli = CliId.Match(head);
                            if (!desktop.Success || !cli.Success) continue;
                            records[cli.Groups[1].Value] = new DesktopRecord(desktop.Groups[1].Value, name);
                            var modified = File.GetLastWriteTimeUtc(file);
                            if (modified > newest) { newest = modified; current = name; }
                        }
                    }
                }
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return new DesktopSnapshot(records, current);
    }

    /// <summary>The first 4 KB, where both ids are.</summary>
    private static string? Head(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[4096];
            var count = stream.Read(buffer, 0, buffer.Length);
            return System.Text.Encoding.UTF8.GetString(buffer, 0, count);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}

/// <summary>The account Claude Code is signed in to (<c>~/.claude.json</c>).</summary>
public static class ClaudeAccount
{
    public static (string Id, string Name)? Organization()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var path = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") is { Length: > 0 } config
            ? Path.Combine(config, ".claude.json") : Path.Combine(home, ".claude.json");
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            if (!document.RootElement.TryGetProperty("oauthAccount", out var account)) return null;
            var id = account.TryGetProperty("organizationUuid", out var value) ? value.GetString() : null;
            var name = account.TryGetProperty("organizationName", out var named) ? named.GetString() : null;
            if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(name)) return null;
            if (name.EndsWith("'s Organization", StringComparison.Ordinal) || name.EndsWith("’s Organization", StringComparison.Ordinal)) name = L.Personal;
            return (id, name);
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }
}

/// <summary>
/// Claude Code deletes a terminal session's transcript once it has not been written to for
/// <c>cleanupPeriodDays</c>. Respool warns in the last week and can keep a copy.
/// </summary>
public static class Retention
{
    public const int WarningWindow = 7;

    private static int? _days;

    public static int Days
    {
        get
        {
            if (_days is { } known) return known;
            var days = 30;
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Paths.ClaudeRoot, "settings.json")));
                if (document.RootElement.TryGetProperty("cleanupPeriodDays", out var value) && value.TryGetInt32(out var figure) && figure >= 1) days = figure;
            }
            catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { }
            _days = days;
            return days;
        }
    }

    public static string Folder =>
        Environment.GetEnvironmentVariable("RESPOOL_DB") is { Length: > 0 } db
            ? Path.Combine(Path.GetDirectoryName(db) ?? ".", "Respool Backups")
            : Path.Combine(Paths.Support, "Backups");

    public static bool IsBackedUp(string sessionId) => File.Exists(Path.Combine(Folder, sessionId + ".jsonl"));

    public static bool BackUp(SessionRecord session)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.Copy(session.Path, Path.Combine(Folder, session.Id + ".jsonl"), overwrite: true);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    public static (int Count, long Bytes) CountBackups()
    {
        try
        {
            if (!Directory.Exists(Folder)) return (0, 0);
            var files = new DirectoryInfo(Folder).GetFiles("*.jsonl");
            return (files.Length, files.Sum(file => file.Length));
        }
        catch (IOException) { return (0, 0); }
    }
}
