# Respool for Windows (preview)

A small Windows version of Respool: a panel at the right edge of the screen that lists your
Claude Code chats, searches them, and resumes the one you pick in a terminal. It reads the same
transcripts as the macOS app (`%USERPROFILE%\.claude\projects`, or `CLAUDE_CONFIG_DIR\projects`)
and never changes them.

It is a first version. It has the list, search, running state and resuming; the macOS app's
tasks, notes, time tracking, tags and project pages are not here yet. It has been compiled and
its shared code tested, but not yet run on Windows.

## Use

| Key | Action |
|---|---|
| `Alt+Shift+Space` | Show or hide the panel (or click the tray icon) |
| `↑` `↓` | Move through chats |
| `Enter` | Resume the selected chat |
| `Esc` | Clear the search, then hide the panel |

A chat resumes in a new tab of Windows Terminal when it is installed, otherwise in a Command
Prompt, in the folder it was started in. Right-click a chat to start a new one in its folder,
copy its session ID or show its folder.

## Build

Requires the .NET 8 SDK.

```powershell
dotnet publish windows/Respool.Windows -c Release -r win-x64 --self-contained false -o build/windows
build\windows\Respool.exe
```

`--self-contained true` makes a copy that runs without .NET installed.

The project also builds on macOS and Linux (`EnableWindowsTargeting`), which is how it is
checked. The shared code can be run anywhere against real transcripts:

```bash
dotnet run --project windows/Respool.Check
```
