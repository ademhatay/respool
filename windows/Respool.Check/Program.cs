using System.Diagnostics;
using Respool.Core;

// Checks the shared code: reads the transcripts in the folder given (or Claude Code's own),
// then checks search, relative times and the commands that resume a session.
//
//   dotnet run --project windows/Respool.Check [projects folder]

var failures = 0;
void Check(string name, bool passed)
{
    Console.WriteLine($"{(passed ? "ok  " : "FAIL")} {name}");
    if (!passed) failures++;
}

var folder = args.Length > 0 ? args[0] : SessionStore.DefaultFolder;
var store = new SessionStore(folder);
var clock = Stopwatch.StartNew();
var sessions = store.Scan();
var first = clock.Elapsed;
Check("the transcripts folder can be read", sessions is not null);
if (sessions is null) return 1;
Console.WriteLine($"     {sessions.Count} chats in {sessions.Select(s => s.ProjectName).Distinct().Count()} projects, read in {first.TotalSeconds:F1}s");

Check("chats are found", sessions.Count > 0);
Check("the most recent comes first",
    sessions.Zip(sessions.Skip(1)).All(pair => (pair.First.LastActivity ?? DateTimeOffset.MinValue) >= (pair.Second.LastActivity ?? DateTimeOffset.MinValue)));
Check("every chat has a title", sessions.All(s => !string.IsNullOrWhiteSpace(s.Title)));
Check("every chat has a project", sessions.All(s => !string.IsNullOrWhiteSpace(s.ProjectName)));
Check("each chat is listed once", sessions.Select(s => s.Id).Distinct().Count() == sessions.Count);
Check("prompts are counted", sessions.Sum(s => s.PromptCount) > 0);

clock.Restart();
var again = store.Scan();
Console.WriteLine($"     second scan {clock.Elapsed.TotalMilliseconds:F0} ms");
Check("a second scan reads nothing new and finds the same", again?.Count == sessions.Count);

Check("a folder that is not there is unreachable, not empty", new SessionStore(Path.Combine(folder, "no-such-folder")).Scan() is null);

var sample = sessions.First(s => s.Title.Length >= 4);
var word = sample.Title.Split(' ', StringSplitOptions.RemoveEmptyEntries).OrderByDescending(w => w.Length).First();
Check($"search finds a chat by a word of its title (\"{word}\")", SessionSearch.Filter(sessions, word.ToUpperInvariant()).Contains(sample));
Check("search finds chats by project", SessionSearch.Filter(sessions, sample.ProjectName).Any(s => s.ProjectName == sample.ProjectName));
Check("an empty search lists everything", SessionSearch.Filter(sessions, "  ").Count == sessions.Count);
Check("a search for nonsense finds nothing", SessionSearch.Filter(sessions, "zzqxv-not-a-word-qq").Count == 0);
Check("search ignores accents", SessionSearch.Filter([sample with { CustomTitle = "Değişiklikler" }], "degisiklik").Count == 1);

var now = new DateTimeOffset(2026, 11, 27, 18, 0, 0, TimeSpan.Zero);
Check("relative times read short",
    RelativeTime.Short(now.AddSeconds(-20), now) == "now" && RelativeTime.Short(now.AddMinutes(-5), now) == "5 min"
    && RelativeTime.Short(now.AddDays(-3), now) == "3 d" && RelativeTime.Short(null, now) == "");

var withTerminal = Launch.Resume(sample, hasWindowsTerminal: true);
var withoutTerminal = Launch.Resume(sample, hasWindowsTerminal: false);
Check("Windows Terminal resumes the chat in a new tab",
    withTerminal.FileName == "wt.exe" && withTerminal.Arguments.Contains($"claude --resume {sample.Id}") && withTerminal.Arguments.StartsWith("-w 0 new-tab -d \""));
Check("without it a Command Prompt does", withoutTerminal.FileName == "cmd.exe" && withoutTerminal.Arguments.StartsWith("/k cd /d \""));
Check("a folder that is gone falls back to the home folder",
    Launch.Resume(sample with { Cwd = "/no/such/folder" }, true).Arguments.Contains(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));

var live = LiveSessions.Load();
Console.WriteLine($"     {live.Count} running now");
Check("running sessions are read without failing", live is not null);

Console.WriteLine(failures == 0 ? "all checks passed" : $"{failures} checks failed");
return failures == 0 ? 0 : 1;
