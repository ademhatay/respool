import Foundation
import Combine

struct IndexProgress: Equatable {
    var done: Int
    var total: Int
}

/// The panel's state: what is on screen, what is selected, and the user's own pins and tasks.
final class Library: ObservableObject {
    static let projectPreviewCount = 8
    static let recentCount = 6

    @Published private(set) var pinned: [PinnedSession] = []
    @Published private(set) var recent: [SessionRecord] = []
    @Published private(set) var projects: [ProjectGroup] = []
    @Published private(set) var results: [SearchHit]?
    @Published private(set) var sessionCount = 0
    @Published private(set) var indexing: IndexProgress?
    @Published private(set) var hasLoaded = false
    @Published private(set) var notice: String?
    @Published private(set) var live: [String: LiveSession] = [:]

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var selection: String?
    @Published var expanded: Set<String> {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: "expandedProjects") }
    }
    @Published var showingAll: Set<String> = []
    @Published var addingTaskFor: String?
    @Published var renamingProject: String?
    @Published var focusRequest = 0
    /// Empty when the global shortcut could not be registered (another app owns it).
    @Published var shortcutLabel = HotKey.displayName
    @Published private(set) var launchesAtLogin = LoginItem.isEnabled

    var searchFocused = true
    var onOpen: ((SessionRecord) -> Void)?
    var onOpenInDesktop: ((SessionRecord) -> Void)?

    private let readDB: Database
    private let userDB: Database
    private let indexDB: Database
    private let readQueue = DispatchQueue(label: "raf.read", qos: .userInitiated)
    private let userQueue = DispatchQueue(label: "raf.user", qos: .userInitiated)
    private let indexQueue = DispatchQueue(label: "raf.index", qos: .utility)

    private var allSessions: [String: SessionRecord] = [:]
    private var desktop = DesktopSessions.Index()
    private var searchGeneration = 0
    private var isRefreshing = false
    private var noticeGeneration = 0

    init() throws {
        indexDB = try Database(path: Paths.database)
        try indexDB.exec(Schema.sql)
        readDB = try Database(path: Paths.database)
        userDB = try Database(path: Paths.database)
        expanded = Set(UserDefaults.standard.stringArray(forKey: "expandedProjects") ?? [])
    }

    // MARK: - Loading

    private struct Snapshot {
        var sessions: [String: SessionRecord] = [:]
        var pinned: [PinnedSession] = []
        var recent: [SessionRecord] = []
        var projects: [ProjectGroup] = []
        var desktop = DesktopSessions.Index()
        var live: [String: LiveSession] = [:]
    }

    func reload() {
        readQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.buildSnapshot()
            DispatchQueue.main.async { self.apply(snapshot) }
        }
    }

    func reloadSync() {
        apply(buildSnapshot())
    }

    private func apply(_ snapshot: Snapshot) {
        allSessions = snapshot.sessions
        desktop = snapshot.desktop
        live = snapshot.live
        pinned = snapshot.pinned
        recent = snapshot.recent
        projects = snapshot.projects
        sessionCount = snapshot.sessions.count
        hasLoaded = true
        if results != nil { scheduleSearch(immediately: true) }
    }

    private func buildSnapshot() -> Snapshot {
        var identities: [String: (key: String, name: String)] = [:]
        try? readDB.query("SELECT cwd, key, name FROM cwd_projects") { row in
            if let cwd = row.text(0), let key = row.text(1), let name = row.text(2) {
                identities[cwd] = (key, name)
            }
        }
        var merges: [String: String] = [:]
        try? readDB.query("SELECT key, target FROM project_merges") { row in
            if let key = row.text(0), let target = row.text(1) { merges[key] = target }
        }
        var customNames: [String: String] = [:]
        try? readDB.query("SELECT key, name FROM project_names") { row in
            if let key = row.text(0), let name = row.text(1) { customNames[key] = name }
        }

        // A folder without a remote joins a repository of the same name, when that name is unambiguous.
        var gitKeyByName: [String: String?] = [:]
        var defaultNames: [String: String] = [:]
        for identity in identities.values {
            if defaultNames[identity.key] == nil { defaultNames[identity.key] = identity.name }
            guard identity.key.hasPrefix("git:") else { continue }
            let name = ProjectResolver.normalize(identity.name)
            if let existing = gitKeyByName[name], existing != identity.key {
                gitKeyByName[name] = .some(nil)
            } else {
                gitKeyByName[name] = identity.key
            }
        }
        func finalKey(_ key: String) -> String {
            var current = key
            if current.hasPrefix("name:"), let match = gitKeyByName[String(current.dropFirst(5))], let match {
                current = match
            }
            var hops = 0
            while let target = merges[current], hops < 8 {
                current = target
                hops += 1
            }
            return current
        }

        var ordered: [SessionRecord] = []
        try? readDB.query(
            """
            SELECT id, path, cwd, custom_title, ai_title, first_prompt, last_prompt, last_ts, pr_number, pr_url, msg_count
            FROM sessions
            WHERE msg_count > 0 OR (custom_title IS NOT NULL AND custom_title != '')
            ORDER BY last_ts DESC
            """
        ) { row in
            guard let id = row.text(0), let path = row.text(1) else { return }
            let cwd = row.text(2) ?? ""
            var record = SessionRecord(
                id: id, path: path, cwd: cwd,
                customTitle: row.text(3), aiTitle: row.text(4),
                firstPrompt: row.text(5), lastPrompt: row.text(6),
                lastActivity: row.date(7).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil },
                prNumber: row.optionalInt(8), prURL: row.text(9),
                messageCount: row.int(10)
            )
            let identity = identities[cwd] ?? {
                let fallback = ProjectResolver.fallback(cwd.isEmpty ? "Diğer" : cwd, durable: false)
                return (fallback.key, fallback.name)
            }()
            if defaultNames[identity.key] == nil { defaultNames[identity.key] = identity.name }
            record.projectKey = finalKey(identity.key)
            ordered.append(record)
        }
        for index in ordered.indices {
            let key = ordered[index].projectKey
            ordered[index].projectName = customNames[key] ?? defaultNames[key] ?? key
        }

        var snapshot = Snapshot()
        snapshot.desktop = DesktopSessions.load()
        snapshot.live = LiveSessions.load()
        snapshot.sessions = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })

        var mergedInto: [String: [String]] = [:]
        for (key, _) in merges { mergedInto[finalKey(key), default: []].append(key) }

        let grouped = Dictionary(grouping: ordered, by: \.projectKey)
        snapshot.projects = grouped.map { key, sessions in
            ProjectGroup(
                key: key,
                name: sessions[0].projectName,
                sessions: sessions,
                folders: Array(Set(sessions.map(\.cwd).filter { !$0.isEmpty })).sorted(),
                mergedKeys: (mergedInto[key] ?? []).sorted()
            )
        }
        .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }

        var tasksBySession: [String: [TaskItem]] = [:]
        let cutoff = Date().addingTimeInterval(-86_400).timeIntervalSince1970
        try? readDB.query(
            "SELECT id, session_id, text, done, done_at FROM tasks WHERE done = 0 OR done_at > ? ORDER BY done, id",
            [cutoff]
        ) { row in
            guard let sessionID = row.text(1), let text = row.text(2) else { return }
            let task = TaskItem(
                id: Int64(row.int(0)), sessionID: sessionID, text: text, done: row.int(3) == 1, doneAt: row.date(4)
            )
            tasksBySession[sessionID, default: []].append(task)
        }
        var pinnedIDs: [String] = []
        try? readDB.query("SELECT session_id FROM pins ORDER BY position") { row in
            if let id = row.text(0) { pinnedIDs.append(id) }
        }
        snapshot.pinned = pinnedIDs.compactMap { id in
            snapshot.sessions[id].map { PinnedSession(session: $0, tasks: tasksBySession[id] ?? []) }
        }
        let pinnedSet = Set(pinnedIDs)
        snapshot.recent = Array(ordered.lazy.filter { !pinnedSet.contains($0.id) }.prefix(Self.recentCount))
        return snapshot
    }

    // MARK: - Indexing

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        indexQueue.async { [weak self] in
            guard let self else { return }
            self.runIndex { done, total in
                guard done % 4 == 0 || done == total else { return }
                DispatchQueue.main.async { self.indexing = IndexProgress(done: done, total: total) }
            }
            DispatchQueue.main.async {
                self.indexing = nil
                self.isRefreshing = false
                self.reload()
            }
        }
    }

    @discardableResult
    func runIndex(progress: ((Int, Int) -> Void)? = nil) -> IndexStats {
        let stats = Indexer(db: indexDB).run(progress: progress)
        ProjectResolver.refresh(db: indexDB)
        return stats
    }

    // MARK: - Search

    private func scheduleSearch(immediately: Bool = false) {
        searchGeneration += 1
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = nil
            selection = nil
            return
        }
        let sessions = allSessions
        readQueue.asyncAfter(deadline: .now() + (immediately ? 0 : 0.1)) { [weak self] in
            guard let self else { return }
            let hits = self.search(text, in: sessions)
            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.results = hits
                self.selection = hits.first.map { RowKey.hit($0.id) }
            }
        }
    }

    func searchSync() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = text.isEmpty ? nil : search(text, in: allSessions)
    }

    private func search(_ text: String, in sessions: [String: SessionRecord]) -> [SearchHit] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = sessions.values
            .filter { $0.title.range(of: text, options: options) != nil || $0.projectName.range(of: text, options: options) != nil }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(20)
            .map { SearchHit(session: $0, snippet: nil) }
        var positions = Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($1.id, $0) })

        guard let match = Self.ftsQuery(text) else { return hits }
        try? readDB.query(
            """
            SELECT session_id, snippet(messages, 0, char(2), char(3), '…', 14)
            FROM messages WHERE messages MATCH ? ORDER BY rank LIMIT 400
            """,
            [match]
        ) { row in
            guard let id = row.text(0), let raw = row.text(1), let session = sessions[id] else { return }
            if let position = positions[id] {
                if hits[position].snippet == nil { hits[position].snippet = Self.parseSnippet(raw) }
            } else if hits.count < 60 {
                positions[id] = hits.count
                hits.append(SearchHit(session: session, snippet: Self.parseSnippet(raw)))
            }
        }
        return hits
    }

    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated()
            .map { index, token in index == tokens.count - 1 ? "\"\(token)\"*" : "\"\(token)\"" }
            .joined(separator: " ")
    }

    static func parseSnippet(_ raw: String) -> Snippet {
        var text = ""
        var matches: [Range<Int>] = []
        var count = 0
        var openedAt: Int?
        var lastWasSpace = false
        for character in raw {
            if character == "\u{2}" {
                openedAt = count
            } else if character == "\u{3}" {
                if let start = openedAt, start < count { matches.append(start..<count) }
                openedAt = nil
            } else if character == "#" || character == "*" || character == "`" || character == "|" {
                // Markdown punctuation is noise in a one-line excerpt.
                continue
            } else if character.isWhitespace || character.isNewline {
                if !lastWasSpace, count > 0 {
                    text.append(" ")
                    count += 1
                }
                lastWasSpace = true
            } else {
                text.append(character)
                count += 1
                lastWasSpace = false
            }
        }
        return Snippet(text: text, matches: matches)
    }

    // MARK: - Navigation

    func visibleSessions(in project: ProjectGroup) -> ArraySlice<SessionRecord> {
        let limit = showingAll.contains(project.key) ? project.sessions.count : Self.projectPreviewCount
        return project.sessions.prefix(limit)
    }

    private var visibleKeys: [String] {
        if let results { return results.map { RowKey.hit($0.id) } }
        var keys = pinned.map { RowKey.pin($0.id) } + recent.map { RowKey.recent($0.id) }
        for project in projects where expanded.contains(project.key) {
            keys += visibleSessions(in: project).map { RowKey.project($0.id) }
        }
        return keys
    }

    func moveSelection(_ delta: Int) {
        let keys = visibleKeys
        guard !keys.isEmpty else { return }
        guard let selection, let index = keys.firstIndex(of: selection) else {
            self.selection = delta > 0 ? keys.first : keys.last
            return
        }
        self.selection = keys[min(max(index + delta, 0), keys.count - 1)]
    }

    @discardableResult
    func openSelection() -> Bool {
        guard let selection, let session = allSessions[RowKey.sessionID(selection)] else { return false }
        onOpen?(session)
        return true
    }

    func open(_ session: SessionRecord) {
        onOpen?(session)
    }

    func openInDesktop(_ session: SessionRecord) {
        onOpenInDesktop?(session)
    }

    func desktopID(for sessionID: String) -> String? {
        live[sessionID]?.desktopID ?? desktop.records[sessionID]?.desktopID
    }

    /// True when the desktop app filed this session under an organization it is not signed in to.
    /// Its link does nothing until the user switches organization in the Claude app.
    func isInOtherOrganization(_ sessionID: String) -> Bool {
        guard live[sessionID] == nil,
              let current = desktop.currentOrganization,
              let record = desktop.records[sessionID] else { return false }
        return record.organization != current
    }

    /// Re-reads only which sessions are running, which is cheap enough to do while the panel is open.
    func refreshLive() {
        readQueue.async { [weak self] in
            let current = LiveSessions.load()
            DispatchQueue.main.async {
                guard let self, self.live != current else { return }
                self.live = current
            }
        }
    }

    /// Returns true when the panel should close.
    func handleEscape() -> Bool {
        if renamingProject != nil {
            renamingProject = nil
            focusRequest += 1
            return false
        }
        if addingTaskFor != nil {
            addingTaskFor = nil
            focusRequest += 1
            return false
        }
        if !query.isEmpty {
            query = ""
            return false
        }
        return true
    }

    func panelDidOpen() {
        selection = nil
        addingTaskFor = nil
        renamingProject = nil
        focusRequest += 1
        refresh()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        if !LoginItem.set(enabled) { show(notice: "Giriş öğesi değiştirilemedi") }
        launchesAtLogin = LoginItem.isEnabled
    }

    func show(notice text: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, generation == self.noticeGeneration else { return }
            self.notice = nil
        }
    }

    // MARK: - Pins and tasks

    func isPinned(_ id: String) -> Bool {
        pinned.contains { $0.id == id }
    }

    func togglePin(_ session: SessionRecord) {
        let wasPinned = isPinned(session.id)
        write { db in
            if wasPinned {
                try db.run("DELETE FROM pins WHERE session_id = ?", [session.id])
            } else {
                try db.run(
                    "INSERT OR REPLACE INTO pins(session_id, position) VALUES(?, ?)",
                    [session.id, Date().timeIntervalSince1970]
                )
            }
        }
    }

    func addTask(_ text: String, to sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write { db in
            try db.run(
                "INSERT INTO tasks(session_id, text, done, created) VALUES(?, ?, 0, ?)",
                [sessionID, trimmed, Date().timeIntervalSince1970]
            )
        }
    }

    func toggle(_ task: TaskItem) {
        write { db in
            try db.run(
                "UPDATE tasks SET done = ?, done_at = ? WHERE id = ?",
                [!task.done, task.done ? nil : Date().timeIntervalSince1970, task.id]
            )
        }
    }

    func delete(_ task: TaskItem) {
        write { db in try db.run("DELETE FROM tasks WHERE id = ?", [task.id]) }
    }

    // MARK: - Projects

    func toggleExpanded(_ key: String) {
        if expanded.contains(key) {
            expanded.remove(key)
            showingAll.remove(key)
        } else {
            expanded.insert(key)
        }
    }

    func rename(_ project: ProjectGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingProject = nil
        focusRequest += 1
        guard trimmed != project.name else { return }
        write { db in
            if trimmed.isEmpty {
                try db.run("DELETE FROM project_names WHERE key = ?", [project.key])
            } else {
                try db.run("INSERT OR REPLACE INTO project_names(key, name) VALUES(?, ?)", [project.key, trimmed])
            }
        }
    }

    func merge(_ project: ProjectGroup, into target: ProjectGroup) {
        guard project.key != target.key else { return }
        let wasExpanded = expanded.contains(project.key)
        write { db in
            try db.run("INSERT OR REPLACE INTO project_merges(key, target) VALUES(?, ?)", [project.key, target.key])
        }
        if wasExpanded { expanded.insert(target.key) }
    }

    func separate(_ project: ProjectGroup) {
        let keys = project.mergedKeys
        write { db in
            for key in keys { try db.run("DELETE FROM project_merges WHERE key = ?", [key]) }
        }
    }

    private func write(_ work: @escaping (Database) throws -> Void) {
        userQueue.async { [weak self] in
            guard let self else { return }
            do {
                try work(self.userDB)
            } catch {
                DispatchQueue.main.async { self.show(notice: "Kaydedilemedi") }
            }
            self.reload()
        }
    }

    // MARK: - Preview data

    /// Fills the pinned section with sample tasks for screenshots. Nothing is written to disk.
    func applyPreviewPins() {
        let samples = [
            ["Staging ortamında dene", "Hata mesajlarını gözden geçir"],
            [],
            ["Sonuçları ekiple paylaş"],
        ]
        let candidates = Array(recent.filter(\.hasCustomTitle).prefix(samples.count))
        var nextID: Int64 = 1
        pinned = zip(candidates, samples).map { session, texts in
            let tasks = texts.enumerated().map { offset, text -> TaskItem in
                defer { nextID += 1 }
                return TaskItem(id: nextID, sessionID: session.id, text: text, done: offset == 1 && texts.count > 1, doneAt: nil)
            }
            return PinnedSession(session: session, tasks: tasks)
        }
        let used = Set(candidates.map(\.id))
        recent = recent.filter { !used.contains($0.id) }
    }
}
