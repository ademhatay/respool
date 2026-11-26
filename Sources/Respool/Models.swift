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

struct HoverTarget: Hashable {
    var subject: HoverSubject
    /// Vertical center of the row, measured down from the top of the panel.
    var rowMidY: CGFloat
}

enum Format {
    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1f Mr", Double(count) / 1_000_000_000).replacingOccurrences(of: ".", with: ",")
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        }
        if count >= 10_000 { return "\(Int((Double(count) / 1000).rounded()))K" }
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000).replacingOccurrences(of: ".", with: ",")
        }
        return "\(count)"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        date.map(dateTime.string(from:)) ?? "—"
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
