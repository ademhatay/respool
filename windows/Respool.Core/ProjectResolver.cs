using System.Diagnostics;

namespace Respool.Core;

public sealed record ProjectIdentity(string Key, string Name, bool Durable);

/// <summary>
/// Groups folders into projects by their git remote, so one repository checked out in several
/// folders is one project. A folder without a remote is named after itself.
/// </summary>
public static class ProjectResolver
{
    public static string Normalize(string name) => name.ToLowerInvariant().Replace('_', '-').Replace(' ', '-');

    public static ProjectIdentity Resolve(string cwd)
    {
        var folder = cwd;
        // A worktree counts as its main repository.
        foreach (var marker in new[] { "/.claude/worktrees/", "\\.claude\\worktrees\\" })
        {
            var at = folder.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (at >= 0) folder = folder[..at];
        }
        // A folder that is not there (an unplugged drive) is tried again later.
        if (!Directory.Exists(folder)) return Fallback(folder, durable: false);
        if (Git(folder, "config --get remote.origin.url") is { Length: > 0 } remote && Slug(remote) is { } slug)
        {
            return new ProjectIdentity("git:" + slug.ToLowerInvariant(), slug.Split('/')[^1], true);
        }
        if (Git(folder, "rev-parse --show-toplevel") is { Length: > 0 } top) return Fallback(top, durable: true);
        return Fallback(folder, durable: true);
    }

    public static ProjectIdentity Fallback(string folder, bool durable)
    {
        var name = LastComponent(folder);
        return new ProjectIdentity("name:" + Normalize(name), name.Length == 0 ? folder : name, durable);
    }

    public static string LastComponent(string path)
    {
        var parts = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 0 ? path : parts[^1];
    }

    /// <summary><c>git@github.com:Org/repo.git</c> and <c>https://github.com/Org/repo</c> become <c>Org/repo</c>.</summary>
    public static string? Slug(string remote)
    {
        var text = remote.Trim();
        if (text.EndsWith(".git", StringComparison.Ordinal)) text = text[..^4];
        var parts = text.Split(['/', ':'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length < 2 ? null : parts[^2] + "/" + parts[^1];
    }

    private static string? Git(string folder, string arguments)
    {
        try
        {
            var info = new ProcessStartInfo("git", $"-C {Opener.Quote(folder)} {arguments}")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var process = Process.Start(info);
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEnd();
            process.StandardError.ReadToEnd();
            if (!process.WaitForExit(10_000)) { process.Kill(); return null; }
            return process.ExitCode == 0 ? output.Trim() : null;
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    /// <summary>Resolves the folders the cache does not know yet, or knew only for now.</summary>
    public static void Refresh(Database db)
    {
        var durable = new Dictionary<string, bool>();
        foreach (var row in db.Query("SELECT cwd, durable FROM cwd_projects")) durable[row.GetString(0)] = row.Flag(1);
        var folders = db.Query("SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL AND cwd != ''").Select(row => row.GetString(0)).ToList();
        var pending = folders.Where(folder => !durable.TryGetValue(folder, out var settled) || !settled).ToList();
        if (pending.Count == 0) return;
        var resolved = new System.Collections.Concurrent.ConcurrentBag<(string, ProjectIdentity)>();
        Parallel.ForEach(pending, new ParallelOptions { MaxDegreeOfParallelism = 6 }, folder => resolved.Add((folder, Resolve(folder))));
        db.Transaction(() =>
        {
            foreach (var (folder, identity) in resolved)
            {
                db.Run("INSERT OR REPLACE INTO cwd_projects(cwd, key, name, durable) VALUES($1, $2, $3, $4)",
                    folder, identity.Key, identity.Name, identity.Durable);
            }
        });
    }
}
