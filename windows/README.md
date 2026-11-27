# Respool for Windows (preview)

The Windows version of Respool: a panel at an edge of the screen with your Claude Code chats.
It reads the same transcripts as the macOS app (`%USERPROFILE%\.claude\projects`, or
`CLAUDE_CONFIG_DIR\projects`), never changes them, and keeps its own data in
`%APPDATA%\Respool` in the same database layout as the Mac.

It has what the macOS app has: the Today, Chats and Time tabs; to-dos on a calendar, notes and
the day's summary; pins, tags, projects grouped by git remote and project pages; search inside
chats and the prompt outline; the timer and automatic time; the quick switcher, the detail card,
notifications and Settings. Where Windows differs:

- A chat opens in Windows Terminal (a new tab, or a window), else in a Command Prompt; with an
  editor chosen, the editor opens the folder and the chat starts in a terminal beside it. There
  is no option to type into the editor's own terminal.
- Notifications are tray balloons, and the tray icon's tooltip shows what the Mac's menu bar
  title shows: chats waiting for you and the running timer.

## Use

| Key | Action |
|---|---|
| `Alt+Shift+Space` | Show or hide the panel (or click the tray icon) |
| `Alt+Shift+O` | Quick switcher |
| `Alt+Shift+T` / `Alt+Shift+N` | A new to-do / a new note |
| `↑` `↓`, `Enter` | Move through chats, open the selected one |
| `Ctrl+Enter` | The selected chat's prompt outline |
| `Ctrl+1` … `Ctrl+9` | Open a pinned chat |
| `Ctrl+P` / `Ctrl+,` | Pin or unpin / Settings |
| `Esc` | Clear the search, then hide the panel |

The shortcuts can be changed in Settings. Errors that a view runs into are shown in the footer
and written to `%APPDATA%\Respool\errors.log`.

## Install

Requires the .NET SDK, version 8 or later.

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1 -StartAtLogin
```

This builds Respool, installs it in `%LOCALAPPDATA%\Programs\Respool`, adds it to the Start
menu and to Settings > Apps, and starts it. `-StartAtLogin` also starts it when you sign in;
leave it out if you don't want that, or run the script again with `-NoStartAtLogin` to turn it
off. Run it again after pulling changes to update. `-Uninstall` removes it, and so does its
Uninstall button in Settings > Apps.

## Build

```powershell
dotnet publish windows/Respool.Windows -c Release -r win-x64 --self-contained false -o build/windows
build\windows\Respool.exe
```

`--self-contained true` makes a copy that runs without .NET installed. A framework-dependent
copy also runs on a newer .NET than 8 (`RollForward` is `Major`).

The project also builds on macOS and Linux (`EnableWindowsTargeting`), which is how it is
checked. The shared code can be run anywhere against real transcripts:

```bash
dotnet run --project windows/Respool.Check
```
