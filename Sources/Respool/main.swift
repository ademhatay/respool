import AppKit

let arguments = CommandLine.arguments

// Developer modes can ask for a language, whatever the system speaks: `--lang en` or `--lang tr`.
if let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count {
    L10n.override = arguments[index + 1].hasPrefix("tr") ? .turkish : .english
}
// Otherwise the language chosen in Settings wins over the system's.
if L10n.override == nil, let chosen = UserDefaults.standard.string(forKey: "language") {
    L10n.override = chosen == "tr" ? .turkish : (chosen == "en" ? .english : nil)
}

if arguments.contains("--index") {
    // Developer mode: index once, print what was found, and exit.
    do {
        let library = try Library()
        let started = Date()
        let stats = library.runIndex()
        library.reloadSync()
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let totals = library.projects.flatMap(\.sessions)
        print("tokens in \(Format.tokens(totals.reduce(0) { $0 + $1.inputTokens }))  cached \(Format.tokens(totals.reduce(0) { $0 + $1.cachedTokens }))  out \(Format.tokens(totals.reduce(0) { $0 + $1.outputTokens }))")
        print("files \(stats.total)  updated \(stats.updated)  removed \(stats.removed)  messages \(stats.messages)  \(seconds)s")
        print("sessions \(library.sessionCount)  projects \(library.projects.count)")
        for project in library.projects {
            print("  \(project.name)  \(project.sessions.count) sohbet  \(project.folders.count) klasör  [\(project.key)]")
        }
        let everything = library.projects.flatMap(\.sessions)
        let tracked = everything.filter { library.desktopID(for: $0.id) != nil }.count
        let elsewhere = everything.filter { library.isInOtherOrganization($0.id) }.count
        print("desktop app tracks \(tracked) of \(library.sessionCount), \(elsewhere) under another organization")
        if let index = arguments.firstIndex(of: "--link"), index + 1 < arguments.count {
            print("link \(library.desktopID(for: arguments[index + 1]) ?? "none")")
        }
        if let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count {
            library.query = arguments[index + 1]
            library.searchSync()
            print("query \"\(library.query)\": \(library.results?.count ?? 0) sonuç")
            for hit in (library.results ?? []).prefix(8) {
                print("  \(hit.session.title)  |  \(hit.snippet?.text ?? "(başlık)")")
            }
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
}

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Forgets what an earlier developer run left of the list's choices, so each one starts from
/// the defaults. The bare binary keeps its own preferences, apart from the installed app's.
func forgetListChoices() {
    for key in [
        "calendarExpanded", "projectSort", "hidesSingleSessionProjects", "hidesInactiveProjects", "hiddenProjects",
    ] {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

if let output = value(after: "--snapshot") {
    // Developer mode: draw the panel to a PNG and exit.
    _ = NSApplication.shared
    do {
        forgetListChoices()
        let library = try Library()
        library.reloadSync()
        if arguments.contains("--seed-tags"), ProcessInfo.processInfo.environment["RESPOOL_DB"] != nil {
            // Writes sample tags, so it only runs against a throwaway index.
            let samples = [("acil", 0), ("müşteri", 4), ("araştırma", 5)]
            for (offset, sample) in samples.enumerated() where offset < library.recent.count {
                library.tagEditor = TagEditor(sessionID: library.recent[offset].id, name: sample.0, color: sample.1)
                library.commitTagEditor()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            if arguments.contains("--filter-tag") { library.tagFilter = library.tags.first?.id }
            library.reloadSync()
        }
        // The month view would otherwise stick, since the calendar's shape is remembered.
        library.calendarExpanded = arguments.contains("--month")
        if arguments.contains("--seed-todos"), ProcessInfo.processInfo.environment["RESPOOL_DB"] != nil {
            // Sample tasks for screenshots. They are written to the index, so this only runs
            // against a throwaway copy.
            let day = 86_400.0
            func plan(_ text: String, daysFromNow: Int, linkedTo link: TaskLink? = nil, undated: Bool = false) {
                library.selectedDay = Format.dayKey(Date().addingTimeInterval(Double(daysFromNow) * day))
                library.taskLink = link
                library.addTodo(text)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                if undated, let task = library.tasks.first(where: { $0.text == text }) {
                    library.setDue(task, to: nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
            }
            plan("Vernal gecikmesini müşteriye yaz", daysFromNow: 0)
            plan("Faturaları gönder", daysFromNow: 0)
            plan("Sunucu yedeğini kontrol et", daysFromNow: 1)
            plan("Sözleşme taslağını gözden geçir", daysFromNow: -3)
            plan("Kütüphane sürümlerini yükselt", daysFromNow: 0, undated: true)
            if let session = library.recent.first {
                plan("Oturum açma hatasını tekrar dene", daysFromNow: 0, linkedTo: .session(id: session.id, title: session.title))
            }
            if let project = library.projects.first {
                plan("README'ye kurulum bölümü ekle", daysFromNow: 2, linkedTo: .project(key: project.key, name: project.name))
            }
            // One finished today, to show how a done task reads.
            if let task = library.tasks.first(where: { $0.text == "Faturaları gönder" }) {
                library.toggle(task)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            library.showToday()
            library.reloadSync()
        }
        if arguments.contains("--task-link"), let session = library.recent.first {
            // Shows the chip that names what the next task will be attached to.
            library.taskLink = .session(id: session.id, title: session.title)
        }
        if let key = value(after: "--day"), let date = Format.date(fromDayKey: key) {
            // Opens the calendar on another day.
            library.selectedDay = key
            library.calendarAnchor = date
        }
        if let name = value(after: "--sort"), let sort = ProjectSort.allCases.first(where: { String(describing: $0) == name }) {
            library.projectSort = sort
        }
        if arguments.contains("--hide-single") { library.hidesSingleSessionProjects = true }
        if arguments.contains("--hide-inactive") { library.hidesInactiveProjects = true }
        if let name = value(after: "--hide"), let project = library.allProjects.first(where: { $0.name == name }) {
            library.hide(project)
        }
        if arguments.contains("--open-days") {
            // Opens every day of the week summary, where only today is open by default.
            for day in library.week { library.dayFold[day.day] = true }
        }
        library.reloadSync()
        if arguments.contains("--demo") { library.seedDemo() }
        if arguments.contains("--settings") {
            library.shortcutLabel = Shortcut.standard.label
            library.shortcutLabels[.quickTask] = Shortcut.quickTask.label
            library.shortcutLabels[.quickNote] = Shortcut.quickNote.label
            library.showsOrganizations = arguments.contains("--accounts")
            library.reloadSync()
            library.showingSettings = true
        }
        if arguments.contains("--notes") {
            // Made-up releases, so the notes can be drawn without asking GitHub.
            library.ingest([
                Release(version: "0.15.0", notes: "- Export a week of time as CSV\n- Faster search in long chats\n- Fixed the panel jumping on a second display", date: Date(), url: Updates.page),
                Release(version: "0.14.0", notes: "- Time tracking with a timer and automatic time\n- A timeline of the day and columns for the week\n- Choose where chats open, for everything or per project\n- Drag and resize the panel", date: Date().addingTimeInterval(-9 * 86_400), url: Updates.page),
                Release(version: "0.13.0", notes: "- Quick task and quick note shortcuts\n- Notes\n- Panel position", date: Date().addingTimeInterval(-20 * 86_400), url: Updates.page),
            ], installed: "0.14.0")
            library.showingReleaseNotes = true
        }
        if let period = value(after: "--period"), let chosen = TimePeriod.allCases.first(where: { String(describing: $0) == period }) {
            library.timePeriod = chosen
        }
        if arguments.contains("--timer"), let project = library.projects.first {
            library.startTimer(forProject: project.key)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            library.reloadSync()
        }
        if arguments.contains("--waiting"), library.recent.count >= 2 {
            // Two made-up running sessions: one asking for permission, one that has just finished.
            let asking = library.recent[0].id, done = library.recent[1].id
            library.finishThreshold = 0
            library.ingestLive([:])
            library.ingestLive([done: LiveSession(pid: 1, state: .working, waitingFor: nil, desktopID: nil)])
            library.ingestLive([
                asking: LiveSession(pid: 2, state: .waiting, waitingFor: "permission", desktopID: nil),
                done: LiveSession(pid: 1, state: .idle, waitingFor: nil, desktopID: nil),
            ])
        }
        if arguments.contains("--onboarding") {
            let ok = Snapshot.renderWelcome(library: library, to: output, dark: arguments.contains("--dark"))
            print(ok ? "wrote \(output)" : "snapshot failed")
            exit(ok ? 0 : 1)
        }
        if arguments.contains("--focus-time") {
            // Folds what sits above the time section, so that it is what the drawing shows.
            for section in [PanelSection.todos, PanelSection.notes, PanelSection.pinned, PanelSection.recent]
            where !library.isCollapsed(section) {
                library.toggleSection(section)
            }
        }
        if arguments.contains("--detail"), let session = library.recent.dropFirst().first {
            library.hover = HoverTarget(subject: .session(session), screenY: 0)
        }
        if arguments.contains("--detail-project"), let project = library.projects.max(by: { $0.sessions.count < $1.sessions.count }) {
            library.hover = HoverTarget(subject: .project(project), screenY: 0)
        }
        if arguments.contains("--outline"), let session = library.recent.max(by: { $0.messageCount < $1.messageCount }) {
            library.showOutlineSync(for: session)
        }
        if arguments.contains("--collapse") {
            library.toggleSection(PanelSection.recent)
            if !library.isCollapsed(PanelSection.recent) { library.toggleSection(PanelSection.recent) }
        }
        library.loadActivitySync()
        if arguments.contains("--preview-pins") { library.applyPreviewPins() }
        if let expand = value(after: "--expand") {
            library.expanded = Set(library.projects.filter { $0.name == expand }.map(\.key))
        } else {
            library.expanded = []
        }
        if let query = value(after: "--query") {
            library.query = query
            library.searchSync()
            if arguments.contains("--select") { library.selection = library.results?.first.map { RowKey.hit($0.id) } }
        }
        Snapshot.showsHover = arguments.contains("--hover")
        let height = value(after: "--height").flatMap(Double.init).map { CGFloat($0) } ?? 860
        let ok = Snapshot.render(library: library, to: output, dark: arguments.contains("--dark"), height: height)
        print(ok ? "wrote \(output)" : "snapshot failed")
        exit(ok ? 0 : 1)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

if let mode = value(after: "--login-item") {
    // Developer mode: turn the login item on or off, or print its state.
    if mode == "on" { LoginItem.set(true) }
    if mode == "off" { LoginItem.set(false) }
    print("login item \(LoginItem.isEnabled ? "enabled" : "disabled")")
    exit(0)
}

if arguments.contains("--selftest") {
    // Developer mode: exercise pins, tasks and project edits against the index named by RESPOOL_DB.
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
    func check(_ name: String, _ passed: Bool) {
        print("\(passed ? "ok  " : "FAIL") \(name)")
        if !passed { exit(1) }
    }
    do {
        forgetListChoices()
        let library = try Library()
        library.reloadSync()
        guard let session = library.recent.first, library.projects.count >= 2 else {
            print("FAIL no sessions in index")
            exit(1)
        }
        library.togglePin(session); settle()
        check("pin appears", library.pinned.map(\.id) == [session.id])
        check("pinned session leaves recents", !library.recent.contains { $0.id == session.id })
        library.addTask("ilk görev", to: session.id)
        library.addTask("ikinci görev", to: session.id); settle()
        check("two tasks saved", library.pinned.first?.tasks.map(\.text) == ["ilk görev", "ikinci görev"])
        library.toggle(library.pinned[0].tasks[0]); settle()
        check("done task sorts last", library.pinned[0].tasks.map(\.done) == [false, true])
        check("open count", library.pinned[0].openCount == 1)
        library.delete(library.pinned[0].tasks[0]); settle()
        check("task deleted", library.pinned[0].tasks.count == 1)

        let reopened = try Library()
        reopened.reloadSync()
        check("pins and tasks survive restart", reopened.pinned.first?.tasks.count == 1)

        let first = library.projects[0], second = library.projects[1]
        let total = first.sessions.count + second.sessions.count
        library.merge(second, into: first); settle()
        let merged = library.projects.first { $0.key == first.key }
        check("merge combines sessions", merged?.sessions.count == total)
        check("merged project disappears", !library.projects.contains { $0.key == second.key })
        library.rename(merged!, to: "Yeni Ad"); settle()
        check("rename", library.projects.first { $0.key == first.key }?.name == "Yeni Ad")
        library.separate(library.projects.first { $0.key == first.key }!); settle()
        check("separate restores project", library.projects.contains { $0.key == second.key })

        library.tagEditor = TagEditor(sessionID: session.id, name: "acil", color: 0)
        library.commitTagEditor(); settle()
        check("tag created", library.tags.map(\.name) == ["acil"])
        check("tag applied to session", library.pinned.first?.session.tagIDs == library.tags.map(\.id))
        let tag = library.tags[0]
        library.tagFilter = tag.id; settle()
        check("tag filter lists the session", library.tagged?.map(\.id) == [session.id])
        library.tagEditor = TagEditor(tagID: tag.id, name: "önemli", color: 3)
        library.commitTagEditor(); settle()
        check("tag renamed and recolored", library.tags.first?.name == "önemli" && library.tags.first?.color == 3)
        library.toggle(library.tags[0], on: library.pinned[0].session); settle()
        check("tag removed from session", library.tagged?.isEmpty == true)
        library.delete(library.tags[0]); settle()
        check("tag deleted clears filter", library.tags.isEmpty && library.tagFilter == nil && library.tagged == nil)

        check("organization names stay hidden by default", !library.projects.flatMap(\.sessions).contains { $0.organizationName != nil })
        library.showsOrganizations = true; settle()
        check("organization names appear when enabled", library.projects.flatMap(\.sessions).contains { $0.organizationName != nil })
        if let organization = library.organizations.last, library.organizations.count > 1 {
            let everything = library.sessionCount
            library.organizationFilter = organization.id; settle()
            check("organization filter narrows the list", library.sessionCount < everything && library.sessionCount > 0)
            let foreign = library.projects.flatMap(\.sessions).contains {
                $0.organizationID != nil && $0.organizationID != organization.id
            }
            check("no session from another organization", !foreign)
            library.rename(organization, to: "Takım"); settle()
            check("organization renamed", library.organizations.contains { $0.name == "Takım" })
            library.showsOrganizations = false; settle()
            check("turning accounts off clears the filter", library.organizationFilter == nil && library.sessionCount == everything)
        }

        library.showOutlineSync(for: session)
        check("outline lists every prompt", library.outline?.entries.count == session.messageCount && session.messageCount > 0)
        library.closeOutline()
        check("outline closes", library.outline == nil)
        let wasCollapsed = library.isCollapsed(PanelSection.recent)
        library.toggleSection(PanelSection.recent)
        check("section toggles", library.isCollapsed(PanelSection.recent) != wasCollapsed)
        library.toggleSection(PanelSection.recent)

        let today = library.today
        let tomorrow = Format.dayKey(Date().addingTimeInterval(86_400))
        let past = Format.dayKey(Date().addingTimeInterval(-3 * 86_400))
        func task(_ text: String) -> TaskItem {
            guard let found = library.tasks.first(where: { $0.text == text }) else {
                print("FAIL task not found: \(text)")
                exit(1)
            }
            return found
        }
        check("a new task goes to the selected day, which is today", library.selectedDay == today)
        library.addTodo("faturaları gönder"); settle()
        check("task lands on the selected day", library.tasks(on: today).map(\.text) == ["faturaları gönder"])
        library.setDue(task("faturaları gönder"), to: tomorrow); settle()
        check("setDue moves a task to another day",
              library.tasks(on: tomorrow).map(\.text) == ["faturaları gönder"] && library.tasks(on: today).isEmpty)
        library.selectedDay = past
        library.addTodo("sözleşmeyi gözden geçir"); settle()
        library.showToday()
        check("a task with a past day is overdue", library.overdueTasks.map(\.text) == ["sözleşmeyi gözden geçir"])
        check("an overdue task is not listed under today",
              library.tasks(on: today).isEmpty && library.openTaskCount(on: today) == 0)
        check("the calendar counts open tasks per day",
              library.openTaskCount(on: tomorrow) == 1 && library.openTaskCount(on: past) == 1)
        library.setDue(task("faturaları gönder"), to: nil); settle()
        check("a task without a day is undated",
              library.undatedTasks.map(\.text) == ["faturaları gönder"] && library.tasks(on: tomorrow).isEmpty)

        check("the calendar week starts on Monday", library.calendarDays.count == 7
            && Library.calendar.component(.weekday, from: library.calendarDays[0]) == 2
            && library.calendarDays.contains { Format.dayKey($0) == today })
        library.shiftCalendar(by: 1)
        let nextWeek = Format.dayKey(Date().addingTimeInterval(7 * 86_400))
        check("moving a week carries the selected day", library.selectedDay == nextWeek
            && library.calendarDays.contains { Format.dayKey($0) == nextWeek })
        library.calendarExpanded = true
        check("a month is whole weeks around its days", library.calendarDays.count % 7 == 0
            && library.calendarDays.contains { Format.dayKey($0) == nextWeek })
        library.showToday()
        check("showToday returns to today", library.selectedDay == today
            && library.calendarDays.contains { Format.dayKey($0) == today })
        library.calendarExpanded = false

        library.beginTask(linkedTo: .session(id: session.id, title: session.title))
        check("beginTask prepares the task field", library.taskLink == .session(id: session.id, title: session.title)
            && library.showsTodos && !library.isCollapsed(PanelSection.todos) && library.todoFocusRequest == 1)
        check("escape gives up the link and keeps the panel open",
              library.handleEscape() == false && library.taskLink == nil)
        library.beginTask(linkedTo: .session(id: session.id, title: session.title))
        library.addTodo("oturum açma hatasını tekrar dene"); settle()
        let sessionTask = task("oturum açma hatasını tekrar dene")
        check("task linked to a session", sessionTask.sessionID == session.id && sessionTask.projectKey == nil)
        check("the link is used by one task", library.taskLink == nil)
        check("linkTitle names the session", library.linkTitle(for: sessionTask)?.title == session.title)
        check("it shows under the pinned session, not as undated",
              library.pinned[0].tasks.contains { $0.id == sessionTask.id }
              && !library.undatedTasks.contains { $0.id == sessionTask.id })

        guard let renamed = library.projects.first(where: { $0.key == first.key }),
              let target = library.projects.first(where: { $0.key == second.key }) else {
            print("FAIL projects went missing")
            exit(1)
        }
        library.taskLink = .project(key: renamed.key, name: renamed.name)
        library.addTodo("README'ye kurulum bölümü ekle"); settle()
        var projectTask = task("README'ye kurulum bölümü ekle")
        check("task linked to a project", projectTask.projectKey == renamed.key && projectTask.sessionID.isEmpty)
        check("linkTitle names the project", library.linkTitle(for: projectTask)?.title == renamed.name)
        library.link(projectTask, toProject: target.key); settle()
        projectTask = task("README'ye kurulum bölümü ekle")
        check("link moves a task to another project", projectTask.projectKey == target.key
            && library.linkTitle(for: projectTask)?.title == target.name)

        var started: (folder: String, prompt: String)?
        library.onStartSession = { folder, prompt, _ in started = (folder, prompt) }
        library.run(projectTask)
        let hasFolder = target.folders.contains { FileManager.default.fileExists(atPath: $0) }
        check("run starts a session for a project's task",
              started?.prompt == projectTask.text || (!hasFolder && library.notice == L10n.projectFolderMissing))
        library.startSession(in: target)
        check("a new session starts in a project's folder with nothing typed",
              started.map { $0.prompt == "" && FileManager.default.fileExists(atPath: $0.folder) } == true
              || (!hasFolder && library.notice == L10n.projectFolderMissing))
        library.onStartSession = nil

        // Sorting and hiding only change the list; every project stays known.
        func inOrder(_ sort: ProjectSort) -> Bool {
            zip(library.projects, library.projects.dropFirst()).allSatisfy { !sort.areInOrder($1, $0) }
        }
        check("projects start in order of last activity",
              library.projects.map(\.key) == library.allProjects.map(\.key) && inOrder(.activity))
        library.projectSort = .name; settle()
        check("projects sort by name", inOrder(.name) && library.projects.count == library.allProjects.count)
        library.projectSort = .sessions; settle()
        check("projects sort by session count", inOrder(.sessions))
        library.projectSort = .tokens; settle()
        check("projects sort by token use", inOrder(.tokens))
        library.hidesSingleSessionProjects = true; settle()
        check("single-session projects are left out, in order",
              library.projects.allSatisfy { $0.sessions.count > 1 }
              && library.projects.count == library.allProjects.filter { $0.sessions.count > 1 }.count
              && inOrder(.tokens))
        library.hidesInactiveProjects = true; settle()
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        func wasActive(_ project: ProjectGroup) -> Bool { (project.lastActivity ?? .distantPast) >= cutoff }
        check("projects quiet for 30 days are left out",
              library.projects.allSatisfy(wasActive)
              && library.projects.count == library.allProjects.filter { $0.sessions.count > 1 && wasActive($0) }.count)
        library.projectSort = .activity
        library.hidesSingleSessionProjects = false
        library.hidesInactiveProjects = false; settle()
        check("turning the filters off brings every project back",
              library.projects.map(\.key) == library.allProjects.map(\.key))

        library.hide(target); settle()
        check("a hidden project leaves the list", !library.projects.contains { $0.key == target.key }
            && library.allProjects.contains { $0.key == target.key })
        check("its sessions leave the recents too", !library.recent.contains { $0.projectKey == target.key })
        check("a hidden project still names the tasks linked to it",
              library.linkTitle(for: projectTask)?.title == target.name)
        if let probe = target.sessions.first {
            library.query = String(probe.title.prefix(16)); library.searchSync()
            check("a hidden project is still found by search", library.results?.contains { $0.id == probe.id } == true)
            library.query = ""
        }
        check("hidden projects are remembered",
              UserDefaults.standard.stringArray(forKey: "hiddenProjects") == [target.key]
              && library.hiddenProjectList.map(\.key) == [target.key])
        library.unhide(target); settle()
        check("a hidden project can be brought back",
              library.projects.contains { $0.key == target.key } && library.hiddenProjectList.isEmpty)

        // The week summary, checked against the prompts in the index.
        guard let monday = Library.calendar.dateInterval(of: .weekOfYear, for: Date())?.start else {
            print("FAIL no week found for today")
            exit(1)
        }
        let mondayKey = Format.dayKey(monday)
        let index = try Database(path: Paths.database)
        var typedThisWeek = 0
        try index.query("SELECT count(*) FROM messages WHERE role = 'u' AND ts >= ?", [monday.timeIntervalSince1970]) {
            typedThisWeek = $0.int(0)
        }
        check("the week counts every prompt since Monday", library.week.reduce(0) { $0 + $1.prompts } == typedThisWeek)
        check("its days run from Monday to today, newest first",
              library.week.allSatisfy { $0.day >= mondayKey && $0.day <= today }
              && zip(library.week, library.week.dropFirst()).allSatisfy { $0.day > $1.day })
        check("each day lists its sessions, the most used first",
              library.week.allSatisfy { day in
                  day.work.allSatisfy { $0.prompts > 0 }
                      && zip(day.work, day.work.dropFirst()).allSatisfy { $0.prompts >= $1.prompts }
              })
        check("today starts open and the other days closed", library.isDayExpanded(today)
              && library.week.filter { $0.day != today }.allSatisfy { !library.isDayExpanded($0.day) })
        if let day = library.week.first {
            library.toggleDay(day.day)
            check("a day of the week opens and closes", library.isDayExpanded(day.day) != (day.day == today))
            library.dayFold[day.day] = true
            for section in [PanelSection.recent, PanelSection.week] where library.isCollapsed(section) {
                library.toggleSection(section)
            }
            if let last = library.recent.last, let first = day.work.first {
                library.selection = RowKey.recent(last.id)
                library.moveSelection(1)
                check("keyboard navigation walks from the recents into the week",
                      library.selection == RowKey.day(day.day, first.id))
            }
        }
        check("a day's row still names its session", RowKey.sessionID(RowKey.day(today, "abc")) == "abc")
        library.dayFold = [:]
        library.selection = nil

        // Time: the arithmetic, the timer, and what the prompts add up to.
        let stretch = TimeMath.blocks([0, 60, 120, 2000, 2060, 9000], gap: 900)
        check("moments close together make one stretch of work",
              stretch == [TimeSpan(start: 0, end: 120), TimeSpan(start: 2000, end: 2060), TimeSpan(start: 9000, end: 9000)])
        check("overlapping time is counted once",
              TimeMath.length(TimeMath.merged([TimeSpan(start: 0, end: 100), TimeSpan(start: 50, end: 150), TimeSpan(start: 300, end: 310)])) == 160)
        check("a period takes only its own part of a stretch",
              TimeMath.clipped([TimeSpan(start: 0, end: 100)], from: 40, to: 70) == [TimeSpan(start: 40, end: 70)])
        check("durations read in hours and minutes", Format.clock(3727) == "1:02:07" && Format.shortClock(84) == "1:24" && Format.shortClock(3727) == "1:02:07")
        if library.allProjects.count >= 2 {
            let one = library.allProjects[0].key, other = library.allProjects[1].key
            library.startTimer(forProject: one); settle()
            check("the timer starts for a project", library.runningTimer?.projectKey == one && library.isTiming(one))
            check("a running timer has its row, however short", library.timeReports[.today]?.rows.contains { $0.key == one } == true)
            library.startTimer(forProject: other); settle()
            check("starting another project's timer moves it there", library.isTiming(other) && !library.isTiming(one))
            library.stopTimer(); settle()
            check("the timer stops", library.runningTimer == nil)
            var kept = 0
            try index.query("SELECT count(*) FROM time_entries") { kept = $0.int(0) }
            check("a stretch of a few seconds is not kept", kept == 0)

            let nowStamp = Date().timeIntervalSince1970
            try index.run("INSERT INTO time_entries(project_key, started, ended, open) VALUES(?, ?, ?, 0)", [one, nowStamp - 1200, nowStamp - 600])
            library.reloadSync()
            check("a measured stretch is remembered for its project", library.lastTimeEntries[one]?.length == 600)
            if let row = library.timeReports[.month]?.rows.first(where: { $0.key == one }) {
                check("the total counts time in both sources once",
                      row.total <= row.manual + row.automatic + 1 && row.total + 1 >= max(row.manual, row.automatic))
            }
            check("a project keeps its color across periods",
                  library.time(for: one, in: .week)?.color == library.time(for: one, in: .month)?.color)
            check("the week has seven days and the totals of its days match its rows",
                  library.timeReports[.week]?.days.count == 7)
            library.tracksTimeAutomatically = false; library.reloadSync()
            check("with automatic time off only the timer counts",
                  library.timeReports.values.allSatisfy { $0.rows.allSatisfy { $0.automatic == 0 } }
                  && library.timeReports[.month]?.rows.map(\.key) == [one])
            library.tracksTimeAutomatically = true
            library.deleteLastTimeEntry(forProject: one); settle()
            check("the last stretch can be taken back", library.lastTimeEntries[one] == nil)

            try index.run("INSERT INTO time_entries(project_key, started, ended, open) VALUES(?, ?, ?, 1)", [one, nowStamp - 5000, nowStamp - 4000])
            library.restoreTimer(); library.reloadSync()
            check("a timer left running long ago ends where it was last seen",
                  library.runningTimer == nil && library.lastTimeEntries[one]?.length == 1000)
            try index.run("INSERT INTO time_entries(project_key, started, ended, open) VALUES(?, ?, ?, 1)", [one, nowStamp - 300, nowStamp - 20])
            library.restoreTimer(); library.reloadSync()
            check("a timer the app left a moment ago is picked up again", library.isTiming(one))
            library.stopTimer(); settle()
            try index.exec("DELETE FROM time_entries"); library.reloadSync()
        }

        // Where sessions open.
        if let project = library.allProjects.first, let member = project.sessions.first {
            var asked: OpenMethod?
            library.onOpen = { _, method in asked = method }
            library.openMethod = .automatic
            library.open(member)
            check("a session left to itself opens the automatic way", asked == library.openMethod(for: member))
            if let fresh = library.allProjects.flatMap(\.sessions).first(where: {
                library.desktopID(for: $0.id) == nil && $0.entrypoint != "claude-vscode" && $0.id != member.id
            }) {
                check("a session never seen running opens where its kind lives", library.openMethod(for: fresh) == .automatic)
                library.remember(host: .terminal, for: fresh)
                check("a session goes back to the app it was last seen in", library.openMethod(for: fresh) == .terminal)
                check("a new session starts where its project's sessions run", library.startMethod(forProject: fresh.projectKey) == .terminal)
                library.openMethod = .desktop
                check("a choice made in Settings wins over what was seen", library.openMethod(for: fresh) == .desktop)
                library.openMethod = .automatic
                library.reloadSync()
            }
            check("apps are recognised by their identifier",
                  OpenMethod(hostBundleID: "com.googlecode.iterm2") == .iterm && OpenMethod(hostBundleID: "dev.zed.Zed") == .zed
                  && OpenMethod(hostBundleID: "com.anthropic.claudefordesktop") == .desktop && OpenMethod(hostBundleID: "com.example.other") == nil)
            library.setOpenMethod(.terminal, for: project); settle()
            check("a project can have its own way of opening", library.openMethod(forProject: project.key) == .terminal)
            library.open(member)
            check("its sessions open that way", asked == .terminal)
            library.open(member, with: .desktop)
            check("a session can be opened another way just once", asked == .desktop)
            library.setOpenMethod(nil, for: project); settle()
            check("the project goes back to the general way", library.projectOpenMethods[project.key] == nil)
            library.onOpen = nil
        }
        check("only installed apps are offered for opening",
              library.openMethods.contains(.automatic) && library.openMethods.contains(.terminal))

        // The timer that follows the work.
        if let worker = library.recent.first(where: { !library.isInOtherOrganization($0.id) }) {
            let busy = LiveSession(pid: 1, state: .working, waitingFor: nil, desktopID: nil)
            let quiet = LiveSession(pid: 1, state: .idle, waitingFor: nil, desktopID: nil)
            let start = Date()
            // Every reload reads the running sessions again, so they are replaced for this part.
            func read(_ state: LiveSession, after seconds: TimeInterval = 0) {
                LiveSessions.standIn = [worker.id: state]
                library.ingestLive([worker.id: state], now: start.addingTimeInterval(seconds))
                settle()
            }
            read(quiet); read(busy)
            check("the timer stays off unless following work was asked for", library.runningTimer == nil)
            library.startsTimerAutomatically = true
            read(quiet); read(busy)
            check("a session setting to work starts its project's timer", library.isTiming(worker.projectKey))
            read(quiet, after: 60)
            check("a short silence leaves the timer running", library.isTiming(worker.projectKey))
            read(quiet, after: 60 + Double(library.idleGapMinutes) * 60 + 5)
            check("a silence longer than the idle gap stops it", library.runningTimer == nil)
            library.startsTimerAutomatically = false
            LiveSessions.standIn = nil
            library.ingestLive([:]); settle()
            try index.exec("DELETE FROM time_entries; DELETE FROM session_hosts"); library.reloadSync()
        }

        // The outline opens on the prompt a search matched.
        if let asked = library.recent.first(where: { $0.messageCount > 2 }) {
            library.showOutlineSync(for: asked)
            if let entries = library.outline?.entries, entries.count > 2 {
                let target = entries[entries.count / 2]
                library.showOutlineSync(for: asked, near: target.id)
                check("the outline opens on the matching prompt", library.outline?.focus == target.id)
                library.showOutlineSync(for: asked, near: target.id + 1)
                check("a match in an answer leads to the prompt before it",
                      library.outline?.focus == entries.last { $0.id <= target.id + 1 }?.id)
            }
            library.closeOutline()
        }

        // A transcripts folder that cannot be reached, such as an external disk that is not
        // mounted, must not empty the index.
        let before = library.sessionCount
        setenv("RESPOOL_TRANSCRIPTS", "/Volumes/respool-missing-disk/projects", 1)
        let away = library.runIndex()
        library.reloadSync()
        check("an unreachable transcripts folder leaves the index as it is",
              away.unreachable && away.removed == 0 && library.sessionCount == before)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("respool-empty-\(getpid())")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        setenv("RESPOOL_TRANSCRIPTS", empty.path, 1)
        let hollow = library.runIndex()
        library.reloadSync()
        check("an empty transcripts folder removes nothing either", hollow.removed == 0 && library.sessionCount == before)
        unsetenv("RESPOOL_TRANSCRIPTS")
        try? FileManager.default.removeItem(at: empty)

        // Sessions that want the user.
        if let probe = library.recent.first {
            library.finishThreshold = 0
            library.ingestLive([:])
            library.ingestLive([probe.id: LiveSession(pid: 1, state: .waiting, waitingFor: "permission", desktopID: nil, hostBundleID: "com.googlecode.iterm2")])
            check("a waiting session is listed as needing you", library.needsYou.map(\.id) == [probe.id])
            check("where it runs is remembered", library.sessionHosts[probe.id] == .iterm)
            library.ingestLive([probe.id: LiveSession(pid: 1, state: .working, waitingFor: nil, desktopID: nil)])
            check("it leaves the list once it is working again", library.needsYou.isEmpty)
            library.ingestLive([:])
            settle()
            try index.exec("DELETE FROM session_hosts"); library.reloadSync()
        }

        // Updates and their notes.
        check("versions compare number by number",
              Updates.isNewer("0.10.0", than: "0.9.3") && !Updates.isNewer("0.9.3", than: "0.9.3") && Updates.isNewer("1.0", than: "0.99.9"))
        let listing = Data("""
        [{"tag_name":"v0.9.0","body":"- one","published_at":"2026-01-02T10:00:00Z","html_url":"https://example.com/a"},
         {"tag_name":"v0.10.0","body":"## New\\r\\n- two\\r\\n- **three**","published_at":"2026-02-02T10:00:00Z","html_url":"https://example.com/b"},
         {"tag_name":"v0.11.0","draft":true,"body":""}]
        """.utf8)
        let parsed = Updates.parse(listing) ?? []
        check("releases are read newest first, drafts left out", parsed.map(\.version) == ["0.10.0", "0.9.0"])
        library.ingest(parsed, installed: "0.9.0")
        check("a newer release is announced", library.availableUpdate == "0.10.0")
        library.ingest(parsed, installed: "0.10.0")
        check("the latest release is up to date", library.updateState == .current)
        library.ingest(nil)
        check("an unreachable GitHub is said so", library.updateState == .failed)
        let noteLines = ReleaseNotesView.lines(of: parsed.first?.notes ?? "")
        check("notes read as a heading and its points",
              noteLines.map(\.heading) == [true, false, false] && noteLines.map(\.bullet) == [false, true, true])

        // A panel that was dragged somewhere comes back onto the screen.
        let desk = NSRect(x: 0, y: 0, width: 1470, height: 900)
        let strayed = PanelController.fitted(NSRect(x: 1400, y: -200, width: 2000, height: 100), in: desk)
        check("a remembered frame is brought back onto the screen",
              desk.contains(strayed) && strayed.width <= Metrics.maximumWidth && strayed.height >= Metrics.minimumSize.height)

        // Copies of the transcripts Claude Code is about to delete.
        try? FileManager.default.removeItem(at: Retention.folder)
        library.countBackups()
        func size(_ path: String) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
        }
        check("Claude Code's retention period is a sane number of days", Retention.days >= 1)
        if let terminal = library.recent.first(where: { library.daysLeft(for: $0) != nil }), let last = terminal.lastActivity {
            let age = Date().timeIntervalSince(last) / 86_400
            check("days left run down from the retention period",
                  library.daysLeft(for: terminal) == Int((Double(Retention.days) - age).rounded(.up)))
        }
        check("only sessions in their last days are about to be deleted",
              library.expiringSessions.allSatisfy { session in
                  library.daysLeft(for: session).map { (0...Retention.warningWindow).contains($0) } == true
              })
        if FileManager.default.fileExists(atPath: session.path) {
            library.backUp([session])
            check("a transcript is copied whole into the backups folder",
                  Retention.isBackedUp(session) && size(Retention.backupURL(for: session).path) == size(session.path)
                  && library.backupCount == 1 && library.notice == L10n.backedUpChats(1))
            library.backUp([session])
            check("backing up again keeps a single copy", library.backupCount == 1)
        }
        for expiring in library.expiringSessions { library.backUp([expiring]) }
        check("every session about to be deleted gets its copy",
              library.expiringSessions.allSatisfy {
                  !FileManager.default.fileExists(atPath: $0.path) || library.expiry(of: $0)?.backedUp == true
              }
              && library.unbackedExpiringSessions.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try? FileManager.default.removeItem(at: Retention.folder)
        library.countBackups()
        check("the backups folder can be emptied again", library.backupCount == 0 && library.backupBytes == 0)

        // Dragging to reorder. A day of its own keeps these tasks away from the ones above.
        let far = Format.dayKey(Date().addingTimeInterval(10 * 86_400))
        library.selectedDay = far
        for text in ["bir", "iki", "üç"] { library.addTodo(text) }
        settle()
        var rows = library.tasks(on: far)
        check("new tasks line up in the order they were added", rows.map(\.text) == ["bir", "iki", "üç"])
        library.moveTask(rows[2].id, in: rows, nextTo: rows[0].id, after: false); settle()
        rows = library.tasks(on: far)
        check("a task dragged to the top goes first", rows.map(\.text) == ["üç", "bir", "iki"])
        library.moveTask(rows[0].id, in: rows, nextTo: rows[2].id, after: true); settle()
        rows = library.tasks(on: far)
        check("a task dragged below the last one goes last", rows.map(\.text) == ["bir", "iki", "üç"])
        library.moveTask(rows[0].id, in: rows, nextTo: rows[2].id, after: false); settle()
        rows = library.tasks(on: far)
        check("a task dropped on the upper half of a row goes above it", rows.map(\.text) == ["iki", "bir", "üç"])
        let again = try Library()
        again.reloadSync()
        check("the new order is kept across a restart", again.tasks(on: far).map(\.text) == ["iki", "bir", "üç"])
        library.addTodo("dört"); settle()
        rows = library.tasks(on: far)
        check("a task added after a drag goes last", rows.map(\.text) == ["iki", "bir", "üç", "dört"])
        // Neighbours with no room between them: the list is numbered afresh instead.
        let db = try Database(path: Paths.database)
        try db.run("UPDATE tasks SET position = 1 WHERE text IN ('bir', 'iki', 'üç')")
        library.reloadSync()
        rows = library.tasks(on: far)
        check("tasks with the same place fall back to the order they were added",
              rows.map(\.text) == ["bir", "iki", "üç", "dört"])
        library.moveTask(rows[2].id, in: rows, nextTo: rows[0].id, after: true); settle()
        rows = library.tasks(on: far)
        check("the list is numbered afresh when nothing fits between",
              rows.map(\.text) == ["bir", "üç", "iki", "dört"] && rows.prefix(3).map(\.position) == [1, 2, 3])

        for item in library.tasks { library.delete(item) }
        settle()
        check("tasks deleted", library.tasks.isEmpty && library.undatedTasks.isEmpty && library.overdueTasks.isEmpty)

        // Dragging the pinned sessions.
        let extras = library.recent.prefix(2)
        for extra in extras { library.togglePin(extra) }
        settle()
        var pins = library.pinned.map(\.id)
        check("a session pinned later goes to the end of the pins", pins == [session.id] + extras.map(\.id))
        library.movePin(pins[2], in: pins, nextTo: pins[0], after: false); settle()
        pins = library.pinned.map(\.id)
        check("a pin dragged to the top goes first", pins == [extras[1].id, session.id, extras[0].id])
        library.movePin(pins[0], in: pins, nextTo: pins[2], after: true); settle()
        check("a pin dragged below the last one goes last",
              library.pinned.map(\.id) == [session.id, extras[0].id, extras[1].id])
        for extra in extras { library.togglePin(extra) }
        settle()
        check("the other pins are removed again", library.pinned.map(\.id) == [session.id])

        var announced: [LiveSession.State] = []
        library.finishThreshold = 0
        library.onAttention = { _, _, live in announced.append(live.state) }
        func live(_ state: LiveSession.State) -> [String: LiveSession] {
            ["probe": LiveSession(pid: 1, state: state, waitingFor: nil, desktopID: nil)]
        }
        library.ingestLive(live(.working))
        check("working is not announced", announced.isEmpty && library.attention.isEmpty)
        library.ingestLive(live(.idle))
        check("finishing is announced", announced == [.idle] && library.attention == ["probe"])
        library.ingestLive(live(.working))
        check("working again clears attention", library.attention.isEmpty)
        library.ingestLive(live(.waiting))
        check("waiting is announced", announced == [.idle, .waiting] && library.attention == ["probe"])
        library.ingestLive(live(.waiting))
        check("waiting is announced once", announced.count == 2)
        library.notificationsEnabled = false
        library.ingestLive(live(.working)); library.ingestLive(live(.idle))
        check("no announcement when notifications are off", announced.count == 2 && library.attention == ["probe"])
        library.notificationsEnabled = true
        library.ingestLive([:])
        check("a session that exits is forgotten", library.attention.isEmpty)
        library.onAttention = nil

        library.addNote("müşteriye dönüş yap"); settle()
        check("note saved", library.notes.map(\.text) == ["müşteriye dönüş yap"])
        let tasksBefore = library.tasks.count
        library.makeTask(from: library.notes[0]); settle()
        check("note becomes a task", library.notes.isEmpty && library.tasks.count == tasksBefore + 1)
        if let made = library.tasks.first(where: { $0.text == "müşteriye dönüş yap" }) { library.delete(made); settle() }
        library.addNote("silinecek not"); settle()
        library.delete(library.notes[0]); settle()
        check("note deleted", library.notes.isEmpty)
        library.query = "x"; library.quickNote()
        check("quick note clears the search and asks for focus", library.query.isEmpty && library.noteFocusRequest > 0)
        library.quickTask()
        check("quick task asks for focus", library.todoFocusRequest > 0 && library.taskLink == nil)
        check("shortcut kinds save under their own names",
              Set(ShortcutKind.allCases.map(\.rawValue)).count == 3 && ShortcutKind.quickTask.fallback != ShortcutKind.quickNote.fallback)
        let screen = NSRect(x: 0, y: 0, width: 1470, height: 900)
        let frames = PanelEdge.edges.map { PanelController.frame(for: $0, in: screen) }
        check("every edge keeps the panel on the screen", frames.allSatisfy { screen.contains($0) })
        check("each edge touches its own side",
              frames[0].maxX > 1400 && frames[1].minX < 20 && frames[2].maxY > 880 && frames[3].minY < 20)

        library.togglePin(session); settle()
        check("unpin", library.pinned.isEmpty)
        check("navigation moves down", { library.moveSelection(1); return library.selection != nil }())
        print("all checks passed")
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
