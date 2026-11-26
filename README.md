<p align="center"><img src="docs/icon.png" width="128" alt="Respool icon"></p>

# Respool

A side panel for your Claude Code sessions on macOS. It slides in from the right edge of the
screen, lists every session from every project on your Mac, searches inside them, and takes
you back to the one you pick.

Respool is an independent project and is not affiliated with Anthropic.

> The interface is in Turkish for now. An English localization is planned.

## What it does

- **Search.** Searches session titles and the conversations themselves, and shows an excerpt
  of the match.
- **Projects.** Groups sessions by git remote, so one repository checked out in several
  folders shows up as one project. Projects can be merged and renamed by hand. The menu beside
  the list's title sorts them by last activity, name, session count or token use, and leaves
  out those with a single session or none in the last 30 days. A project can be hidden from its
  context menu; hidden projects are still found by search and come back in Settings.
- **Pins and tasks.** Pin the sessions you keep returning to and keep a short task list on each.
  Drag a pinned session or an open task onto another one to change their order.
- **Calendar.** Plan tasks by day on a calendar at the top of the panel. It shows a week, or a
  whole month when you click its title, with a dot under each day that has open tasks. Tasks
  whose day has passed are listed with today's.
- **Tasks linked to a session or project.** Add a task from a session's or project's context
  menu and it stays attached to it. A linked task has a run button: for a session, the task
  goes on the clipboard and the session opens; for a project, a new session starts in the
  project's folder with the task as its first prompt. A task's own context menu sets its day,
  moves it to a project, or deletes it.
- **Tags.** Give sessions colored tags and filter the list by tag.
- **Week.** A summary of the week so far: a row for each day with the sessions used that day and
  how many prompts went into each. A day opens onto its sessions; today is open to begin with.
  The summary can be turned off in Settings.
- **Notifications.** When a session finishes or starts waiting for you, Respool posts a
  notification and shows a count next to its menu bar icon. Clicking the notification opens
  the session.
- **Live status.** Shows which sessions are running, and whether Claude is working or waiting
  for you.
- **Prompt outline.** Open any session's outline to read everything you asked in it, in order,
  without opening the session itself.
- **Details on hover.** Rest the pointer on a session or project for a card with a context
  gauge, token usage, an activity chart, transcript size, model, branch and folder.
- **Opening.** A session opens where it lives: in the Claude desktop app, by bringing its
  terminal forward, or by resuming it in a new terminal. The button on a project's row starts
  a new session in its folder.
- **Accounts.** Optional. If you use several Claude organizations, a switcher narrows the list
  to one of them.

## Keys

| Key | Action |
|---|---|
| `⌥⇧Space` | Open or close the panel (change it in Settings) |
| `↑` `↓` | Move through sessions |
| `↩` | Open the selected session |
| `esc` | Clear the search, then close the panel |

Hover a session for the pin button; everything else is in its context menu.

## Install

Requires macOS 14 or later and the Xcode command line tools.

```bash
git clone https://github.com/ademhatay/respool.git
cd respool
./scripts/install.sh
```

This builds the app, copies it to `/Applications/Respool.app` and starts it. To build without
installing, run `./scripts/bundle.sh`; the app lands in `build/Respool.app`.

## Your data

Respool only reads Claude Code's files. It never changes them, and nothing leaves your Mac.

| Source | Used for |
|---|---|
| `~/.claude/projects/**/*.jsonl` | Titles, dates, token usage and searchable text |
| `~/.claude/sessions/*.json` | Which sessions are running, and their state |
| `~/.claude.json` | The name of the organization you are signed in to |
| `~/Library/Application Support/Claude/claude-code-sessions` | Links to sessions in the desktop app |

These formats belong to Claude Code and can change between versions; Respool was written
against Claude Code 2.1.332. The index, pins, tasks and tags live in
`~/Library/Application Support/Respool/respool.db`.

## Limits

- A session that belongs to an organization the desktop app is not signed in to cannot be
  opened there. Respool says so; switch organization in the Claude app first.
- Token counts cover the main conversation, not subagents.
- Lines longer than 512 KB in a transcript are skipped by the indexer.

## Development

```bash
.build/release/Respool --index --query "some phrase"       # update the index and try a search
.build/release/Respool --snapshot panel.png --dark         # draw the panel to an image
RESPOOL_DB=/tmp/test.db .build/release/Respool --selftest  # pins, tasks, tags and filters
swift scripts/make-icon.swift                              # regenerate the app icon
```

## License

MIT. See [LICENSE](LICENSE).
