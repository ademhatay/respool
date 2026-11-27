using System.Diagnostics;
using Respool.Core;

// Checks the shared code against real transcripts, in a database of its own that is thrown
// away afterwards, so neither the transcripts nor Respool's own data are touched.
//
//   dotnet run --project windows/Respool.Check [projects folder]

var failures = 0;
void Check(string name, bool passed)
{
    Console.WriteLine($"{(passed ? "ok  " : "FAIL")} {name}");
    if (!passed) failures++;
}

if (args.Length > 0) Environment.SetEnvironmentVariable("RESPOOL_TRANSCRIPTS", args[0]);
var scratch = Path.Combine(Path.GetTempPath(), "respool-check-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(scratch);
var databasePath = Path.Combine(scratch, "respool.db");
Environment.SetEnvironmentVariable("RESPOOL_DB", databasePath);

try
{
    // Pure pieces first.
    Check("a timestamp is read as UTC", Indexer.ParseTimestamp("2026-09-07T06:50:05.161Z"u8) is { } stamp
        && Math.Abs(stamp - new DateTimeOffset(2026, 9, 7, 6, 50, 5, 161, TimeSpan.Zero).ToUnixTimeMilliseconds() / 1000.0) < 0.001);
    Check("a broken timestamp is refused", Indexer.ParseTimestamp("2026-0x-07T06:50:05Z"u8) is null);
    Check("a remote becomes a slug", ProjectResolver.Slug("git@github.com:Org/repo.git") == "Org/repo" && ProjectResolver.Slug("https://github.com/Org/repo") == "Org/repo");
    Check("a Windows folder is named after its last part", ProjectResolver.Fallback(@"C:\Users\x\My_Project", true) is { Key: "name:my-project", Name: "My_Project" });
    Check("moments close together make one stretch", TimeMath.Length(TimeMath.Blocks([0, 60, 120, 2000], 900)) == 120);
    Check("overlapping time counts once", TimeMath.Length(TimeMath.Merged([new Span(0, 100), new Span(50, 150)])) == 150);
    Check("the search query quotes each word", Library.FtsQuery("Hello, wörld") == "\"hello\" \"wörld\"*");
    var snippet = Library.ParseSnippet("a  **\u0002match\u0003**\n b");
    Check("an excerpt is cleaned and marks the match", snippet.Text == "a match b" && snippet.Matches.Count == 1 && snippet.Matches[0] == (2, 7));
    Check("token counts are short", Format.Tokens(512_300) == "512K" && Format.Tokens(999) == "999");
    Check("a prompt for cmd stays one argument", Opener.QuotePrompt("say \"hi\"\nnow") == "\"say 'hi' now\"");

    // The whole pipeline on the real transcripts.
    var settings = Settings.Load(Path.Combine(scratch, "settings.json"));
    using var library = new Library(settings, action => action(), databasePath);
    var clock = Stopwatch.StartNew();
    var stats = library.IndexSync();
    Console.WriteLine($"     indexed {stats.Total} transcripts, {stats.Messages} messages in {clock.Elapsed.TotalSeconds:F1}s");
    Check("the transcripts folder can be read", !stats.Unreachable);
    clock.Restart();
    var again = library.IndexSync();
    Check($"a second run reads nothing again ({again.Updated} updated, {clock.Elapsed.TotalSeconds:F1}s)", again.Updated == 0);

    library.ReloadSync();
    var snapshot = library.Current;
    Console.WriteLine($"     {snapshot.Sessions.Count} chats in {snapshot.AllProjects.Count} projects");
    Check("chats are found", snapshot.Sessions.Count > 0);
    Check("the most recent comes first", snapshot.Sessions.Zip(snapshot.Sessions.Skip(1))
        .All(pair => (pair.First.LastActivity ?? DateTimeOffset.MinValue) >= (pair.Second.LastActivity ?? DateTimeOffset.MinValue)));
    Check("every chat has a title and a project", snapshot.Sessions.All(s => !string.IsNullOrWhiteSpace(s.Title) && !string.IsNullOrWhiteSpace(s.ProjectName)));
    Check("each chat is in exactly one project", snapshot.AllProjects.Sum(p => p.Sessions.Count) == snapshot.Sessions.Count);
    Check("recent chats are at most six", snapshot.Recent.Count <= 6);
    foreach (var project in snapshot.AllProjects.Take(8))
        Console.WriteLine($"     {project.Name,-28} {project.Key,-40} {project.Sessions.Count,4} chats  {Format.Tokens(project.TokenUse),6} tokens");

    var newest = snapshot.Sessions[0];
    var word = newest.Title.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(w => w.Length > 3) ?? newest.Title;
    var hits = library.Search(word);
    Check($"searching for \"{word}\" finds the chat it came from", hits.Any(hit => hit.Session.Id == newest.Id));
    Check("search returns at most 60 chats", hits.Count <= 60);
    var deep = hits.FirstOrDefault(hit => hit.Snippet is not null);
    if (deep is not null) Console.WriteLine($"     excerpt: {deep.Snippet!.Text}");

    var outline = library.Outline(newest);
    Check("the newest chat's prompts can be listed", outline.Entries.Count > 0 || newest.MessageCount == 0);
    var activity = library.Activity(newest);
    Check("its activity has 30 slices", activity.Buckets.Count == 30);

    var today = library.Report(TimePeriod.Today);
    var week = library.Report(TimePeriod.Week);
    var month = library.Report(TimePeriod.Month);
    Console.WriteLine($"     worked today {Format.Worked(today.Total)}, this week {Format.Worked(week.Total)}, this month {Format.Worked(month.Total)}");
    Check("a week has seven days", week.Days.Count == 7);
    Check("a longer period holds at least as much time", today.Total <= week.Total + 1 || today.Total <= month.Total + 1);
    Check("a project's time never exceeds its timer and automatic time together", month.Rows.All(row => row.Total <= row.Manual + row.Automatic + 0.001));
    Check("the week summary starts with the latest day", snapshot.Week.Zip(snapshot.Week.Skip(1)).All(pair => string.CompareOrdinal(pair.First.Day, pair.Second.Day) > 0));

    // The user's own data, in the scratch database.
    library.TogglePin(newest.Id);
    library.AddTodo("check the panel", Format.Today, new TaskLink.ToSession(newest.Id, newest.Title));
    library.AddNote("a note");
    library.SaveTag(null, "check", 3, newest.Id);
    library.Rename(newest, "Renamed in Respool");
    library.StartTimer(newest.ProjectKey);
    library.ReloadSync();
    snapshot = library.Current;
    Check("a pin is kept", snapshot.Pinned.Any(pin => pin.Id == newest.Id));
    Check("a to-do is kept on its day, linked to its chat", library.TasksOn(Format.Today).Any(task => task.SessionId == newest.Id));
    Check("a note is kept", snapshot.Notes.Any(note => note.Text == "a note"));
    Check("a new tag goes on the chat", library.Session(newest.Id)!.TagIds.Count == 1);
    Check("a name given in Respool wins", library.Session(newest.Id)!.Title == "Renamed in Respool");
    Check("the timer runs for the project", library.IsTiming(newest.ProjectKey));
    library.StopTimer();
    library.ReloadSync();
    Check("a timer stopped after a moment leaves nothing", !library.IsTiming(newest.ProjectKey) && !library.Current.LastTimeEntries.ContainsKey(newest.ProjectKey));

    var live = LiveSessions.Load();
    Console.WriteLine($"     {live.Count} Claude Code processes running");
    var desktop = DesktopSessions.Load();
    Console.WriteLine($"     the Claude app tracks {desktop.Records.Count} sessions");
    Console.WriteLine($"     can open in: {string.Join(", ", Opener.Installed.Select(method => method.Title()))}");
}
finally
{
    Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
    try { Directory.Delete(scratch, true); } catch (IOException) { }
}

Console.WriteLine(failures == 0 ? "all checks passed" : $"{failures} checks failed");
return failures == 0 ? 0 : 1;
