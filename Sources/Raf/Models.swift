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
    var projectKey: String = ""
    var projectName: String = ""

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

enum RowKey {
    static func pin(_ id: String) -> String { "pin:" + id }
    static func recent(_ id: String) -> String { "recent:" + id }
    static func project(_ id: String) -> String { "project:" + id }
    static func hit(_ id: String) -> String { "hit:" + id }

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
