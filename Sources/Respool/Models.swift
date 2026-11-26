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
        return "Adsız sohbet"
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
    /// For a to-do that belongs to no session: "today" or "week".
    var bucket: String?
}

enum TodoBucket {
    static let today = "today"
    static let week = "week"

    static func title(_ bucket: String) -> String {
        bucket == week ? "Bu hafta" : "Bugün"
    }
}

struct PinnedSession: Identifiable, Hashable {
    var session: SessionRecord
    var tasks: [TaskItem]

    var id: String { session.id }
    var openCount: Int { tasks.filter { !$0.done }.count }
}

struct ProjectGroup: Identifiable, Hashable {
    let key: String
    var name: String
    var sessions: [SessionRecord]
    var folders: [String]
    var mergedKeys: [String]

    var id: String { key }
    var lastActivity: Date? { sessions.first?.lastActivity }
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

enum PanelSection {
    static let todos = "todos"
    static let pinned = "pinned"
    static let recent = "recent"
    static let projects = "projects"
}

enum Format {
    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()

    /// A token count in the largest unit that keeps it short: 512K, 39,2M, 1,5 Mr.
    static func tokens(_ count: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let value = (Double(count) / divisor * 10).rounded() / 10
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return text.replacingOccurrences(of: ".", with: ",") + suffix
        }
        if count >= 1_000_000_000 { return scaled(1_000_000_000, " Mr") }
        if count >= 1_000_000 { return scaled(1_000_000, "M") }
        if count >= 10_000 { return "\(Int((Double(count) / 1000).rounded()))K" }
        if count >= 1000 { return scaled(1000, "K") }
        return "\(count)"
    }

    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
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
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    static func shortDate(_ date: Date) -> String {
        shortDateTime.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM EEEE"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func time(_ date: Date?) -> String {
        date.map(timeFormatter.string(from:)) ?? ""
    }

    /// A length of time in its two largest units, such as "6 sa 40 dk" or "3 gün 2 sa".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "1 dk'dan az" }
        if minutes < 60 { return "\(minutes) dk" }
        let hours = minutes / 60
        if hours < 24 {
            return minutes % 60 == 0 ? "\(hours) sa" : "\(hours) sa \(minutes % 60) dk"
        }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) gün" : "\(days) gün \(hours % 24) sa"
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
    static func hit(_ id: String) -> String { "hit:" + id }
    static func tagged(_ id: String) -> String { "tagged:" + id }

    static func sessionID(_ key: String) -> String {
        key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
    }
}

enum RelativeTime {
    private static let sameYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        let calendar = Calendar.current
        if seconds < 60 { return "şimdi" }
        if seconds < 3600 { return "\(Int(seconds / 60)) dk" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) sa" }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 1 { return "dün" }
        if days < 7 { return "\(days) gün" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return sameYear.string(from: date)
        }
        return otherYear.string(from: date)
    }
}
