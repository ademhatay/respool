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
    /// Every project the index knows, before the panel sorts and filters them.
    @Published private(set) var allProjects: [ProjectGroup] = []
    @Published private(set) var results: [SearchHit]?
    @Published private(set) var sessionCount = 0
    @Published private(set) var indexing: IndexProgress?
    @Published private(set) var hasLoaded = false
    @Published private(set) var notice: String?
    @Published private(set) var live: [String: LiveSession] = [:]
    @Published private(set) var tags: [Tag] = []
    /// Every task that is open or was finished in the last day, in the order they were added.
    @Published private(set) var tasks: [TaskItem] = []
    /// The day whose tasks are listed, as a day key.
    @Published var selectedDay = Format.dayKey(Date())
    /// A day inside the week or month the calendar is showing.
    @Published var calendarAnchor = Date()
    /// False shows the anchor's week, true its whole month.
    @Published var calendarExpanded = UserDefaults.standard.bool(forKey: "calendarExpanded") {
        didSet { UserDefaults.standard.set(calendarExpanded, forKey: "calendarExpanded") }
    }
    /// What the next task typed into the list will be attached to.
    @Published var taskLink: TaskLink?
    @Published var todoFocusRequest = 0
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
    @Published var projectSort = ProjectSort.activity {
        didSet {
            guard projectSort != oldValue else { return }
            UserDefaults.standard.set(projectSort.rawValue, forKey: "projectSort")
            reload()
        }
    }
    @Published var hidesSingleSessionProjects = false {
        didSet {
            guard hidesSingleSessionProjects != oldValue else { return }
            UserDefaults.standard.set(hidesSingleSessionProjects, forKey: "hidesSingleSessionProjects")
            reload()
        }
    }
    @Published var hidesInactiveProjects = false {
        didSet {
            guard hidesInactiveProjects != oldValue else { return }
            UserDefaults.standard.set(hidesInactiveProjects, forKey: "hidesInactiveProjects")
            reload()
        }
    }
    /// Projects hidden by hand, by key. They still turn up in a search.
    @Published private(set) var hiddenProjects: Set<String> = [] {
        didSet { UserDefaults.standard.set(hiddenProjects.sorted(), forKey: "hiddenProjects") }
    }
    @Published var tagEditor: TagEditor?
    /// The row the pointer has rested on long enough to show its details.
    @Published var hover: HoverTarget? {
        didSet { if hover?.subject.key != oldValue?.subject.key { loadActivity() } }
    }
    /// Activity over time for the hovered row; arrives a moment after `hover` is set.
    @Published private(set) var hoverActivity: ActivitySeries?
    @Published var showingSettings = false
    /// The session whose prompts are being listed, when that view is open.
    @Published private(set) var outline: SessionOutline?
    @Published private(set) var collapsedSections: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections") }
    }
    @Published var showsTodos: Bool {
        didSet { UserDefaults.standard.set(showsTodos, forKey: "showsTodos") }
    }
    @Published var showsWeek = true {
        didSet { UserDefaults.standard.set(showsWeek, forKey: "showsWeek") }
    }
    /// This week's work, one entry for each day that had any, today first.
    @Published private(set) var week: [DaySummary] = []
    /// Which days were opened or closed by hand. A day not named here is open when it is today.
    @Published var dayFold: [String: Bool] = [:]
    /// The copies of transcripts in the backups folder.
    @Published private(set) var backupCount = 0
    @Published private(set) var backupBytes = 0
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    /// The shortcut being recorded in Settings, if any.
    @Published private(set) var recordingKind: ShortcutKind?
    var recordingShortcut: Bool { recordingKind != nil }
    /// Notes jotted down from anywhere, newest first.
    @Published private(set) var notes: [NoteItem] = []
    @Published var noteFocusRequest = 0
    /// The screen edge the panel opens from. Takes effect the next time the panel opens.
    @Published var panelEdge: PanelEdge {
        didSet { UserDefaults.standard.set(panelEdge.rawValue, forKey: "panelEdge") }
    }
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
    /// The releases GitHub lists, newest first, once they have been asked for.
    @Published private(set) var releases: [Release] = []
    @Published private(set) var updateState = UpdateState.unknown
    /// The version of this copy of the app, which the releases are measured against.
    @Published private(set) var installedVersion = Updates.installed
    @Published var showingReleaseNotes = false {
        didSet { if showingReleaseNotes, releases.isEmpty { checkForUpdates() } }
    }
    /// Off by default, so that nothing is asked of the network unless the user wants it.
    @Published var checksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(checksForUpdates, forKey: "checksForUpdates")
            if checksForUpdates { checkForUpdatesIfDue() }
        }
    }
    /// The interface language: "tr", "en", or empty to follow the system. A change restarts the app.
    @Published var languageChoice: String {
        didSet {
            guard languageChoice != oldValue else { return }
            if languageChoice.isEmpty {
                UserDefaults.standard.removeObject(forKey: "language")
            } else {
                UserDefaults.standard.set(languageChoice, forKey: "language")
            }
            Updates.relaunch()
        }
    }
    /// The panel's look: "light", "dark", or empty to follow the system.
    @Published var appearanceChoice: String {
        didSet { UserDefaults.standard.set(appearanceChoice, forKey: "appearance") }
    }
    /// How long each project was worked on, for each period the panel can show.
    @Published private(set) var timeReports: [TimePeriod: TimeReport] = [:]
    @Published private(set) var runningTimer: RunningTimer?
    /// The last stretch the timer measured for each project, which can be taken back.
    @Published private(set) var lastTimeEntries: [String: TimeEntry] = [:]
    @Published var timePeriod: TimePeriod {
        didSet { UserDefaults.standard.set(timePeriod.rawValue, forKey: "timePeriod") }
    }
    @Published var showsTime: Bool {
        didSet { UserDefaults.standard.set(showsTime, forKey: "showsTime") }
    }
    /// Works time out from when prompts were typed and answered, without a timer.
    @Published var tracksTimeAutomatically: Bool {
        didSet {
            guard tracksTimeAutomatically != oldValue else { return }
            UserDefaults.standard.set(tracksTimeAutomatically, forKey: "tracksTimeAutomatically")
            reload()
        }
    }
    /// A silence longer than this many minutes ends a stretch of automatic time.
    @Published var idleGapMinutes: Int {
        didSet {
            guard idleGapMinutes != oldValue else { return }
            UserDefaults.standard.set(idleGapMinutes, forKey: "idleGapMinutes")
            reload()
        }
    }
    static let idleGapChoices = [5, 10, 15, 30]
    /// Starts the timer for a project when one of its sessions sets to work, and stops it
    /// when the project has been quiet for the idle gap. Off unless asked for.
    @Published var startsTimerAutomatically: Bool {
        didSet { UserDefaults.standard.set(startsTimerAutomatically, forKey: "startsTimerAutomatically") }
    }
    /// The project the timer was last started for without being asked. A timer started by
    /// hand for another project is left alone.
    private var followedProject: String?
    private var lastWork: Date?
    /// Where sessions open, unless their project says otherwise.
    @Published var openMethod: OpenMethod {
        didSet { UserDefaults.standard.set(openMethod.rawValue, forKey: "openMethod") }
    }
    /// Where each session was last seen running, which is where the automatic way reopens it.
    @Published private(set) var sessionHosts: [String: OpenMethod] = [:]
    /// The same for projects: where their most recently seen session ran.
    @Published private(set) var projectHosts: [String: OpenMethod] = [:]
    /// Resumes in a new tab of iTerm's front window instead of a new window.
    @Published var opensInTabs: Bool {
        didSet { UserDefaults.standard.set(opensInTabs, forKey: "opensInTabs") }
    }
    /// Keeps the panel on screen when something else is clicked, for a panel parked on a
    /// second display. It then closes only by its shortcut or Escape.
    @Published var staysOpen: Bool {
        didSet { UserDefaults.standard.set(staysOpen, forKey: "staysOpen") }
    }
    /// The projects that open their sessions their own way.
    @Published private(set) var projectOpenMethods: [String: OpenMethod] = [:]
    /// The ways of opening a session that this Mac has the app for.
    let openMethods: [OpenMethod] = OpenMethod.allCases.filter { method in
        method.bundleID.map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? true
    }
    @Published var showingAll: Set<String> = []
    @Published var addingTaskFor: String?
    @Published var renamingProject: String?
    @Published var focusRequest = 0
    /// Empty when the global shortcut could not be registered (another app owns it).
    @Published var shortcutLabels: [ShortcutKind: String] = [:]
    private var hotKeys: [ShortcutKind: HotKey] = [:]
    /// The label of the shortcut that opens the panel, shown in the footer.
    var shortcutLabel: String {
        get { shortcutLabels[.panel] ?? "" }
        set { shortcutLabels[.panel] = newValue }
    }

    func register(_ hotKey: HotKey) {
        hotKeys[hotKey.kind] = hotKey
        shortcutLabels[hotKey.kind] = hotKey.isRegistered ? hotKey.shortcut.label : ""
    }
    @Published private(set) var launchesAtLogin = LoginItem.isEnabled

    var searchFocused = true
    var onOpen: ((SessionRecord, OpenMethod) -> Void)?
    var onOpenInDesktop: ((SessionRecord) -> Void)?
    /// Called to show the welcome screen again.
    var onShowWelcome: (() -> Void)?
    /// Called with a folder and a first prompt to start a new session.
    var onStartSession: ((String, String, OpenMethod) -> Void)?
    /// Called when a session starts waiting or finishes its work.
    var onAttention: ((String, SessionRecord?, LiveSession) -> Void)?
    /// How long a session must have worked before its finishing is worth announcing.
    var finishThreshold: TimeInterval = 8
    private var workingSince: [String: Date] = [:]
    private var hasSeenLive = false
    private var monitor: Timer?
    private var heartbeat: Timer?

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
        checksForUpdates = UserDefaults.standard.bool(forKey: "checksForUpdates")
        appearanceChoice = UserDefaults.standard.string(forKey: "appearance") ?? ""
        languageChoice = UserDefaults.standard.string(forKey: "language") ?? ""
        timePeriod = TimePeriod(rawValue: UserDefaults.standard.integer(forKey: "timePeriod")) ?? .today
        showsTime = UserDefaults.standard.object(forKey: "showsTime") as? Bool ?? true
        tracksTimeAutomatically = UserDefaults.standard.object(forKey: "tracksTimeAutomatically") as? Bool ?? true
        startsTimerAutomatically = UserDefaults.standard.bool(forKey: "startsTimerAutomatically")
        let gap = UserDefaults.standard.integer(forKey: "idleGapMinutes")
        idleGapMinutes = Self.idleGapChoices.contains(gap) ? gap : 15
        openMethod = UserDefaults.standard.string(forKey: "openMethod").flatMap(OpenMethod.init) ?? .automatic
        opensInTabs = UserDefaults.standard.object(forKey: "opensInTabs") as? Bool ?? true
        staysOpen = UserDefaults.standard.bool(forKey: "staysOpen")
        showsOrganizations = UserDefaults.standard.bool(forKey: "showsOrganizations")
        panelEdge = UserDefaults.standard.string(forKey: "panelEdge").flatMap(PanelEdge.init) ?? .right
        showsTodos = UserDefaults.standard.object(forKey: "showsTodos") as? Bool ?? true
        showsWeek = UserDefaults.standard.object(forKey: "showsWeek") as? Bool ?? true
        collapsedSections = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])
        notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        organizationFilter = showsOrganizations ? UserDefaults.standard.string(forKey: "organizationFilter") : nil
        projectSort = ProjectSort(rawValue: UserDefaults.standard.integer(forKey: "projectSort")) ?? .activity
        hidesSingleSessionProjects = UserDefaults.standard.bool(forKey: "hidesSingleSessionProjects")
        hidesInactiveProjects = UserDefaults.standard.bool(forKey: "hidesInactiveProjects")
        hiddenProjects = Set(UserDefaults.standard.stringArray(forKey: "hiddenProjects") ?? [])
    }

    // MARK: - Loading

    private struct Snapshot {
        var sessions: [String: SessionRecord] = [:]
        var pinned: [PinnedSession] = []
        var recent: [SessionRecord] = []
        var projects: [ProjectGroup] = []
        var allProjects: [ProjectGroup] = []
        var hidden: Set<String> = []
        var desktop = DesktopSessions.Index()
        var live: [String: LiveSession] = [:]
        var tags: [Tag] = []
        var tasks: [TaskItem] = []
        var notes: [NoteItem] = []
        var organizations: [Organization] = []
        var tagged: [SessionRecord]?
        var week: [DaySummary] = []
        var timeReports: [TimePeriod: TimeReport] = [:]
        var runningTimer: RunningTimer?
        var lastTimeEntries: [String: TimeEntry] = [:]
        var openMethods: [String: OpenMethod] = [:]
        var sessionHosts: [String: OpenMethod] = [:]
        var projectHosts: [String: OpenMethod] = [:]
    }

    /// How the project list is thinned and ordered, and how time is counted. Read on the main
    /// thread before loading.
    private struct ProjectArrangement {
        var sort = ProjectSort.activity
        var hideSingle = false
        var hideInactive = false
        var hidden: Set<String> = []
        var automaticTime = true
        var idleGap: TimeInterval = 900
    }

    private var projectArrangement: ProjectArrangement {
        ProjectArrangement(
            sort: projectSort, hideSingle: hidesSingleSessionProjects,
            hideInactive: hidesInactiveProjects, hidden: hiddenProjects,
            automaticTime: tracksTimeAutomatically, idleGap: TimeInterval(idleGapMinutes * 60)
        )
    }

    func reload() {
        let organization = organizationFilter, tag = tagFilter, named = showsOrganizations
        let arrangement = projectArrangement
        readQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.buildSnapshot(
                organization: organization, tag: tag, namesOrganizations: named, projects: arrangement
            )
            DispatchQueue.main.async {
                // A filter changed while this was loading; a newer reload is already on its way.
                guard organization == self.organizationFilter, tag == self.tagFilter else { return }
                self.apply(snapshot)
            }
        }
    }

    func reloadSync() {
        apply(buildSnapshot(
            organization: organizationFilter, tag: tagFilter,
            namesOrganizations: showsOrganizations, projects: projectArrangement
        ))
    }

    private func apply(_ snapshot: Snapshot) {
        allSessions = snapshot.sessions
        desktop = snapshot.desktop
        ingestLive(snapshot.live)
        tags = snapshot.tags
        tasks = snapshot.tasks
        notes = snapshot.notes
        week = snapshot.week
        timeReports = snapshot.timeReports
        runningTimer = snapshot.runningTimer
        lastTimeEntries = snapshot.lastTimeEntries
        projectOpenMethods = snapshot.openMethods
        sessionHosts = snapshot.sessionHosts
        projectHosts = snapshot.projectHosts
        organizations = snapshot.organizations
        tagged = snapshot.tagged
        if let tagFilter, !snapshot.tags.contains(where: { $0.id == tagFilter }) { self.tagFilter = nil }
        if let organizationFilter, !snapshot.organizations.contains(where: { $0.id == organizationFilter }) {
            self.organizationFilter = nil
        }
        pinned = snapshot.pinned
        recent = snapshot.recent
        allProjects = snapshot.allProjects
        projects = snapshot.projects
        if hiddenProjects != snapshot.hidden { hiddenProjects = snapshot.hidden }
        sessionCount = snapshot.sessions.count
        hasLoaded = true
        countBackups()
        if results != nil { scheduleSearch(immediately: true) }
    }

    /// Leaves out what the user asked not to see and puts the rest in the chosen order.
    private static func arrange(
        _ projects: [ProjectGroup], by arrangement: ProjectArrangement, hidden: Set<String>
    ) -> [ProjectGroup] {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        return projects
            .filter { project in
                if hidden.contains(project.key) { return false }
                if arrangement.hideSingle && project.sessions.count < 2 { return false }
                if arrangement.hideInactive && (project.lastActivity ?? .distantPast) < cutoff { return false }
                return true
            }
            .sorted(by: arrangement.sort.areInOrder)
    }

    /// Which sessions were used on each day of the week that holds `now`, from Monday up to
    /// that day. The timestamps of the prompts are all this needs; sessions of hidden projects
    /// are left out, as they are everywhere else in the list.
    private func week(of snapshot: Snapshot, until now: Date) -> [DaySummary] {
        let calendar = Self.calendar
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var promptsPerDay: [String: [String: Int]] = [:]
        try? readDB.query("SELECT session_id, ts FROM messages WHERE role = 'u' AND ts >= ?", [monday.timeIntervalSince1970]) {
            row in
            guard let id = row.text(0), let stamp = row.double(1) else { return }
            let key = Format.dayKey(Date(timeIntervalSince1970: stamp), in: calendar)
            promptsPerDay[key, default: [:]][id, default: 0] += 1
        }
        let today = Format.dayKey(now, in: calendar)
        var days: [DaySummary] = []
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: monday) else { break }
            let key = Format.dayKey(date, in: calendar)
            if key > today { break }
            let work = (promptsPerDay[key] ?? [:]).compactMap { id, prompts -> DayWork? in
                guard let session = snapshot.sessions[id], !snapshot.hidden.contains(session.projectKey) else { return nil }
                return DayWork(session: session, prompts: prompts)
            }
            .sorted { $0.prompts == $1.prompts ? $0.id < $1.id : $0.prompts > $1.prompts }
            if !work.isEmpty { days.append(DaySummary(day: key, work: work)) }
        }
        return days.reversed()
    }

    private func buildSnapshot(
        organization organizationFilter: String?, tag tagFilter: Int64?, namesOrganizations: Bool,
        projects arrangement: ProjectArrangement
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
                   first_ts, branch, file_size, tok_input, tok_cached, tok_output, context_tokens, model, entrypoint
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
            record.entrypoint = row.text(19)
            let identity = identities[cwd] ?? {
                let fallback = ProjectResolver.fallback(cwd.isEmpty ? L10n.otherProject : cwd, durable: false)
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
        try? readDB.query("SELECT id, text, created FROM notes ORDER BY id DESC") { row in
            if let text = row.text(1) {
                snapshot.notes.append(NoteItem(id: Int64(row.int(0)), text: text, created: row.date(2)))
            }
        }
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
            let fallback = signedIn?.id == id ? signedIn!.name : L10n.accountNumber(position + 1)
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
        snapshot.allProjects = grouped.map { key, sessions in
            ProjectGroup(
                key: key,
                name: sessions[0].projectName,
                sessions: sessions,
                folders: Array(Set(sessions.map(\.cwd).filter { !$0.isEmpty })).sorted(),
                mergedKeys: (mergedInto[key] ?? []).sorted()
            )
        }
        .sorted(by: ProjectSort.activity.areInOrder)
        // The key of a project that was merged into another no longer hides anything.
        snapshot.hidden = arrangement.hidden.intersection(Set(snapshot.allProjects.map(\.key)))

        var tasksBySession: [String: [TaskItem]] = [:]
        let cutoff = Date().addingTimeInterval(-86_400).timeIntervalSince1970
        try? readDB.query(
            """
            SELECT id, session_id, text, done, done_at, due, project_key, position, created
            FROM tasks WHERE done = 0 OR done_at > ? ORDER BY done, COALESCE(position, created), id
            """,
            [cutoff]
        ) { row in
            guard let sessionID = row.text(1), let text = row.text(2) else { return }
            let task = TaskItem(
                id: Int64(row.int(0)), sessionID: sessionID, text: text, done: row.int(3) == 1,
                doneAt: row.date(4), due: row.text(5), projectKey: row.text(6),
                created: row.date(8) ?? .distantPast, position: row.double(7)
            )
            snapshot.tasks.append(task)
            if !sessionID.isEmpty { tasksBySession[sessionID, default: []].append(task) }
        }
        var pinnedIDs: [String] = []
        try? readDB.query("SELECT session_id FROM pins ORDER BY position") { row in
            if let id = row.text(0) { pinnedIDs.append(id) }
        }
        snapshot.pinned = pinnedIDs.compactMap { id in
            snapshot.sessions[id].map { PinnedSession(session: $0, tasks: tasksBySession[id] ?? []) }
        }
        let pinnedSet = Set(pinnedIDs)
        snapshot.recent = Array(ordered.lazy.filter {
            !pinnedSet.contains($0.id) && !snapshot.hidden.contains($0.projectKey)
        }.prefix(Self.recentCount))
        snapshot.projects = Self.arrange(snapshot.allProjects, by: arrangement, hidden: snapshot.hidden)
        snapshot.week = week(of: snapshot, until: Date())
        try? readDB.query("SELECT key, method FROM project_open") { row in
            if let key = row.text(0), let method = row.text(1).flatMap(OpenMethod.init) {
                snapshot.openMethods[finalKey(key)] = method
            }
        }
        // Oldest first, so that a project ends up with the host of its most recently seen session.
        try? readDB.query("SELECT session_id, method FROM session_hosts ORDER BY seen") { row in
            guard let id = row.text(0), let method = row.text(1).flatMap(OpenMethod.init) else { return }
            snapshot.sessionHosts[id] = method
            if let key = snapshot.sessions[id]?.projectKey { snapshot.projectHosts[key] = method }
        }
        let names = Dictionary(uniqueKeysWithValues: snapshot.allProjects.map { ($0.key, $0.name) })
        addTime(to: &snapshot, arrangement: arrangement, resolve: finalKey) { key in
            names[key] ?? customNames[key] ?? defaultNames[key] ?? key
        }
        return snapshot
    }

    /// Adds up how long each project was worked on today, this week and this month: what the
    /// timer measured, and what the moments of prompts and answers suggest.
    private func addTime(
        to snapshot: inout Snapshot, arrangement: ProjectArrangement,
        resolve: (String) -> String, name: (String) -> String, now: Date = Date()
    ) {
        let calendar = Self.calendar
        let nowStamp = now.timeIntervalSince1970
        let dayStart = calendar.startOfDay(for: now)
        let starts: [TimePeriod: Double] = [
            .today: dayStart.timeIntervalSince1970,
            .week: (calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart).timeIntervalSince1970,
            .month: (calendar.dateInterval(of: .month, for: now)?.start ?? dayStart).timeIntervalSince1970,
        ]
        let earliest = starts.values.min() ?? nowStamp

        var manual: [String: [TimeSpan]] = [:]
        try? readDB.query(
            "SELECT id, project_key, started, ended, open FROM time_entries WHERE ended >= ? OR open = 1 ORDER BY id",
            [earliest]
        ) { row in
            guard let raw = row.text(1), let started = row.double(2), let ended = row.double(3) else { return }
            let key = resolve(raw), id = Int64(row.int(0))
            if row.int(4) == 1 {
                snapshot.runningTimer = RunningTimer(
                    id: id, projectKey: key, projectName: name(key), started: Date(timeIntervalSince1970: started)
                )
                manual[key, default: []].append(TimeSpan(start: started, end: nowStamp))
            } else {
                snapshot.lastTimeEntries[key] = TimeEntry(id: id, length: ended - started)
                manual[key, default: []].append(TimeSpan(start: started, end: ended))
            }
        }

        var automatic: [String: [TimeSpan]] = [:]
        if arrangement.automaticTime {
            var stamps: [String: [Double]] = [:]
            try? readDB.query("SELECT session_id, ts FROM messages WHERE ts >= ?", [earliest]) { row in
                guard let id = row.text(0), let stamp = row.double(1), stamp <= nowStamp,
                      let key = snapshot.sessions[id]?.projectKey else { return }
                stamps[key, default: []].append(stamp)
            }
            for (key, list) in stamps {
                automatic[key] = TimeMath.blocks(list.sorted(), gap: arrangement.idleGap)
            }
        }

        let keys = Set(manual.keys).union(automatic.keys).subtracting(snapshot.hidden)
        // A project keeps one color in every period: the busiest take the chart's colors in turn.
        var lengths: [(key: String, length: TimeInterval)] = []
        for key in keys {
            let spans: [TimeSpan] = (manual[key] ?? []) + (automatic[key] ?? [])
            lengths.append((key, TimeMath.length(TimeMath.merged(spans))))
        }
        lengths.sort { $0.length == $1.length ? $0.key < $1.key : $0.length > $1.length }
        var colors: [String: Int] = [:]
        for (index, entry) in lengths.prefix(TimePalette.count).enumerated() { colors[entry.key] = index }

        for period in TimePeriod.allCases {
            let from = starts[period] ?? nowStamp
            var report = TimeReport(start: from, end: nowStamp)
            var everything: [TimeSpan] = []
            var spansByKey: [String: [TimeSpan]] = [:]
            for key in keys {
                let timed = TimeMath.clipped(TimeMath.merged(manual[key] ?? []), from: from, to: nowStamp)
                let guessed = TimeMath.clipped(automatic[key] ?? [], from: from, to: nowStamp)
                let both = TimeMath.merged(timed + guessed)
                let total = TimeMath.length(both)
                // Under a minute is not worth a row, unless its timer is running right now.
                guard total >= 60 || snapshot.runningTimer?.projectKey == key else { continue }
                var row = ProjectTime(
                    key: key, name: name(key), manual: TimeMath.length(timed),
                    automatic: TimeMath.length(guessed), total: total, color: colors[key]
                )
                if period == .today {
                    row.timed = timed
                    row.guessed = guessed
                }
                report.rows.append(row)
                spansByKey[key] = both
                everything += both
            }
            report.rows.sort { $0.total == $1.total ? $0.key < $1.key : $0.total > $1.total }
            report.total = TimeMath.length(TimeMath.merged(everything))
            if period != .today, let whole = calendar.dateInterval(of: period == .week ? .weekOfYear : .month, for: now) {
                var day = whole.start
                while day < whole.end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
                    var entry = DayTime(day: Format.dayKey(day, in: calendar), date: day)
                    let head = day.timeIntervalSince1970, tail = next.timeIntervalSince1970
                    if head <= nowStamp {
                        for (key, spans) in spansByKey {
                            let length = TimeMath.length(TimeMath.clipped(spans, from: head, to: tail))
                            if length > 0 { entry.parts[key] = length }
                        }
                    }
                    report.days.append(entry)
                    day = next
                }
            }
            snapshot.timeReports[period] = report
        }
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
            SELECT session_id, snippet(messages, 0, char(2), char(3), '…', 14), rowid
            FROM messages WHERE messages MATCH ? ORDER BY rank LIMIT 400
            """,
            [match]
        ) { row in
            guard let id = row.text(0), let raw = row.text(1), let session = sessions[id] else { return }
            if let position = positions[id] {
                if hits[position].snippet == nil {
                    hits[position].snippet = Self.parseSnippet(raw)
                    hits[position].matchRow = row.int(2)
                }
            } else if hits.count < 60 {
                positions[id] = hits.count
                hits.append(SearchHit(session: session, snippet: Self.parseSnippet(raw), matchRow: row.int(2)))
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
        var keys: [String] = []
        if !isCollapsed(PanelSection.waiting) { keys += needsYou.map { RowKey.waiting($0.id) } }
        if !isCollapsed(PanelSection.pinned) { keys += pinned.map { RowKey.pin($0.id) } }
        if !isCollapsed(PanelSection.recent) { keys += recent.map { RowKey.recent($0.id) } }
        if showsWeek, !isCollapsed(PanelSection.week) {
            for day in week where isDayExpanded(day.day) { keys += day.work.map { RowKey.day(day.day, $0.id) } }
        }
        if !isCollapsed(PanelSection.projects) {
            for project in projects where expanded.contains(project.key) {
                keys += visibleSessions(in: project).map { RowKey.project($0.id) }
            }
        }
        return keys
    }

    func moveSelection(_ delta: Int) {
        guard !showingSettings, outline == nil else { return }
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
        guard !showingSettings, outline == nil, let selection, let session = allSessions[RowKey.sessionID(selection)] else { return false }
        open(session)
        return true
    }

    /// Opens a session the way its project asks for, or the given way just this once.
    func open(_ session: SessionRecord, with method: OpenMethod? = nil) {
        hover = nil
        attention.remove(session.id)
        onOpen?(session, method ?? openMethod(for: session))
    }

    /// The way a project's sessions open: its own choice, or the one from Settings.
    func openMethod(forProject key: String) -> OpenMethod {
        let method = projectOpenMethods[key] ?? openMethod
        return openMethods.contains(method) ? method : .automatic
    }

    /// The way one session opens. Left to itself, a session goes back to where it was last seen
    /// running; one never seen goes where its kind lives, then where its project's sessions run.
    func openMethod(for session: SessionRecord) -> OpenMethod {
        let chosen = openMethod(forProject: session.projectKey)
        guard chosen == .automatic else { return chosen }
        if let host = sessionHosts[session.id], openMethods.contains(host) { return host }
        if desktop.records[session.id] != nil { return .automatic }
        if session.entrypoint == "claude-vscode", openMethods.contains(.vscode) { return .vscode }
        if let host = projectHosts[session.projectKey], host != .desktop, openMethods.contains(host) { return host }
        return .automatic
    }

    /// The way a new session starts in a project: where the project's sessions have been running.
    func startMethod(forProject key: String) -> OpenMethod {
        let chosen = openMethod(forProject: key)
        guard chosen == .automatic else { return chosen }
        if let host = projectHosts[key], host != .desktop, openMethods.contains(host) { return host }
        return .automatic
    }

    /// Records where a session ran, as a reading of the running sessions would.
    func remember(host: OpenMethod, for session: SessionRecord) {
        sessionHosts[session.id] = host
        projectHosts[session.projectKey] = host
    }

    /// Gives a project its own way of opening, or takes it back with nil.
    func setOpenMethod(_ method: OpenMethod?, for project: ProjectGroup) {
        let keys = [project.key] + project.mergedKeys
        write { db in
            for key in keys { try db.run("DELETE FROM project_open WHERE key = ?", [key]) }
            if let method {
                try db.run("INSERT INTO project_open(key, method) VALUES(?, ?)", [project.key, method.rawValue])
            }
        }
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
        if showingReleaseNotes {
            // The notes are opened from Settings, and go back there.
            showingReleaseNotes = false
            return false
        }
        if showingSettings || outline != nil {
            showingSettings = false
            outline = nil
            focusRequest += 1
            return false
        }
        if addingTaskFor != nil {
            addingTaskFor = nil
            focusRequest += 1
            return false
        }
        if taskLink != nil {
            // Leaving the task field without adding a task gives up the link.
            taskLink = nil
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
        checkForUpdatesIfDue()
        selection = nil
        hover = nil
        selectedDay = Format.dayKey(Date())
        calendarAnchor = Date()
        taskLink = nil
        // Opening the panel counts as seeing what finished; sessions still waiting stay marked.
        attention = attention.filter { live[$0]?.state == .waiting }
        addingTaskFor = nil
        renamingProject = nil
        tagEditor = nil
        showingSettings = false
        outline = nil
        cancelShortcutRecording()
        focusRequest += 1
        refresh()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        if !LoginItem.set(enabled) { show(notice: L10n.loginItemFailed) }
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
                    "INSERT OR REPLACE INTO pins(session_id, position) VALUES(?, (SELECT COALESCE(MAX(position), 0) + 1 FROM pins))",
                    [session.id]
                )
            }
        }
    }

    /// Moves a pinned session beside another one, below it when `after` is true. The pins are
    /// numbered again in their new order, so the next one pinned still goes to the end.
    func movePin(_ id: String, in order: [String], nextTo target: String, after: Bool) {
        guard id != target, let from = order.firstIndex(of: id) else { return }
        var order = order
        order.remove(at: from)
        guard let index = order.firstIndex(of: target) else { return }
        order.insert(id, at: index + (after ? 1 : 0))
        write { db in
            for (offset, sessionID) in order.enumerated() {
                try db.run("UPDATE pins SET position = ? WHERE session_id = ?", [Double(offset + 1), sessionID])
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

    /// Moves an open task beside another one in the list it is shown in, below it when `after`
    /// is true. The task is given a place between its new neighbours, so the rest keep theirs.
    func moveTask(_ id: Int64, in list: [TaskItem], nextTo target: Int64, after: Bool) {
        let open = list.filter { !$0.done }
        guard let from = open.firstIndex(where: { $0.id == id }), let to = open.firstIndex(where: { $0.id == target }),
              id != target else { return }
        var order = open
        let moved = order.remove(at: from)
        order.insert(moved, at: to + (after ? 1 : 0) - (from < to ? 1 : 0))
        let at = order.firstIndex { $0.id == id }!
        let previous = at > 0 ? order[at - 1] : nil
        let next = at + 1 < order.count ? order[at + 1] : nil

        var rank = moved.rank
        if let previous, let next {
            let low = previous.rank, high = next.rank
            rank = (low + high) / 2
            // Half-way is not between them when they are as close as numbers can be.
            if !(rank > low && rank < high) { rank = .nan }
        } else if let previous {
            rank = previous.rank + 1
        } else if let next {
            rank = next.rank - 1
        }
        write { db in
            if rank.isNaN || rank.isInfinite {
                // No room between the neighbours: the list is numbered afresh in its new order.
                for (offset, task) in order.enumerated() {
                    try db.run("UPDATE tasks SET position = ? WHERE id = ?", [Double(offset + 1), task.id])
                }
            } else {
                try db.run("UPDATE tasks SET position = ? WHERE id = ?", [rank, id])
            }
        }
    }

    // MARK: - Sections

    func isCollapsed(_ section: String) -> Bool {
        collapsedSections.contains(section)
    }

    func toggleSection(_ section: String) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }

    // MARK: - Outline

    /// Opens the list of everything the user asked in a session.
    /// With `row`, the outline opens on the prompt that message belongs to.
    func showOutline(for session: SessionRecord, near row: Int? = nil) {
        hover = nil
        readQueue.async { [weak self] in
            guard let self else { return }
            let outline = self.loadOutline(for: session, near: row)
            DispatchQueue.main.async { self.outline = outline }
        }
    }

    func showOutlineSync(for session: SessionRecord, near row: Int? = nil) {
        outline = loadOutline(for: session, near: row)
    }

    /// The outline of the selected session, opened on the match when it is a search result.
    func showOutlineOfSelection() -> Bool {
        guard let selection, let session = allSessions[RowKey.sessionID(selection)] else { return false }
        showOutline(for: session, near: results?.first { $0.id == session.id }?.matchRow)
        return true
    }

    /// Opens the pinned session at a position, counted from one.
    func openPinned(at position: Int) -> Bool {
        guard results == nil, pinned.indices.contains(position - 1) else { return false }
        open(pinned[position - 1].session)
        return true
    }

    func togglePinOfSelection() -> Bool {
        guard let selection, let session = allSessions[RowKey.sessionID(selection)] else { return false }
        togglePin(session)
        return true
    }

    func closeOutline() {
        outline = nil
        focusRequest += 1
    }

    private func loadOutline(for session: SessionRecord, near row: Int? = nil) -> SessionOutline {
        var entries: [OutlineEntry] = []
        try? readDB.query(
            "SELECT rowid, text, ts FROM messages WHERE session_id = ? AND role = 'u' ORDER BY rowid",
            [session.id]
        ) { row in
            guard let text = row.text(1) else { return }
            entries.append(OutlineEntry(id: row.int(0), text: Self.outlineText(text), date: row.date(2)))
        }
        // A match in an answer belongs to the prompt before it.
        let focus = row.flatMap { row in entries.last { $0.id <= row }?.id ?? entries.first?.id }
        return SessionOutline(session: session, entries: entries, focus: focus)
    }

    private static let pastedBlock = try! NSRegularExpression(
        pattern: "<pasted_content[^>]*>.*?(</pasted_content[^>]*>|$)", options: [.dotMatchesLineSeparators]
    )

    /// A prompt as shown in the outline: pasted material is named rather than printed, and
    /// the text is kept to a readable length.
    private static func outlineText(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = pastedBlock.stringByReplacingMatches(
            in: text, range: range, withTemplate: L10n.pastedContent
        )
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
    }

    // MARK: - Attention

    /// Keeps watching running sessions while the panel is closed.
    func startMonitoring() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshLive()
        }
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.recordHeartbeat()
        }
        checkForUpdatesIfDue()
    }

    /// Takes a fresh reading of the running sessions and works out which ones now need the user:
    /// a session that started waiting, or one that worked for a while and then stopped.
    func ingestLive(_ current: [String: LiveSession], now: Date = Date()) {
        defer { if live != current { live = current } }
        rememberHosts(of: current, now: now)
        followWork(in: current, now: now)
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

    /// Moves the timer to where the work is, when that was asked for in Settings.
    private func followWork(in current: [String: LiveSession], now: Date) {
        guard startsTimerAutomatically else { return }
        func project(_ id: String) -> String? {
            allSessions[id].map(\.projectKey).flatMap { hiddenProjects.contains($0) ? nil : $0 }
        }
        let working = Set(current.filter { $0.value.state == .working }.keys.compactMap(project))
        // The projects where a session has just set to work.
        let started = current
            .filter { $0.value.state == .working && live[$0.key]?.state != .working }
            .keys.sorted().compactMap(project)
        guard let timer = runningTimer else {
            if let key = started.first { follow(key, now: now) }
            return
        }
        if working.contains(timer.projectKey) { lastWork = now }
        guard followedProject == timer.projectKey else { return }
        if !working.contains(timer.projectKey), let key = started.first(where: { $0 != timer.projectKey }) {
            follow(key, now: now)
        } else if let lastWork, now.timeIntervalSince(lastWork) > TimeInterval(idleGapMinutes * 60) {
            // The time since the work stopped was not work, so the stretch ends where it did.
            followedProject = nil
            stopTimer(at: lastWork)
        }
    }

    private func follow(_ key: String, now: Date) {
        followedProject = key
        lastWork = now
        startTimer(forProject: key)
    }

    /// Notes which app each running session is in, so it can be reopened there later.
    private func rememberHosts(of current: [String: LiveSession], now: Date) {
        var news: [(String, OpenMethod)] = []
        for (id, session) in current {
            let host = session.desktopID != nil ? OpenMethod.desktop : OpenMethod(hostBundleID: session.hostBundleID)
            if let host, sessionHosts[id] != host { news.append((id, host)) }
        }
        guard !news.isEmpty else { return }
        for (id, host) in news {
            sessionHosts[id] = host
            if let key = allSessions[id]?.projectKey { projectHosts[key] = host }
        }
        let stamp = now.timeIntervalSince1970
        userQueue.async { [weak self] in
            for (id, host) in news {
                _ = try? self?.userDB.run(
                    "INSERT OR REPLACE INTO session_hosts(session_id, method, seen) VALUES(?, ?, ?)", [id, host.rawValue, stamp]
                )
            }
        }
    }

    /// The sessions that want the user now: waiting for an answer, or finished since last looked at.
    var needsYou: [SessionRecord] {
        let ids = Set(live.filter { $0.value.state == .waiting }.keys).union(attention)
        return ids.compactMap { allSessions[$0] }
            .filter { !hiddenProjects.contains($0.projectKey) }
            .sorted { ($0.lastActivity ?? .distantPast, $0.id) > ($1.lastActivity ?? .distantPast, $1.id) }
    }

    private func announce(_ id: String, _ session: LiveSession) {
        guard notificationsEnabled else { return }
        onAttention?(id, allSessions[id], session)
    }

    func session(withID id: String) -> SessionRecord? {
        allSessions[id]
    }

    // MARK: - Tasks and calendar

    var today: String {
        Format.dayKey(Date())
    }

    func tasks(on day: String) -> [TaskItem] {
        tasks.filter { $0.due == day }
    }

    /// Open tasks whose day has passed, the longest overdue first. They are listed with today's.
    var overdueTasks: [TaskItem] {
        let today = today
        return tasks
            .filter { !$0.done && ($0.due.map { $0 < today } ?? false) }
            .sorted { ($0.due ?? "", $0.id) < ($1.due ?? "", $1.id) }
    }

    /// Tasks with no date. Those that belong to a pinned session are left out, because they
    /// already show under that session.
    var undatedTasks: [TaskItem] {
        let pinnedIDs = Set(pinned.map(\.id))
        return tasks.filter { $0.due == nil && !pinnedIDs.contains($0.sessionID) }
    }

    /// How many open tasks the to-do section lists, for its title when it is collapsed.
    var openListedTaskCount: Int {
        let pinnedIDs = Set(pinned.map(\.id))
        return tasks.filter { !$0.done && ($0.due != nil || !pinnedIDs.contains($0.sessionID)) }.count
    }

    func openTaskCount(on day: String) -> Int {
        tasks.reduce(0) { $0 + (!$1.done && $1.due == day ? 1 : 0) }
    }

    /// A day as "Bugün", "Yarın" or "Per 26 Kas".
    func dayLabel(_ key: String) -> String {
        let calendar = Self.calendar
        if key == today { return L10n.today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()), key == Format.dayKey(tomorrow) {
            return L10n.tomorrow
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()), key == Format.dayKey(yesterday) {
            return L10n.yesterday
        }
        return Format.date(fromDayKey: key).map(Format.shortDay) ?? key
    }

    /// Adds a task for the selected day, attached to whatever `taskLink` names.
    func addTodo(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let day = selectedDay
        var sessionID = ""
        var projectKey: String?
        switch taskLink {
        case .session(let id, _): sessionID = id
        case .project(let key, _): projectKey = key
        case nil: break
        }
        taskLink = nil
        write { db in
            try db.run(
                "INSERT INTO tasks(session_id, text, done, created, due, project_key) VALUES(?, ?, 0, ?, ?, ?)",
                [sessionID, trimmed, Date().timeIntervalSince1970, day, projectKey]
            )
        }
    }

    func setDue(_ task: TaskItem, to day: String?) {
        write { db in try db.run("UPDATE tasks SET due = ? WHERE id = ?", [day, task.id]) }
    }

    func link(_ task: TaskItem, toProject key: String?) {
        write { db in
            try db.run("UPDATE tasks SET project_key = ?, session_id = '' WHERE id = ?", [key, task.id])
        }
    }

    /// Starts typing a task that will be attached to a session or project. Search results and a
    /// tag view give way to the task list, since that is where the field is.
    func beginTask(linkedTo link: TaskLink) {
        taskLink = link
        query = ""
        tagFilter = nil
        showsTodos = true
        collapsedSections.remove(PanelSection.todos)
        todoFocusRequest += 1
    }

    /// The session or project a task is attached to, if it can still be found. A project counts
    /// even when the panel's filters keep it out of the list.
    func linkTitle(for task: TaskItem) -> (symbol: String, title: String)? {
        if !task.sessionID.isEmpty, let session = allSessions[task.sessionID] {
            return ("bubble.left", session.title)
        }
        if let key = task.projectKey, let project = allProjects.first(where: { $0.key == key }) {
            return ("folder", project.name)
        }
        return nil
    }

    /// Takes a linked task to Claude: opens its session with the task on the clipboard, or
    /// starts a new session in its project with the task as the first prompt.
    func run(_ task: TaskItem) {
        if !task.sessionID.isEmpty, let session = allSessions[task.sessionID] {
            Opener.copy(task.text)
            show(notice: L10n.taskCopied)
            open(session)
        } else if let key = task.projectKey, let project = allProjects.first(where: { $0.key == key }) {
            guard let folder = existingFolder(of: project) else {
                show(notice: L10n.projectFolderMissing)
                return
            }
            startSession(in: folder, prompt: task.text, projectKey: project.key)
        }
    }

    /// Starts a new session in a project's folder, with nothing typed yet.
    func startSession(in project: ProjectGroup) {
        guard let folder = existingFolder(of: project) else {
            show(notice: L10n.projectFolderMissing)
            return
        }
        startSession(in: folder, prompt: "", projectKey: project.key)
    }

    private func startSession(in folder: String, prompt: String, projectKey: String) {
        onStartSession?(folder, prompt, startMethod(forProject: projectKey))
    }

    /// A folder of the project that is still on this Mac.
    private func existingFolder(of project: ProjectGroup) -> String? {
        project.folders.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Calendar

    /// Today is open unless it was closed by hand; the other days of the week are closed
    /// unless opened.
    func isDayExpanded(_ day: String) -> Bool {
        dayFold[day] ?? (day == today)
    }

    func toggleDay(_ day: String) {
        dayFold[day] = !isDayExpanded(day)
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: L10n.localeIdentifier)
        calendar.firstWeekday = 2
        return calendar
    }()

    /// The days the calendar shows: the anchor's week, or every week touching its month.
    var calendarDays: [Date] {
        let calendar = Self.calendar
        func weekStart(_ date: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
        guard calendarExpanded, let month = calendar.dateInterval(of: .month, for: calendarAnchor) else {
            let start = weekStart(calendarAnchor)
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
        let start = weekStart(month.start)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.start
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart(lastDay)) ?? month.end
        let count = calendar.dateComponents([.day], from: start, to: end).day ?? 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Moves the calendar a week or a month. The selected day moves by the same amount, so the
    /// list under the calendar keeps describing a day that is on screen.
    func shiftCalendar(by step: Int) {
        let unit: Calendar.Component = calendarExpanded ? .month : .weekOfYear
        calendarAnchor = Self.calendar.date(byAdding: unit, value: step, to: calendarAnchor) ?? calendarAnchor
        if let day = Format.date(fromDayKey: selectedDay),
           let moved = Self.calendar.date(byAdding: unit, value: step, to: day) {
            selectedDay = Format.dayKey(moved)
        }
    }

    func showToday() {
        calendarAnchor = Date()
        selectedDay = today
    }

    // MARK: - Activity

    static let activityBuckets = 30

    private func loadActivity() {
        guard let subject = hover?.subject else {
            hoverActivity = nil
            return
        }
        if hoverActivity?.key != subject.key { hoverActivity = nil }
        let gap = TimeInterval(idleGapMinutes * 60)
        readQueue.async { [weak self] in
            guard let self else { return }
            let series = self.activity(for: subject, idleGap: gap)
            DispatchQueue.main.async {
                guard self.hover?.subject.key == subject.key else { return }
                self.hoverActivity = series
            }
        }
    }

    func loadActivitySync() {
        hoverActivity = hover.map { activity(for: $0.subject, idleGap: TimeInterval(idleGapMinutes * 60)) }
    }

    /// A session is charted across its own lifetime; a project across the last thirty days.
    /// Both come with how long they were worked on in all.
    private func activity(for subject: HoverSubject, idleGap: TimeInterval) -> ActivitySeries {
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
                endLabel: Format.shortDate(Date(timeIntervalSince1970: last)),
                worked: TimeMath.length(TimeMath.blocks(stamps.sorted(), gap: idleGap))
            )
        case .project(let project):
            let ids = Set(project.sessions.map(\.id))
            let day = 86_400.0
            let end = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 + day
            let start = end - Double(count) * day
            var stamps: [Double] = []
            try? readDB.query("SELECT session_id, ts, role FROM messages") { row in
                guard let id = row.text(0), ids.contains(id), let stamp = row.double(1), stamp > 0 else { return }
                stamps.append(stamp)
                guard row.text(2) == "u", stamp >= start, stamp < end else { return }
                buckets[min(Int((stamp - start) / day), count - 1)] += 1
            }
            // What the timer measured counts too, under any key the project was ever filed as.
            var spans = TimeMath.blocks(stamps.sorted(), gap: idleGap)
            let keys = Set([project.key] + project.mergedKeys)
            let now = Date().timeIntervalSince1970
            try? readDB.query("SELECT project_key, started, ended, open FROM time_entries") { row in
                guard let key = row.text(0), keys.contains(key), let started = row.double(1), let ended = row.double(2) else { return }
                spans.append(TimeSpan(start: started, end: row.int(3) == 1 ? now : ended))
            }
            return ActivitySeries(
                key: subject.key, buckets: buckets, startLabel: L10n.daysAgo(count), endLabel: L10n.today.lowercased(),
                worked: TimeMath.length(TimeMath.merged(spans))
            )
        }
    }

    // MARK: - Retention

    /// Days until Claude Code may delete a session's transcript. Nil for sessions the desktop
    /// app keeps, which it does not clean up, and for sessions with no recorded activity.
    func daysLeft(for session: SessionRecord) -> Int? {
        guard desktop.records[session.id] == nil, let last = session.lastActivity else { return nil }
        return Int((Double(Retention.days) - Date().timeIntervalSince(last) / 86_400).rounded(.up))
    }

    /// What puts a session in danger of being deleted, for the mark on its row: how many days it
    /// has left and whether a copy was taken. Nil when it is in no danger. A session that is
    /// running is still being written to, so it is never one of these.
    func expiry(of session: SessionRecord) -> (days: Int, backedUp: Bool)? {
        guard live[session.id] == nil, let days = daysLeft(for: session),
              (0...Retention.warningWindow).contains(days) else { return nil }
        return (days, Retention.isBackedUp(session))
    }

    /// The sessions in their last days, the one with fewest left first.
    var expiringSessions: [SessionRecord] {
        allSessions.values
            .filter { expiry(of: $0) != nil }
            .sorted { lhs, rhs in
                let left = daysLeft(for: lhs) ?? 0, right = daysLeft(for: rhs) ?? 0
                return left == right ? lhs.id < rhs.id : left < right
            }
    }

    var unbackedExpiringSessions: [SessionRecord] {
        expiringSessions.filter { !Retention.isBackedUp($0) }
    }

    /// Copies the sessions' transcripts into the backups folder.
    func backUp(_ sessions: [SessionRecord]) {
        let done = sessions.filter(Retention.backUp).count
        countBackups()
        show(notice: done == 0 ? L10n.backupFailed : L10n.backedUpChats(done))
    }

    /// Counts what is in the backups folder, for Settings.
    func countBackups() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Retention.folder, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        backupCount = files.count
        backupBytes = files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Updates

    /// The release newer than this copy of the app, when one is known.
    var availableUpdate: String? {
        if case .available(let version) = updateState { return version }
        return nil
    }

    func checkForUpdates() {
        guard updateState != .checking else { return }
        updateState = .checking
        Updates.fetch { [weak self] releases in
            guard let self else { return }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            self.ingest(releases)
        }
    }

    /// Takes what GitHub answered, or nil when it did not.
    func ingest(_ releases: [Release]?, installed: String = Updates.installed) {
        guard let releases else {
            updateState = .failed
            return
        }
        self.releases = releases
        installedVersion = installed
        if let latest = releases.first, Updates.isNewer(latest.version, than: installed) {
            updateState = .available(latest.version)
        } else {
            updateState = .current
        }
    }

    /// The daily check, for those who turned it on.
    func checkForUpdatesIfDue() {
        guard checksForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last > 86_400 { checkForUpdates() }
    }

    // MARK: - Time tracking

    var timeReport: TimeReport { timeReports[timePeriod] ?? TimeReport() }

    func time(for key: String, in period: TimePeriod) -> ProjectTime? {
        timeReports[period]?.rows.first { $0.key == key }
    }

    func isTiming(_ key: String) -> Bool {
        runningTimer?.projectKey == key
    }

    /// Starts the timer for a project. Only one runs at a time, so any other is stopped.
    func startTimer(forProject key: String) {
        guard !isTiming(key) else { return }
        let now = Date().timeIntervalSince1970
        write { db in
            try Self.closeTimers(db, at: now)
            try db.run("INSERT INTO time_entries(project_key, started, ended, open) VALUES(?, ?, ?, 1)", [key, now, now])
        }
    }

    /// Stops the timer. `moment` ends the stretch earlier than now, when the work ended earlier.
    func stopTimer(at moment: Date = Date()) {
        guard let timer = runningTimer else { return }
        let end = max(moment, timer.started).timeIntervalSince1970
        write { db in try Self.closeTimers(db, at: end) }
    }

    func toggleTimer(forProject key: String) {
        if isTiming(key) { stopTimer() } else { startTimer(forProject: key) }
    }

    /// Takes back the last stretch the timer measured for a project.
    func deleteLastTimeEntry(forProject key: String) {
        guard let entry = lastTimeEntries[key] else { return }
        write { db in try db.run("DELETE FROM time_entries WHERE id = ? AND open = 0", [entry.id]) }
    }

    /// Ends whatever is running. A stretch of a few seconds was a slip of the hand and is dropped.
    private static func closeTimers(_ db: Database, at now: Double) throws {
        try db.run("UPDATE time_entries SET ended = ?, open = 0 WHERE open = 1", [now])
        try db.exec("DELETE FROM time_entries WHERE open = 0 AND ended - started < 10")
    }

    /// Called once when the app starts. A timer left running is picked up again if the app was
    /// away for a moment (a restart); otherwise it ends where it was last known to be running.
    func restoreTimer(now: Date = Date()) {
        _ = try? userDB.run(
            "UPDATE time_entries SET open = 0 WHERE open = 1 AND ended < ?", [now.timeIntervalSince1970 - 150]
        )
        _ = try? userDB.exec("DELETE FROM time_entries WHERE open = 0 AND ended - started < 10")
    }

    /// Notes that the timer is still running, so that a crash or a power cut loses a minute at most.
    func recordHeartbeat() {
        guard let timer = runningTimer else { return }
        let now = Date().timeIntervalSince1970
        write { db in try db.run("UPDATE time_entries SET ended = ? WHERE id = ? AND open = 1", [now, timer.id]) }
    }

    /// The same, done before returning, for when the app is about to quit.
    func recordHeartbeatSync() {
        guard let timer = runningTimer else { return }
        _ = try? userDB.run(
            "UPDATE time_entries SET ended = ? WHERE id = ? AND open = 1", [Date().timeIntervalSince1970, timer.id]
        )
    }

    // MARK: - Quick capture

    /// Brings the task field up, ready to type. Called by the quick-task shortcut.
    func quickTask() {
        taskLink = nil
        showBrowseList()
        showsTodos = true
        collapsedSections.remove(PanelSection.todos)
        todoFocusRequest += 1
    }

    /// Brings the note field up, ready to type. Called by the quick-note shortcut.
    func quickNote() {
        showBrowseList()
        collapsedSections.remove(PanelSection.notes)
        noteFocusRequest += 1
    }

    private func showBrowseList() {
        query = ""
        tagFilter = nil
        showingSettings = false
        showingReleaseNotes = false
        outline = nil
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write { db in
            try db.run("INSERT INTO notes(text, created) VALUES(?, ?)", [trimmed, Date().timeIntervalSince1970])
        }
    }

    func delete(_ note: NoteItem) {
        write { db in try db.run("DELETE FROM notes WHERE id = ?", [note.id]) }
    }

    /// Turns a note into a task for the selected day, and removes the note.
    func makeTask(from note: NoteItem) {
        let day = selectedDay
        write { db in
            try db.run(
                "INSERT INTO tasks(session_id, text, done, created, due) VALUES('', ?, 0, ?, ?)",
                [note.text, Date().timeIntervalSince1970, day]
            )
            try db.run("DELETE FROM notes WHERE id = ?", [note.id])
        }
    }

    // MARK: - Shortcut

    /// Starts listening for the next key press, which becomes the new shortcut of that kind.
    func beginShortcutRecording(_ kind: ShortcutKind = .panel) {
        cancelShortcutRecording()
        hotKeys[kind]?.unregister()
        recordingKind = kind
    }

    func cancelShortcutRecording() {
        guard let kind = recordingKind else { return }
        recordingKind = nil
        hotKeys[kind]?.register()
        shortcutLabels[kind] = hotKeys[kind]?.isRegistered == true ? hotKeys[kind]!.shortcut.label : ""
    }

    /// Handles a key press while recording. Escape cancels; a press without ⌘, ⌥ or ⌃ is refused.
    func captureShortcut(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancelShortcutRecording()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            show(notice: L10n.shortcutNeedsModifier)
            return
        }
        guard let kind = recordingKind else { return }
        recordingKind = nil
        guard let hotKey = hotKeys[kind] else { return }
        if !hotKey.change(to: shortcut) {
            show(notice: L10n.shortcutTaken(shortcut.label))
        }
        shortcutLabels[kind] = hotKey.isRegistered ? hotKey.shortcut.label : ""
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

    /// Projects hidden by hand, by name, for Settings to offer back.
    var hiddenProjectList: [ProjectGroup] {
        allProjects
            .filter { hiddenProjects.contains($0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Hides a project from the panel. Its sessions can still be found by a search.
    func hide(_ project: ProjectGroup) {
        hiddenProjects.insert(project.key)
        reload()
    }

    func unhide(_ project: ProjectGroup) {
        hiddenProjects.remove(project.key)
        reload()
    }

    private func write(_ work: @escaping (Database) throws -> Void) {
        userQueue.async { [weak self] in
            guard let self else { return }
            do {
                try work(self.userDB)
            } catch {
                DispatchQueue.main.async { self.show(notice: L10n.couldNotSave) }
            }
            self.reload()
        }
    }

    // MARK: - Preview data

    /// Fills the pinned section with sample tasks for screenshots. Nothing is written to disk.
    func applyPreviewPins() {
        let samples = L10n.previewTasks
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

// MARK: - Demo data

extension Library {
    /// Fills an empty index with made-up projects, chats, tasks and notes, so screenshots show
    /// the app without showing anyone's work. Only runs against an index named by RESPOOL_DB.
    func seedDemo() {
        guard ProcessInfo.processInfo.environment["RESPOOL_DB"] != nil else { return }
        let now = Date().timeIntervalSince1970
        let hour = 3600.0, day = 86_400.0
        // project, title, hours since last activity, prompts, context tokens, custom title?
        let chats: [(String, String, Double, Int, Int, Bool)] = [
            ("storefront", "Checkout flow redesign", 0.2, 34, 412_000, true),
            ("storefront", "Fix the cart total rounding", 3, 9, 96_000, false),
            ("storefront", "Product page image loading", 27, 17, 188_000, false),
            ("storefront", "Migrate to the new design tokens", 80, 41, 530_000, true),
            ("billing-api", "Invoice PDF generation", 1.5, 22, 240_000, true),
            ("billing-api", "Retry failed webhooks", 30, 12, 131_000, false),
            ("billing-api", "Tax rules for EU customers", 52, 28, 305_000, false),
            ("mobile-app", "Offline sync conflicts", 6, 19, 276_000, true),
            ("mobile-app", "Push notification deep links", 49, 8, 74_000, false),
            ("mobile-app", "Release checklist", 120, 6, 52_000, true),
            ("docs", "Rewrite the getting started guide", 26, 14, 118_000, false),
            ("docs", "API reference examples", 200, 7, 61_000, false),
            ("infra", "Staging database upgrade", 75, 16, 162_000, true),
            ("infra", "Reduce the CI build time", 300, 25, 210_000, false),
        ]
        let prompts = [
            "Walk me through how this works today before changing anything",
            "The invoice total is off by one cent when a discount applies, find out why",
            "Add a test for that case and make it pass",
            "Looks good, now do the same for the mobile client",
            "Summarize what changed so I can write the release note",
        ]
        do {
            try userDB.exec("BEGIN")
            for (index, chat) in chats.enumerated() {
                let id = String(format: "00000000-0000-4000-8000-%012d", index + 1)
                let cwd = "/Users/demo/code/" + chat.0
                let last = now - chat.2 * hour
                let first = last - Double(chat.3) * 9 * 60
                try userDB.run(
                    """
                    INSERT INTO sessions(id, path, cwd, custom_title, ai_title, last_prompt, first_prompt, first_ts, last_ts,
                        entrypoint, branch, msg_count, file_size, file_mtime, indexed_offset,
                        tok_input, tok_cached, tok_output, context_tokens, model)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 'claude-desktop', ?, ?, ?, ?, 1, ?, ?, ?, ?, 'claude-opus-5-5')
                    """,
                    [
                        id, "/demo/\(id).jsonl", cwd, chat.5 ? chat.1 : nil, chat.1, prompts[index % prompts.count],
                        prompts[0], first, last, index % 3 == 0 ? "main" : "feature/\(chat.0)", chat.3,
                        chat.4 * 14, last, chat.4 * 2, chat.4 * 90, chat.4 / 3, chat.4,
                    ]
                )
                try userDB.run(
                    "INSERT OR REPLACE INTO cwd_projects(cwd, key, name, durable) VALUES(?, ?, ?, 1)",
                    [cwd, "git:acme/" + chat.0, chat.0]
                )
                for step in 0..<chat.3 {
                    let stamp = first + (last - first) * Double(step) / Double(max(chat.3 - 1, 1))
                    try userDB.run(
                        "INSERT INTO messages(text, session_id, role, ts) VALUES(?, ?, 'u', ?)",
                        [prompts[(index + step) % prompts.count], id, stamp]
                    )
                }
            }
            let ids = chats.indices.map { String(format: "00000000-0000-4000-8000-%012d", $0 + 1) }
            for (position, pinned) in [0, 4, 7].enumerated() {
                try userDB.run("INSERT INTO pins(session_id, position) VALUES(?, ?)", [ids[pinned], Double(position)])
            }
            let today = Format.dayKey(Date())
            let tomorrow = Format.dayKey(Date().addingTimeInterval(day))
            let tasks: [(String, String, String?, String?, Bool)] = [
                ("Test the checkout on a slow connection", ids[0], today, nil, false),
                ("Send the invoice template to finance", "", today, nil, true),
                ("Decide on the retry limit", ids[5], today, nil, false),
                ("Draft the release note", "", tomorrow, "git:acme/mobile-app", false),
                ("Read the tax ruling", "", nil, nil, false),
            ]
            for task in tasks {
                try userDB.run(
                    "INSERT INTO tasks(session_id, text, done, created, done_at, due, project_key) VALUES(?, ?, ?, ?, ?, ?, ?)",
                    [task.1, task.0, task.4, now, task.4 ? now : nil, task.2, task.3]
                )
            }
            for (name, color, tagged) in [("urgent", 0, 0), ("customer", 4, 4), ("research", 5, 7)] {
                try userDB.run("INSERT INTO tags(name, color) VALUES(?, ?)", [name, color])
                try userDB.run(
                    "INSERT INTO session_tags(session_id, tag_id) SELECT ?, id FROM tags WHERE name = ?", [ids[tagged], name]
                )
            }
            for (offset, note) in ["Ask Dana about the staging credentials", "Idea: show the cart total while typing a coupon"].enumerated() {
                try userDB.run("INSERT INTO notes(text, created) VALUES(?, ?)", [note, now - Double(offset + 1) * hour])
            }
            // What the timer measured: one stretch the prompts also show, and one they do not.
            for (project, from, to) in [("storefront", 5.0, 4.1), ("billing-api", 2.9, 2.2), ("docs", 30.0, 28.8)] {
                try userDB.run(
                    "INSERT INTO time_entries(project_key, started, ended, open) VALUES(?, ?, ?, 0)",
                    ["git:acme/" + project, now - from * hour, now - to * hour]
                )
            }
            try userDB.exec("COMMIT")
        } catch {
            _ = try? userDB.exec("ROLLBACK")
            print("demo data failed: \(error)")
        }
        expanded = ["git:acme/storefront"]
        reloadSync()
    }
}
