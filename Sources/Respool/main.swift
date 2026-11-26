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
        if arguments.contains("--settings") {
            library.shortcutLabel = Shortcut.standard.label
            library.showsOrganizations = arguments.contains("--accounts")
            library.reloadSync()
            library.showingSettings = true
        }
        if arguments.contains("--detail"), let session = library.recent.dropFirst().first {
            library.hover = HoverTarget(subject: .session(session), rowMidY: 200)
        }
        if arguments.contains("--detail-project"), let project = library.projects.max(by: { $0.sessions.count < $1.sessions.count }) {
            library.hover = HoverTarget(subject: .project(project), rowMidY: 200)
        }
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
