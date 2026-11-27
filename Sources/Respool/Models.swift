import Foundation

struct SessionRecord: Identifiable, Hashable {
    let id: String
    var path: String
    var cwd: String
    var customTitle: String?
    var aiTitle: String?
    var firstPrompt: String?
    var lastPrompt: String?
    var lastActivity: Date?
    var prNumber: Int?
    var prURL: String?
    var messageCount: Int
    var firstActivity: Date?
    var branch: String?
    var fileSize = 0
    var inputTokens = 0
    var cachedTokens = 0
    var outputTokens = 0
    var contextTokens: Int?
    var model: String?
    /// How the session was started, as Claude Code names it: "cli", "claude-desktop", "claude-vscode".
    var entrypoint: String?
    var projectKey: String = ""
    var projectName: String = ""
    var tagIDs: [Int64] = []
    /// The organization the desktop app filed this session under; nil for terminal-only sessions.
    var organizationID: String?
    var organizationName: String?
    /// True when the session's organization is not the one the desktop app is signed in to.
    var inOtherOrganization = false

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        let prompt = (firstPrompt ?? lastPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = prompt.split(whereSeparator: \.isNewline).first, !line.isEmpty {
            return String(line.prefix(80))
        }
        return L10n.untitledChat
    }

    var hasCustomTitle: Bool {
        !(customTitle ?? "").isEmpty
    }

    /// The project, plus the organization when the session lives in one that is not open.
    var placeLabel: String {
        guard inOtherOrganization, let organizationName else { return projectName }
        return "\(projectName) · \(organizationName)"
    }
}

struct Tag: Identifiable, Hashable {
    let id: Int64
    var name: String
    /// Index into `TagPalette.colors`.
    var color: Int
}

struct Organization: Identifiable, Hashable {
    let id: String
    var name: String
    var isCurrent: Bool
    var sessionCount: Int
}

/// The tag being created or renamed in the panel.
struct TagEditor: Hashable {
    var tagID: Int64?
    /// A session to tag as soon as the new tag is created.
    var sessionID: String?
    var name = ""
    var color = 4
}

struct TaskItem: Identifiable, Hashable {
    let id: Int64
    let sessionID: String
    var text: String
    var done: Bool
    var doneAt: Date?
    /// The day the task is planned for, as `yyyy-MM-dd`; nil when it has no date.
    var due: String?
    /// The project the task belongs to, when it is linked to one rather than to a session.
    var projectKey: String?
    var created = Date.distantPast
    /// Where in its list the task was dragged to. A task that was never dragged is ordered by
    /// when it was added, which comes after any dragged one.
    var position: Double?

    /// What the task is ordered by inside its list.
    var rank: Double { position ?? created.timeIntervalSince1970 }
}

/// What a new task will be attached to.
enum TaskLink: Hashable {
    case session(id: String, title: String)
    case project(key: String, name: String)

    var title: String {
        switch self {
        case .session(_, let title): return title
        case .project(_, let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .session: return "bubble.left"
        case .project: return "folder"
        }
    }
}

struct PinnedSession: Identifiable, Hashable {
    var session: SessionRecord
    var tasks: [TaskItem]

    var id: String { session.id }
    var openCount: Int { tasks.filter { !$0.done }.count }
}

/// A session that was used on one day, and how many prompts were typed in it there.
struct DayWork: Identifiable, Hashable {
    var session: SessionRecord
    var prompts: Int

    var id: String { session.id }
}

/// What a day's work touched: its sessions, the most used first.
struct DaySummary: Identifiable, Hashable {
    /// The day, as a day key.
    let day: String
    var work: [DayWork]

    var id: String { day }
    var prompts: Int { work.reduce(0) { $0 + $1.prompts } }
}

struct ProjectGroup: Identifiable, Hashable {
    let key: String
    var name: String
    var sessions: [SessionRecord]
    var folders: [String]
    var mergedKeys: [String]

    var id: String { key }
    var lastActivity: Date? { sessions.first?.lastActivity }

    /// Everything the sessions read and wrote, cached input included.
    var tokenUse: Int {
        sessions.reduce(0) { $0 + $1.inputTokens + $1.cachedTokens + $1.outputTokens }
    }
}

/// The orders the project list can be put in. The raw value is what is saved.
enum ProjectSort: Int, CaseIterable, Hashable {
    case activity, name, sessions, tokens

    var title: String {
        switch self {
        case .activity: return L10n.sortActivity
        case .name: return L10n.sortName
        case .sessions: return L10n.sortSessions
        case .tokens: return L10n.sortTokens
        }
    }

    /// Puts projects in this order, settling ties by name so the list never shuffles.
    func areInOrder(_ first: ProjectGroup, _ second: ProjectGroup) -> Bool {
        let a = figure(first), b = figure(second)
        return a == b ? Self.byName(first, second) : a > b
    }

    /// What each project is ranked by, largest first. Sorting by name ranks them all the same,
    /// which leaves the order to the tie-break.
    private func figure(_ project: ProjectGroup) -> Double {
        switch self {
        case .activity: return project.lastActivity?.timeIntervalSince1970 ?? -.infinity
        case .name: return 0
        case .sessions: return Double(project.sessions.count)
        case .tokens: return Double(project.tokenUse)
        }
    }

    private static func byName(_ first: ProjectGroup, _ second: ProjectGroup) -> Bool {
        let order = first.name.localizedStandardCompare(second.name)
        if order == .orderedSame { return first.key < second.key }
        return order == .orderedAscending
    }
}

struct SearchHit: Identifiable, Hashable {
    var session: SessionRecord
    /// Snippet text with match ranges, or nil when only the title matched.
    var snippet: Snippet?

    var id: String { session.id }
}

struct Snippet: Hashable {
    var text: String
    var matches: [Range<Int>]
}

/// What the pointer is resting on, for the detail card that appears beside the panel.
enum HoverSubject: Hashable {
    case session(SessionRecord)
    case project(ProjectGroup)
}

extension HoverSubject {
    var key: String {
        switch self {
        case .session(let session): return "session:" + session.id
        case .project(let project): return "project:" + project.key
        }
    }
}

/// How busy a session or project was over time, as counts per equal slice of the period.
struct ActivitySeries: Hashable {
    var key: String
    var buckets: [Int]
    var startLabel: String
    var endLabel: String
    /// How long the subject was worked on in all, once that has been added up.
    var worked: TimeInterval?
}

struct HoverTarget: Hashable {
    var subject: HoverSubject
    /// Where the pointer was on the screen, so the card can open level with it.
    var screenY: CGFloat
}

/// One thing the user typed in a session.
struct OutlineEntry: Identifiable, Hashable {
    let id: Int
    var text: String
    var date: Date?
}

/// Everything the user asked in one session, in order.
struct SessionOutline: Hashable {
    var session: SessionRecord
    var entries: [OutlineEntry]
}

/// A line jotted down from anywhere, to be dealt with later.
struct NoteItem: Identifiable, Hashable {
    let id: Int64
    var text: String
    var created: Date?
}

/// The screen edge the panel opens from.
enum PanelEdge: String, CaseIterable {
    case right, left, top, bottom
    /// Wherever the panel was dragged to, at the size it was given.
    case free

    /// The edges the panel can be docked to.
    static let edges: [PanelEdge] = [.right, .left, .top, .bottom]

    var title: String {
        switch self {
        case .free: return L10n.edgeFree
        case .right: return L10n.edgeRight
        case .left: return L10n.edgeLeft
        case .top: return L10n.edgeTop
        case .bottom: return L10n.edgeBottom
        }
    }
}

enum PanelSection {
    static let waiting = "waiting"
    static let todos = "todos"
    static let notes = "notes"
    static let pinned = "pinned"
    static let recent = "recent"
    static let week = "week"
    static let time = "time"
    static let projects = "projects"
}

enum Format {
    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()

    /// A token count in the largest unit that keeps it short: 512K, 39,2M, 1,5 Mr.
    static func tokens(_ count: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let value = (Double(count) / divisor * 10).rounded() / 10
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return L10n.decimal(text) + suffix
        }
        if count >= 1_000_000_000 { return scaled(1_000_000_000, L10n.billions) }
        if count >= 1_000_000 { return scaled(1_000_000, "M") }
        if count >= 10_000 { return "\(Int((Double(count) / 1000).rounded()))K" }
        if count >= 1000 { return scaled(1000, "K") }
        return "\(count)"
    }

    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// A plain count with thousands separators, such as 1.280.
    static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        date.map(dateTime.string(from:)) ?? "—"
    }

    private static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    static func shortDate(_ date: Date) -> String {
        shortDateTime.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "d MMMM EEEE"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The local calendar day as `yyyy-MM-dd`, which sorts in date order.
    static func dayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// The same, read off the calendar instead of a formatter, which is not safe off the main
    /// thread. The calendar must be the one the panel's weeks are cut by.
    static func dayKey(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDayKey key: String) -> Date? {
        dayKeyFormatter.date(from: key)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    static func month(_ date: Date) -> String {
        monthFormatter.string(from: date).capitalized(with: Locale(identifier: L10n.localeIdentifier))
    }

    private static let releaseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    static func releaseDate(_ date: Date) -> String {
        releaseFormatter.string(from: date)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "EEE"
        return formatter
    }()

    /// A day of the week as "Pzt".
    static func weekday(_ date: Date) -> String {
        weekdayFormatter.string(from: date)
    }

    /// A day as "Pzt 30 Kas".
    static func shortDay(_ date: Date) -> String {
        shortDayFormatter.string(from: date)
    }

    private static let monthNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "LLLL"
        return formatter
    }()

    private static func monthName(_ date: Date) -> String {
        monthNameFormatter.string(from: date)
    }

    /// What to call the days a calendar shows: one month, or both when a week crosses into another.
    static func calendarTitle(from first: Date, to last: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let head = calendar.dateComponents([.year, .month], from: first)
        let tail = calendar.dateComponents([.year, .month], from: last)
        if head == tail { return month(first) }
        if head.year == tail.year { return monthName(first) + " – " + month(last) }
        return month(first) + " – " + month(last)
    }

    static func time(_ date: Date?) -> String {
        date.map(timeFormatter.string(from:)) ?? ""
    }

    /// A length of time in its two largest units, such as "6 sa 40 dk" or "3 gün 2 sa".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L10n.underMinute }
        if minutes < 60 { return L10n.minutes(minutes) }
        let hours = minutes / 60
        if hours < 24 {
            return minutes % 60 == 0 ? L10n.hours(hours) : L10n.hoursAndMinutes(hours, minutes % 60)
        }
        let days = hours / 24
        return hours % 24 == 0 ? L10n.days(days) : L10n.daysAndHours(days, hours % 24)
    }

    /// A running clock, such as 0:42:07.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds), 0)
        return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    /// Hours and minutes for a narrow place, such as 1:24.
    static func shortClock(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds), 0) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// A length of work in hours and minutes, however long: 26 sa 10 dk rather than a day.
    static func worked(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return L10n.underMinute }
        if minutes < 60 { return L10n.minutes(minutes) }
        return minutes % 60 == 0 ? L10n.hours(minutes / 60) : L10n.hoursAndMinutes(minutes / 60, minutes % 60)
    }

    static func path(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum RowKey {
    static func pin(_ id: String) -> String { "pin:" + id }
    static func recent(_ id: String) -> String { "recent:" + id }
    static func project(_ id: String) -> String { "project:" + id }
    static func day(_ day: String, _ id: String) -> String { "day:" + day + ":" + id }
    static func hit(_ id: String) -> String { "hit:" + id }
    static func tagged(_ id: String) -> String { "tagged:" + id }
    static func waiting(_ id: String) -> String { "waiting:" + id }

    static func sessionID(_ key: String) -> String {
        // A day's rows name the day as well: day:<day>:<session id>.
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return String(parts.last ?? Substring(key))
    }
}

enum RelativeTime {
    private static let sameYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.localeIdentifier)
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        let calendar = Calendar.current
        if seconds < 60 { return L10n.now }
        if seconds < 3600 { return L10n.minutes(Int(seconds / 60)) }
        if calendar.isDate(date, inSameDayAs: now) { return L10n.hours(Int(seconds / 3600)) }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 1 { return L10n.yesterday.lowercased() }
        if days < 7 { return L10n.shortDays(days) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return sameYear.string(from: date)
        }
        return otherYear.string(from: date)
    }
}

// MARK: - Time tracking

/// A stretch of time, as seconds since 1970.
struct TimeSpan: Hashable {
    var start: Double
    var end: Double
}

/// The periods a project's time is added up over. The raw value is what is saved.
enum TimePeriod: Int, CaseIterable, Hashable {
    case today, week, month

    var title: String {
        switch self {
        case .today: return L10n.today
        case .week: return L10n.weekTitle
        case .month: return L10n.thisMonth
        }
    }

    var next: TimePeriod {
        TimePeriod(rawValue: (rawValue + 1) % Self.allCases.count) ?? .today
    }
}

/// How long a project was worked on in one period. `manual` is what the timer measured and
/// `automatic` what the prompts suggest; `total` counts a minute that is in both only once.
struct ProjectTime: Identifiable, Hashable {
    let key: String
    var name: String
    var manual: TimeInterval
    var automatic: TimeInterval
    var total: TimeInterval
    /// Which of the chart's colors the project is drawn in; nil once they have run out.
    var color: Int?
    /// When the timer ran and when the prompts suggest work, for a period short enough to draw
    /// moment by moment. Empty for the longer periods.
    var timed: [TimeSpan] = []
    var guessed: [TimeSpan] = []

    var id: String { key }
}

/// One day of a period: how long each project was worked on in it.
struct DayTime: Identifiable, Hashable {
    let day: String
    var date: Date
    var parts: [String: TimeInterval] = [:]

    var id: String { day }
    var total: TimeInterval { parts.values.reduce(0, +) }
}

struct TimeReport: Hashable {
    var rows: [ProjectTime] = []
    /// Every project together. Two projects worked on at once count once here.
    var total: TimeInterval = 0
    /// When the period began and the moment it was added up.
    var start: Double = 0
    var end: Double = 0
    /// The period day by day, for the periods longer than one.
    var days: [DayTime] = []
}

/// The timer that is running now.
struct RunningTimer: Hashable {
    let id: Int64
    let projectKey: String
    var projectName: String
    let started: Date
}

/// A stretch the timer measured and has finished with.
struct TimeEntry: Hashable {
    let id: Int64
    var length: TimeInterval
}

enum TimeMath {
    /// Turns moments of activity into stretches of work: moments closer together than `gap`
    /// belong to one stretch. `stamps` must be in order. A moment on its own has no length.
    static func blocks(_ stamps: [Double], gap: Double) -> [TimeSpan] {
        var spans: [TimeSpan] = []
        for stamp in stamps {
            if let last = spans.last, stamp - last.end <= gap {
                spans[spans.count - 1].end = max(last.end, stamp)
            } else {
                spans.append(TimeSpan(start: stamp, end: stamp))
            }
        }
        return spans
    }

    /// The same time with overlaps joined, in order.
    static func merged(_ spans: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// The parts of the spans that fall between two moments.
    static func clipped(_ spans: [TimeSpan], from start: Double, to end: Double) -> [TimeSpan] {
        spans.compactMap { span in
            let clipped = TimeSpan(start: max(span.start, start), end: min(span.end, end))
            return clipped.end > clipped.start ? clipped : nil
        }
    }

    static func length(_ spans: [TimeSpan]) -> TimeInterval {
        spans.reduce(0) { $0 + max($1.end - $1.start, 0) }
    }
}

// MARK: - Opening sessions

/// Where a session is opened. The raw value is what is saved.
enum OpenMethod: String, CaseIterable, Hashable {
    /// Where the session lives: the Claude app for a session it tracks, a terminal for the rest.
    case automatic
    case desktop, terminal, iterm, vscode, cursor, zed

    var title: String {
        switch self {
        case .automatic: return L10n.openAutomatic
        case .desktop: return "Claude"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        }
    }

    /// The app that does the opening, for the choices that need one installed.
    var bundleID: String? {
        switch self {
        case .automatic, .desktop: return nil
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        }
    }

    /// The way of opening that goes with the app a session was seen running in.
    init?(hostBundleID: String?) {
        guard let hostBundleID else { return nil }
        if hostBundleID == "com.anthropic.claudefordesktop" {
            self = .desktop
        } else if let match = Self.allCases.first(where: { $0.bundleID == hostBundleID }) {
            self = match
        } else {
            return nil
        }
    }

    /// An editor opens the project's folder; Claude Code is then started in its own terminal.
    var isEditor: Bool { self == .vscode || self == .cursor || self == .zed }
}
