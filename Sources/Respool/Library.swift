import AppKit
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
    @Published private(set) var tags: [Tag] = []
    /// To-dos that belong to no session, in the order they were added.
    @Published private(set) var todos: [TaskItem] = []
    /// Sessions that are waiting for the user, or finished while the user was not looking.
    @Published private(set) var attention: Set<String> = []
    @Published private(set) var organizations: [Organization] = []
    /// Sessions carrying the selected tag, newest first; nil when no tag is selected.
    @Published private(set) var tagged: [SessionRecord]?

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var selection: String?
    /// Show only one organization's sessions. Terminal-only sessions have none and always show.
    @Published var organizationFilter: String? {
        didSet {
            guard organizationFilter != oldValue else { return }
            UserDefaults.standard.set(organizationFilter, forKey: "organizationFilter")
            reload()
        }
    }
    @Published var tagFilter: Int64? {
        didSet { if tagFilter != oldValue { reload() } }
    }
    @Published var tagEditor: TagEditor?
    /// The row the pointer has rested on long enough to show its details.
    @Published var hover: HoverTarget? {
        didSet { if hover?.subject.key != oldValue?.subject.key { loadActivity() } }
    }
    /// Activity over time for the hovered row; arrives a moment after `hover` is set.
    @Published private(set) var hoverActivity: ActivitySeries?
    @Published var showingSettings = false
    @Published var todoBucket = TodoBucket.today
    @Published var showsTodos: Bool {
        didSet { UserDefaults.standard.set(showsTodos, forKey: "showsTodos") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published private(set) var recordingShortcut = false
    /// Off by default: most people have one organization and do not need the switcher.
    @Published var showsOrganizations: Bool {
        didSet {
            guard showsOrganizations != oldValue else { return }
            UserDefaults.standard.set(showsOrganizations, forKey: "showsOrganizations")
            if !showsOrganizations { organizationFilter = nil }
            reload()
        }
    }
    @Published var expanded: Set<String> {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: "expandedProjects") }
    }
    @Published var showingAll: Set<String> = []
    @Published var addingTaskFor: String?
    @Published var renamingProject: String?
    @Published var focusRequest = 0
    /// Empty when the global shortcut could not be registered (another app owns it).
    @Published var shortcutLabel = ""
    var hotKey: HotKey? {
        didSet { shortcutLabel = hotKey?.isRegistered == true ? hotKey!.shortcut.label : "" }
    }
    @Published private(set) var launchesAtLogin = LoginItem.isEnabled

    var searchFocused = true
    var onOpen: ((SessionRecord) -> Void)?
    var onOpenInDesktop: ((SessionRecord) -> Void)?
    /// Called when a session starts waiting or finishes its work.
    var onAttention: ((String, SessionRecord?, LiveSession) -> Void)?
    /// How long a session must have worked before its finishing is worth announcing.
    var finishThreshold: TimeInterval = 8
    private var workingSince: [String: Date] = [:]
    private var hasSeenLive = false
    private var monitor: Timer?

    private let readDB: Database
    private let userDB: Database
    private let indexDB: Database
    private let readQueue = DispatchQueue(label: "respool.read", qos: .userInitiated)
    private let userQueue = DispatchQueue(label: "respool.user", qos: .userInitiated)
    private let indexQueue = DispatchQueue(label: "respool.index", qos: .utility)

    private var allSessions: [String: SessionRecord] = [:]
    private var desktop = DesktopSessions.Index()
    private var searchGeneration = 0
    private var isRefreshing = false
    private var noticeGeneration = 0

    init() throws {
        indexDB = try Database(path: Paths.database)
        try indexDB.exec(Schema.sql)
        try Schema.migrate(indexDB)
        Schema.addColumns(indexDB)
        readDB = try Database(path: Paths.database)
        userDB = try Database(path: Paths.database)
        expanded = Set(UserDefaults.standard.stringArray(forKey: "expandedProjects") ?? [])
        showsOrganizations = UserDefaults.standard.bool(forKey: "showsOrganizations")
        showsTodos = UserDefaults.standard.object(forKey: "showsTodos") as? Bool ?? true
        notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        organizationFilter = showsOrganizations ? UserDefaults.standard.string(forKey: "organizationFilter") : nil
    }

    // MARK: - Loading

    private struct Snapshot {
        var sessions: [String: SessionRecord] = [:]
        var pinned: [PinnedSession] = []
        var recent: [SessionRecord] = []
        var projects: [ProjectGroup] = []
        var desktop = DesktopSessions.Index()
        var live: [String: LiveSession] = [:]
        var tags: [Tag] = []
        var todos: [TaskItem] = []
        var organizations: [Organization] = []
        var tagged: [SessionRecord]?
    }

    func reload() {
        let organization = organizationFilter, tag = tagFilter, named = showsOrganizations
        readQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.buildSnapshot(organization: organization, tag: tag, namesOrganizations: named)
            DispatchQueue.main.async {
                // A filter changed while this was loading; a newer reload is already on its way.
                guard organization == self.organizationFilter, tag == self.tagFilter else { return }
                self.apply(snapshot)
            }
        }
    }

    func reloadSync() {
        apply(buildSnapshot(organization: organizationFilter, tag: tagFilter, namesOrganizations: showsOrganizations))
    }

    private func apply(_ snapshot: Snapshot) {
        allSessions = snapshot.sessions
        desktop = snapshot.desktop
        ingestLive(snapshot.live)
        tags = snapshot.tags
        todos = snapshot.todos
        organizations = snapshot.organizations
        tagged = snapshot.tagged
        if let tagFilter, !snapshot.tags.contains(where: { $0.id == tagFilter }) { self.tagFilter = nil }
        if let organizationFilter, !snapshot.organizations.contains(where: { $0.id == organizationFilter }) {
            self.organizationFilter = nil
        }
        pinned = snapshot.pinned
        recent = snapshot.recent
        projects = snapshot.projects
        sessionCount = snapshot.sessions.count
        hasLoaded = true
        if results != nil { scheduleSearch(immediately: true) }
    }

    private func buildSnapshot(
        organization organizationFilter: String?, tag tagFilter: Int64?, namesOrganizations: Bool
    ) -> Snapshot {
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
            SELECT id, path, cwd, custom_title, ai_title, first_prompt, last_prompt, last_ts, pr_number, pr_url, msg_count,
                   first_ts, branch, file_size, tok_input, tok_cached, tok_output, context_tokens, model
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
            record.firstActivity = row.date(11).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
            record.branch = row.text(12)
            record.fileSize = row.int(13)
            record.inputTokens = row.int(14)
            record.cachedTokens = row.int(15)
            record.outputTokens = row.int(16)
            record.contextTokens = row.optionalInt(17)
            record.model = row.text(18)
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

        // Organizations: which one each session was filed under, and what to call them.
        var customOrganizationNames: [String: String] = [:]
        try? readDB.query("SELECT id, name FROM organization_names") { row in
            if let id = row.text(0), let name = row.text(1) { customOrganizationNames[id] = name }
        }
        let signedIn = ClaudeAccount.organization()
        let currentOrganization = snapshot.desktop.currentOrganization
        var organizationCounts: [String: Int] = [:]
        for index in ordered.indices {
            guard let record = snapshot.desktop.records[ordered[index].id] else { continue }
            ordered[index].organizationID = record.organization
            organizationCounts[record.organization, default: 0] += 1
        }
        let organizationIDs = organizationCounts.keys.sorted { first, second in
            if (first == currentOrganization) != (second == currentOrganization) { return first == currentOrganization }
            return (organizationCounts[first] ?? 0) > (organizationCounts[second] ?? 0)
        }
        snapshot.organizations = organizationIDs.enumerated().map { position, id in
            let fallback = signedIn?.id == id ? signedIn!.name : "Hesap \(position + 1)"
            return Organization(
                id: id, name: customOrganizationNames[id] ?? fallback,
                isCurrent: id == currentOrganization, sessionCount: organizationCounts[id] ?? 0
            )
        }
        let organizationNames = Dictionary(uniqueKeysWithValues: snapshot.organizations.map { ($0.id, $0.name) })
        for index in ordered.indices {
            guard let id = ordered[index].organizationID else { continue }
            if namesOrganizations { ordered[index].organizationName = organizationNames[id] }
            ordered[index].inOtherOrganization = currentOrganization != nil && id != currentOrganization
                && snapshot.live[ordered[index].id] == nil
        }
        if let organizationFilter, organizationCounts[organizationFilter] != nil {
            ordered = ordered.filter { $0.organizationID == nil || $0.organizationID == organizationFilter }
        }

        // Tags.
        try? readDB.query("SELECT id, name, color FROM tags ORDER BY name COLLATE NOCASE") { row in
            if let name = row.text(1) { snapshot.tags.append(Tag(id: Int64(row.int(0)), name: name, color: row.int(2))) }
        }
        var tagsBySession: [String: [Int64]] = [:]
        try? readDB.query("SELECT session_id, tag_id FROM session_tags ORDER BY tag_id") { row in
            if let id = row.text(0) { tagsBySession[id, default: []].append(Int64(row.int(1))) }
        }
        for index in ordered.indices {
            ordered[index].tagIDs = tagsBySession[ordered[index].id] ?? []
        }
        if let tagFilter, snapshot.tags.contains(where: { $0.id == tagFilter }) {
            snapshot.tagged = ordered.filter { $0.tagIDs.contains(tagFilter) }
        }
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
            "SELECT id, session_id, text, done, done_at, bucket FROM tasks WHERE done = 0 OR done_at > ? ORDER BY done, id",
            [cutoff]
        ) { row in
            guard let sessionID = row.text(1), let text = row.text(2) else { return }
            let task = TaskItem(
                id: Int64(row.int(0)), sessionID: sessionID, text: text, done: row.int(3) == 1,
                doneAt: row.date(4), bucket: row.text(5)
            )
            if sessionID.isEmpty {
                snapshot.todos.append(task)
            } else {
                tasksBySession[sessionID, default: []].append(task)
            }
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
        if let tagged { return tagged.map { RowKey.tagged($0.id) } }
        var keys = pinned.map { RowKey.pin($0.id) } + recent.map { RowKey.recent($0.id) }
        for project in projects where expanded.contains(project.key) {
            keys += visibleSessions(in: project).map { RowKey.project($0.id) }
        }
        return keys
    }

    func moveSelection(_ delta: Int) {
        guard !showingSettings else { return }
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
        guard !showingSettings, let selection, let session = allSessions[RowKey.sessionID(selection)] else { return false }
        onOpen?(session)
        return true
    }

    func open(_ session: SessionRecord) {
        hover = nil
        attention.remove(session.id)
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
            DispatchQueue.main.async { self?.ingestLive(current) }
        }
    }

    /// Returns true when the panel should close.
    func handleEscape() -> Bool {
        if renamingProject != nil {
            renamingProject = nil
            focusRequest += 1
            return false
        }
        if tagEditor != nil {
            tagEditor = nil
            focusRequest += 1
            return false
        }
        if showingSettings {
            showingSettings = false
            focusRequest += 1
            return false
        }
        if addingTaskFor != nil {
            addingTaskFor = nil
            focusRequest += 1
            return false
        }
        if !searchFocused {
            // Escape in any other field goes back to the search field first.
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
        hover = nil
        // Opening the panel counts as seeing what finished; sessions still waiting stay marked.
        attention = attention.filter { live[$0]?.state == .waiting }
        addingTaskFor = nil
        renamingProject = nil
        tagEditor = nil
        showingSettings = false
        cancelShortcutRecording()
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

    // MARK: - Attention

    /// Keeps watching running sessions while the panel is closed.
    func startMonitoring() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshLive()
        }
    }

    /// Takes a fresh reading of the running sessions and works out which ones now need the user:
    /// a session that started waiting, or one that worked for a while and then stopped.
    func ingestLive(_ current: [String: LiveSession], now: Date = Date()) {
        defer { if live != current { live = current } }
        guard hasSeenLive else {
            // The first reading is the baseline; nothing in it is news.
            hasSeenLive = true
            for (id, session) in current where session.state == .working { workingSince[id] = now }
            return
        }
        var updated = attention
        for (id, session) in current {
            let before = live[id]?.state
            switch session.state {
            case .working:
                if workingSince[id] == nil { workingSince[id] = now }
                updated.remove(id)
            case .waiting:
                workingSince[id] = nil
                if before != .waiting {
                    updated.insert(id)
                    announce(id, session)
                }
            case .idle:
                if before == .working, let since = workingSince[id], now.timeIntervalSince(since) >= finishThreshold {
                    updated.insert(id)
                    announce(id, session)
                }
                workingSince[id] = nil
            }
        }
        for id in live.keys where current[id] == nil {
            updated.remove(id)
            workingSince[id] = nil
        }
        if updated != attention { attention = updated }
    }

    private func announce(_ id: String, _ session: LiveSession) {
        guard notificationsEnabled else { return }
        onAttention?(id, allSessions[id], session)
    }

    func session(withID id: String) -> SessionRecord? {
        allSessions[id]
    }

    // MARK: - To-dos

    func addTodo(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bucket = todoBucket
        write { db in
            try db.run(
                "INSERT INTO tasks(session_id, text, done, created, bucket) VALUES('', ?, 0, ?, ?)",
                [trimmed, Date().timeIntervalSince1970, bucket]
            )
        }
    }

    func move(_ todo: TaskItem, to bucket: String) {
        write { db in try db.run("UPDATE tasks SET bucket = ? WHERE id = ?", [bucket, todo.id]) }
    }

    func todos(in bucket: String) -> [TaskItem] {
        todos.filter { ($0.bucket ?? TodoBucket.today) == bucket }
    }

    // MARK: - Activity

    static let activityBuckets = 30

    private func loadActivity() {
        guard let subject = hover?.subject else {
            hoverActivity = nil
            return
        }
        if hoverActivity?.key != subject.key { hoverActivity = nil }
        readQueue.async { [weak self] in
            guard let self else { return }
            let series = self.activity(for: subject)
            DispatchQueue.main.async {
                guard self.hover?.subject.key == subject.key else { return }
                self.hoverActivity = series
            }
        }
    }

    func loadActivitySync() {
        hoverActivity = hover.map { activity(for: $0.subject) }
    }

    /// A session is charted across its own lifetime; a project across the last thirty days.
    private func activity(for subject: HoverSubject) -> ActivitySeries {
        let count = Self.activityBuckets
        var buckets = [Int](repeating: 0, count: count)
        switch subject {
        case .session(let session):
            var stamps: [Double] = []
            try? readDB.query("SELECT ts FROM messages WHERE session_id = ?", [session.id]) { row in
                if let stamp = row.double(0), stamp > 0 { stamps.append(stamp) }
            }
            guard let first = stamps.min(), let last = stamps.max() else {
                return ActivitySeries(key: subject.key, buckets: buckets, startLabel: "", endLabel: "")
            }
            let span = max(last - first, 1)
            for stamp in stamps {
                buckets[min(Int((stamp - first) / span * Double(count)), count - 1)] += 1
            }
            return ActivitySeries(
                key: subject.key, buckets: buckets,
                startLabel: Format.shortDate(Date(timeIntervalSince1970: first)),
                endLabel: Format.shortDate(Date(timeIntervalSince1970: last))
            )
        case .project(let project):
            let ids = Set(project.sessions.map(\.id))
            let day = 86_400.0
            let end = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 + day
            let start = end - Double(count) * day
            try? readDB.query("SELECT session_id, ts FROM messages WHERE role = 'u'") { row in
                guard let id = row.text(0), ids.contains(id), let stamp = row.double(1), stamp >= start, stamp < end else { return }
                buckets[min(Int((stamp - start) / day), count - 1)] += 1
            }
            return ActivitySeries(key: subject.key, buckets: buckets, startLabel: "\(count) gün önce", endLabel: "bugün")
        }
    }

    // MARK: - Shortcut

    /// Starts listening for the next key press, which becomes the new shortcut.
    func beginShortcutRecording() {
        hotKey?.unregister()
        recordingShortcut = true
    }

    func cancelShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false
        hotKey?.register()
        shortcutLabel = hotKey?.isRegistered == true ? hotKey!.shortcut.label : ""
    }

    /// Handles a key press while recording. Escape cancels; a press without ⌘, ⌥ or ⌃ is refused.
    func captureShortcut(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancelShortcutRecording()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            show(notice: "Kısayolda ⌘, ⌥ veya ⌃ olmalı")
            return
        }
        recordingShortcut = false
        guard let hotKey else { return }
        if !hotKey.change(to: shortcut) {
            show(notice: "\(shortcut.label) kullanılamıyor, başka bir uygulamada")
        }
        shortcutLabel = hotKey.isRegistered ? hotKey.shortcut.label : ""
    }

    // MARK: - Tags

    func tags(for session: SessionRecord) -> [Tag] {
        guard !session.tagIDs.isEmpty else { return [] }
        return tags.filter { session.tagIDs.contains($0.id) }
    }

    func toggle(_ tag: Tag, on session: SessionRecord) {
        let has = session.tagIDs.contains(tag.id)
        write { db in
            if has {
                try db.run("DELETE FROM session_tags WHERE session_id = ? AND tag_id = ?", [session.id, tag.id])
            } else {
                try db.run("INSERT OR IGNORE INTO session_tags(session_id, tag_id) VALUES(?, ?)", [session.id, tag.id])
            }
        }
    }

    /// Saves the tag in the editor: renames an existing tag, or creates one and applies it.
    func commitTagEditor() {
        guard let editor = tagEditor else { return }
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        tagEditor = nil
        focusRequest += 1
        guard !name.isEmpty else { return }
        write { db in
            if let id = editor.tagID {
                try db.run("UPDATE tags SET name = ?, color = ? WHERE id = ?", [name, editor.color, id])
            } else {
                try db.run("INSERT OR IGNORE INTO tags(name, color) VALUES(?, ?)", [name, editor.color])
                if let sessionID = editor.sessionID {
                    try db.run(
                        "INSERT OR IGNORE INTO session_tags(session_id, tag_id) SELECT ?, id FROM tags WHERE name = ?",
                        [sessionID, name]
                    )
                }
            }
        }
    }

    func recolor(_ tag: Tag, to color: Int) {
        write { db in try db.run("UPDATE tags SET color = ? WHERE id = ?", [color, tag.id]) }
    }

    func delete(_ tag: Tag) {
        if tagFilter == tag.id { tagFilter = nil }
        write { db in
            try db.run("DELETE FROM session_tags WHERE tag_id = ?", [tag.id])
            try db.run("DELETE FROM tags WHERE id = ?", [tag.id])
        }
    }

    // MARK: - Organizations

    func rename(_ organization: Organization, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != organization.name else { return }
        write { db in
            if trimmed.isEmpty {
                try db.run("DELETE FROM organization_names WHERE id = ?", [organization.id])
            } else {
                try db.run("INSERT OR REPLACE INTO organization_names(id, name) VALUES(?, ?)", [organization.id, trimmed])
            }
        }
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
