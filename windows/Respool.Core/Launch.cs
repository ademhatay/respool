namespace Respool.Core;

/// <summary>How a session is resumed on Windows: a program and its arguments.</summary>
public sealed record LaunchCommand(string FileName, string Arguments);

public static class Launch
{
    /// <summary>
    /// Resumes a session in Windows Terminal when it is installed, else in a Command Prompt that
    /// stays open. Claude Code finds a session by id in the folder it was started in, so the
    /// command starts there.
    /// </summary>
    public static LaunchCommand Resume(SessionInfo session, bool hasWindowsTerminal) =>
        Start(session.Cwd, $"claude --resume {session.Id}", hasWindowsTerminal);

    /// <summary>Starts a new session in a folder.</summary>
    public static LaunchCommand NewSession(string folder, bool hasWindowsTerminal) =>
        Start(folder, "claude", hasWindowsTerminal);

    private static LaunchCommand Start(string folder, string command, bool hasWindowsTerminal)
    {
        var directory = string.IsNullOrEmpty(folder) || !Directory.Exists(folder)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : folder;
        if (hasWindowsTerminal)
        {
            // A new tab in the open Windows Terminal window, or a new window when there is none.
            return new LaunchCommand("wt.exe", $"-w 0 new-tab -d {Quote(directory)} cmd /k {command}");
        }
        return new LaunchCommand("cmd.exe", $"/k cd /d {Quote(directory)} && {command}");
    }

    /// <summary>A path in double quotes, for a command line. Windows paths cannot hold a quote.</summary>
    public static string Quote(string path) => "\"" + path.Replace("\"", "") + "\"";
}
