using System;
using System.Windows;
using Respool.Core;

namespace Respool.Windows;

/// <summary>The global shortcuts, as Settings names them.</summary>
public enum ShortcutKind { Panel, QuickTask, QuickNote, Switcher }

/// <summary>
/// What the panel's pages, the switcher, the detail card and the welcome screen can ask of the
/// app. <see cref="App"/> implements it; the panel window is one of its parts.
/// </summary>
public interface IAppHost
{
    Library Library { get; }
    Theme Theme { get; }

    /// <summary>Opens a session where it belongs, or with the given method once.</summary>
    void Open(SessionRecord session, OpenMethod? method = null);

    /// <summary>Opens a session in the Claude app.</summary>
    void OpenInDesktop(SessionRecord session);

    /// <summary>Starts a new chat in a project's first folder that exists, with an optional first prompt.</summary>
    void StartSession(ProjectGroup project, string? prompt = null, OpenMethod? method = null);

    /// <summary>Shows the panel, on a project's page.</summary>
    void ShowProjectPage(string projectKey);

    void ShowPanel();
    void HidePanel();

    /// <summary>A short message in the panel's footer for four seconds.</summary>
    void Notice(string text);

    /// <summary>The label of a shortcut as registered now, or "" when it is not.</summary>
    string ShortcutLabel(ShortcutKind kind);

    /// <summary>Stops listening to a shortcut while a new one is being recorded.</summary>
    void SuspendShortcut(ShortcutKind kind);

    /// <summary>Registers a new shortcut; false (and the old one back) when another app has it.</summary>
    bool SetShortcut(ShortcutKind kind, Shortcut shortcut);

    /// <summary>Puts the old shortcut back after a recording was cancelled.</summary>
    void RestoreShortcut(ShortcutKind kind);

    bool LaunchesAtLogin { get; }
    bool SetLaunchesAtLogin(bool on);

    /// <summary>Applies a new light/dark choice to every window.</summary>
    void ApplyTheme();

    /// <summary>Starts Respool again, for a language change.</summary>
    void Relaunch();

    void ShowWelcome();
    void Quit();
}
