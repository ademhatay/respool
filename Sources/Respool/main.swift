import AppKit

let arguments = CommandLine.arguments

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

if let output = value(after: "--snapshot") {
    // Developer mode: draw the panel to a PNG and exit.
    _ = NSApplication.shared
    do {
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
        if arguments.contains("--settings") {
            library.shortcutLabel = Shortcut.standard.label
            library.showsOrganizations = arguments.contains("--accounts")
            library.reloadSync()
            library.showingSettings = true
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
        library.onStartSession = { started = ($0, $1) }
        library.run(projectTask)
        let hasFolder = target.folders.contains { FileManager.default.fileExists(atPath: $0) }
        check("run starts a session for a project's task",
              started?.prompt == projectTask.text || (!hasFolder && library.notice == "Proje klasörü bulunamadı"))
        library.onStartSession = nil

        for item in library.tasks { library.delete(item) }
        settle()
        check("tasks deleted", library.tasks.isEmpty && library.undatedTasks.isEmpty && library.overdueTasks.isEmpty)

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
