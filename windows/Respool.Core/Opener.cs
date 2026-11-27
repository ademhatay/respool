using System.Diagnostics;

namespace Respool.Core;

public enum OpenOutcome { Opened, Failed, AlreadyInTerminal, OpenedInEditor }

/// <summary>A program and its arguments.</summary>
public sealed record LaunchCommand(string FileName, string Arguments, string? WorkingDirectory = null);

/// <summary>
/// Opens sessions where they belong. Respool never edits a transcript: it only runs
/// <c>claude --resume &lt;id&gt;</c>, in Windows Terminal, the Claude app or next to an editor.
/// </summary>
public static class Opener
{
    /// <summary>A new tab in the open Windows Terminal window rather than a new window.</summary>
    public static bool UsesTabs { get; set; } = true;

    /// <summary>With an editor chosen, the chat runs in the editor's own terminal.</summary>
    public static bool UsesEditorTerminal { get; set; }

    /// <summary>
    /// Types a command into an editor's own terminal, in the background; runs the fallback when
    /// it could not. Set by the app, which can press keys; null where nothing can.
    /// </summary>
    public static Action<OpenMethod, string, Action>? EditorTerminal { get; set; }

    private static string Local => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static bool HasWindowsTerminal => File.Exists(Path.Combine(Local, "Microsoft", "WindowsApps", "wt.exe"));

    private static readonly Dictionary<OpenMethod, string?> Editors = new();

    /// <summary>The editor's program, or null when it is not installed.</summary>
    public static string? EditorPath(OpenMethod method)
    {
        lock (Editors)
        {
            if (Editors.TryGetValue(method, out var known)) return known;
            var programs = Path.Combine(Local, "Programs");
            var files = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string?[] candidates = method switch
            {
                OpenMethod.VsCode => [Path.Combine(programs, "Microsoft VS Code", "Code.exe"), Path.Combine(files, "Microsoft VS Code", "Code.exe"), OnPath("code.cmd")],
                OpenMethod.Cursor => [Path.Combine(programs, "cursor", "Cursor.exe"), OnPath("cursor.cmd")],
                OpenMethod.Zed => [Path.Combine(programs, "Zed", "Zed.exe"), Path.Combine(programs, "Zed", "zed.exe"), OnPath("zed.exe")],
                _ => [],
            };
            var found = candidates.FirstOrDefault(path => path is not null && File.Exists(path));
            Editors[method] = found;
            return found;
        }
    }

    private static bool? _hasDesktop;

    /// <summary>The Claude app is installed when its <c>claude://</c> link is registered.</summary>
    public static bool HasDesktopApp
    {
        get
        {
            if (_hasDesktop is { } known) return known;
            var found = false;
            if (OperatingSystem.IsWindows())
            {
                using var key = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("claude");
                found = key is not null;
            }
            found |= DesktopSessions.Roots().Any();
            _hasDesktop = found;
            return found;
        }
    }

    public static bool IsInstalled(OpenMethod method) => method switch
    {
        OpenMethod.Automatic or OpenMethod.Terminal => true,
        OpenMethod.Desktop => HasDesktopApp,
        _ => EditorPath(method) is not null,
    };

    public static IReadOnlyList<OpenMethod> Installed => Enum.GetValues<OpenMethod>().Where(IsInstalled).ToList();

    public static OpenMethod? FirstEditor => new[] { OpenMethod.VsCode, OpenMethod.Cursor, OpenMethod.Zed }.Cast<OpenMethod?>().FirstOrDefault(method => IsInstalled(method!.Value));

    private static string? OnPath(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var folder in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(folder.Trim('"'), name);
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    public static string WorkingDirectory(string cwd) =>
        cwd.Length > 0 && Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>A path in double quotes, for a command line. Windows paths cannot hold a quote.</summary>
    public static string Quote(string path) => "\"" + path.Replace("\"", "") + "\"";

    /// <summary>A prompt as one argument for <c>claude</c> run through cmd: one line, in double quotes.</summary>
    public static string QuotePrompt(string prompt)
    {
        var line = string.Join(" ", prompt.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).Trim();
        return "\"" + line.Replace("\"", "'").Replace("%", "%%") + "\"";
    }

    // MARK: Commands

    /// <summary>
    /// Runs a command in a folder in Windows Terminal when it is installed (a new tab, or a new
    /// window), else in a Command Prompt that stays open after it.
    /// </summary>
    public static LaunchCommand InTerminal(string folder, string command)
    {
        var directory = WorkingDirectory(folder);
        if (HasWindowsTerminal)
        {
            var window = UsesTabs ? "0" : "new";
            return new LaunchCommand("wt.exe", $"-w {window} new-tab -d {Quote(directory)} cmd /k {command}");
        }
        return new LaunchCommand("cmd.exe", $"/k cd /d {Quote(directory)} && {command}", directory);
    }

    public static LaunchCommand Resume(SessionRecord session) => InTerminal(session.Cwd, $"claude --resume {session.Id}");

    public static LaunchCommand NewSession(string folder, string? prompt) =>
        InTerminal(folder, string.IsNullOrWhiteSpace(prompt) ? "claude" : "claude " + QuotePrompt(prompt));

    public static bool Run(LaunchCommand command)
    {
        try
        {
            var info = new ProcessStartInfo(command.FileName, command.Arguments) { UseShellExecute = true };
            if (command.WorkingDirectory is not null) info.WorkingDirectory = command.WorkingDirectory;
            using var process = Process.Start(info);
            return true;
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
    }

    // MARK: Opening

    public static OpenOutcome Open(SessionRecord session, OpenMethod method, LiveSession? live, string? desktopId)
    {
        // A running session is never resumed a second time: its window comes forward.
        if (live is { IsInTerminal: true })
        {
            LiveSessions.ActivateHost(live.Pid);
            return OpenOutcome.AlreadyInTerminal;
        }
        if (live is not null) return OpenInDesktop(session, live.DesktopId) ? OpenOutcome.Opened : OpenOutcome.Failed;
        switch (method)
        {
            case OpenMethod.Automatic:
                if (desktopId is not null) return OpenInDesktop(session, desktopId) ? OpenOutcome.Opened : OpenOutcome.Failed;
                return Run(Resume(session)) ? OpenOutcome.Opened : OpenOutcome.Failed;
            case OpenMethod.Desktop:
                return OpenInDesktop(session, desktopId) ? OpenOutcome.Opened : OpenOutcome.Failed;
            case OpenMethod.Terminal:
                return Run(Resume(session)) ? OpenOutcome.Opened : OpenOutcome.Failed;
            default:
                // The editor opens the folder; the chat goes on in its own terminal, or in one beside it.
                if (!OpenFolder(method, WorkingDirectory(session.Cwd))) return OpenOutcome.Failed;
                if (UsesEditorTerminal && EditorTerminal is { } type)
                {
                    type(method, $"claude --resume {session.Id}", () => Run(Resume(session)));
                    return OpenOutcome.OpenedInEditor;
                }
                return Run(Resume(session)) ? OpenOutcome.OpenedInEditor : OpenOutcome.Failed;
        }
    }

    public static bool OpenFolder(OpenMethod editor, string folder)
    {
        if (EditorPath(editor) is not { } program) return false;
        return Run(new LaunchCommand(program, Quote(folder)));
    }

    /// <summary>The Claude app's link for a session it tracks, else <c>claude --desktop --resume</c>.</summary>
    public static bool OpenInDesktop(SessionRecord session, string? desktopId)
    {
        if (desktopId is not null) return Run(new LaunchCommand($"claude://claude.ai/epitaxy/{desktopId}", ""));
        try
        {
            var info = new ProcessStartInfo("claude", $"--desktop --resume {session.Id}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = WorkingDirectory(session.Cwd),
            };
            using var process = Process.Start(info);
            if (process is null) return false;
            return !process.WaitForExit(15_000) || process.ExitCode == 0;
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>Starts a new chat in a folder, with a first prompt when one is given.</summary>
    public static bool StartSession(string folder, string? prompt, OpenMethod method)
    {
        if (method.IsEditor() && !OpenFolder(method, folder)) return false;
        if (method.IsEditor() && UsesEditorTerminal && EditorTerminal is { } type)
        {
            var command = string.IsNullOrWhiteSpace(prompt) ? "claude" : "claude " + QuotePrompt(prompt).Replace("%%", "%");
            type(method, command, () => Run(NewSession(folder, prompt)));
            return true;
        }
        return Run(NewSession(folder, prompt));
    }

    public static void RevealFolder(string path)
    {
        if (Directory.Exists(path)) Run(new LaunchCommand("explorer.exe", Quote(path)));
        else if (File.Exists(path)) Run(new LaunchCommand("explorer.exe", "/select," + Quote(path)));
    }
}
