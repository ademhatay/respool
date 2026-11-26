import Foundation

struct IndexStats {
    var total = 0
    var updated = 0
    var removed = 0
    var messages = 0
}

/// Reads Claude Code transcripts (read-only) and keeps the local index in step with them.
/// Transcripts are append-only, so a file that only grew is parsed from where the last run stopped.
final class Indexer {
    private static let maxLineBytes = 512 * 1024
    private static let maxTextLength = 16_000

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    private struct FileEntry {
        let id: String
        let path: String
        let size: Int
        let mtime: Double
    }

    private struct Known {
        let path: String
        let size: Int
        let mtime: Double
        let offset: Int
    }

    private struct Accumulator {
        var cwd: String?
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var firstPrompt: String?
        var firstTimestamp: Double?
        var lastTimestamp: Double?
        var entrypoint: String?
        var branch: String?
        var prURL: String?
        var prNumber: Int?
        var promptCount = 0
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
        /// Tokens the model read on its latest turn, which is how full the context is.
        var contextTokens: Int?
        var model: String?
        var lastUsageMessageID: String?
    }

    @discardableResult
    func run(progress: ((Int, Int) -> Void)? = nil) -> IndexStats {
        var stats = IndexStats()
        let files = discover()
        stats.total = files.count

        var known: [String: Known] = [:]
        try? db.query("SELECT id, path, file_size, file_mtime, indexed_offset FROM sessions") { row in
            guard let id = row.text(0), let path = row.text(1) else { return }
            known[id] = Known(path: path, size: row.int(2), mtime: row.double(3) ?? 0, offset: row.int(4))
        }

        let pending = files.filter { file in
            guard let old = known[file.id] else { return true }
            return old.path != file.path || old.size != file.size || abs(old.mtime - file.mtime) > 0.001
        }

        for (position, file) in pending.enumerated() {
            progress?(position, pending.count)
            let old = known[file.id]
            let canAppend = old.map { $0.path == file.path && $0.offset > 0 && file.size >= $0.offset } ?? false
            do {
                stats.messages += try index(file, from: canAppend ? old!.offset : 0, isKnown: old != nil)
                stats.updated += 1
            } catch {
                try? db.exec("ROLLBACK")
            }
        }
        if !pending.isEmpty { progress?(pending.count, pending.count) }

        let present = Set(files.map(\.id))
        for id in known.keys where !present.contains(id) {
            _ = try? db.run("DELETE FROM messages WHERE session_id = ?", [id])
            _ = try? db.run("DELETE FROM sessions WHERE id = ?", [id])
            stats.removed += 1
        }
        return stats
    }

    private func discover() -> [FileEntry] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var best: [String: FileEntry] = [:]
        let folders = (try? manager.contentsOfDirectory(at: Paths.transcripts, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            for url in entries where url.pathExtension == "jsonl" {
                let id = url.deletingPathExtension().lastPathComponent
                guard id.count == 36, let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let entry = FileEntry(
                    id: id,
                    path: url.path,
                    size: values.fileSize ?? 0,
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                )
                // The same session can exist in two folders after a move; keep the larger copy.
                if let existing = best[id], existing.size >= entry.size { continue }
                best[id] = entry
            }
        }
        return Array(best.values)
    }

    private func index(_ file: FileEntry, from offset: Int, isKnown: Bool) throws -> Int {
        var accumulator = Accumulator()
        var inserted = 0

        try db.exec("BEGIN IMMEDIATE")
        if offset == 0, isKnown {
            try db.run("DELETE FROM messages WHERE session_id = ?", [file.id])
            try db.run("DELETE FROM sessions WHERE id = ?", [file.id])
        }
        let insert = try db.prepared("INSERT INTO messages(text, session_id, role, ts) VALUES(?, ?, ?, ?)")
        let consumed = try parse(path: file.path, from: offset, into: &accumulator) { role, text, timestamp in
            try insert.run([String(text.prefix(Self.maxTextLength)), file.id, role, timestamp])
            inserted += 1
        }

        try db.run(
            """
            INSERT INTO sessions(
                id, path, cwd, custom_title, ai_title, last_prompt, first_prompt, first_ts, last_ts,
                entrypoint, branch, pr_url, pr_number, msg_count, file_size, file_mtime, indexed_offset,
                tok_input, tok_cached, tok_output, context_tokens, model
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                cwd = COALESCE(sessions.cwd, excluded.cwd),
                custom_title = COALESCE(excluded.custom_title, sessions.custom_title),
                ai_title = COALESCE(excluded.ai_title, sessions.ai_title),
                last_prompt = COALESCE(excluded.last_prompt, sessions.last_prompt),
                first_prompt = COALESCE(sessions.first_prompt, excluded.first_prompt),
                first_ts = COALESCE(sessions.first_ts, excluded.first_ts),
                last_ts = MAX(COALESCE(excluded.last_ts, 0), COALESCE(sessions.last_ts, 0)),
                entrypoint = COALESCE(sessions.entrypoint, excluded.entrypoint),
                branch = COALESCE(excluded.branch, sessions.branch),
                pr_url = COALESCE(excluded.pr_url, sessions.pr_url),
                pr_number = COALESCE(excluded.pr_number, sessions.pr_number),
                msg_count = sessions.msg_count + excluded.msg_count,
                file_size = excluded.file_size,
                file_mtime = excluded.file_mtime,
                indexed_offset = excluded.indexed_offset,
                tok_input = sessions.tok_input + excluded.tok_input,
                tok_cached = sessions.tok_cached + excluded.tok_cached,
                tok_output = sessions.tok_output + excluded.tok_output,
                context_tokens = COALESCE(excluded.context_tokens, sessions.context_tokens),
                model = COALESCE(excluded.model, sessions.model)
            """,
            [
                file.id, file.path, accumulator.cwd, accumulator.customTitle, accumulator.aiTitle,
                accumulator.lastPrompt, accumulator.firstPrompt, accumulator.firstTimestamp,
                accumulator.lastTimestamp, accumulator.entrypoint, accumulator.branch, accumulator.prURL,
                accumulator.prNumber, accumulator.promptCount, file.size, file.mtime, consumed,
                accumulator.inputTokens, accumulator.cachedTokens, accumulator.outputTokens,
                accumulator.contextTokens, accumulator.model,
            ]
        )
        try db.exec("COMMIT")
        return inserted
    }

    // MARK: - Parsing

    private static let metaPrefix = Array(#"{"type":""#.utf8)
    private static let userMarker = Array(#""type":"user""#.utf8)
    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let wantedMeta: Set<String> = ["custom-title", "ai-title", "last-prompt", "pr-link"]

    /// Returns the byte offset up to which complete lines were consumed.
    private func parse(
        path: String,
        from start: Int,
        into accumulator: inout Accumulator,
        emit: (String, String, Double?) throws -> Void
    ) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let count = data.count
        guard start < count else { return min(start, count) }
        var consumed = start

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var position = start
            while position < count {
                guard let newline = memchr(base + position, 0x0A, count - position) else { break }
                let end = base.distance(to: UnsafeRawPointer(newline))
                let length = end - position
                if length > 2, length <= Self.maxLineBytes {
                    try handleLine(base + position, length, &accumulator, emit)
                }
                position = end + 1
                consumed = position
            }
        }
        return consumed
    }

    private func handleLine(
        _ pointer: UnsafeRawPointer,
        _ length: Int,
        _ accumulator: inout Accumulator,
        _ emit: (String, String, Double?) throws -> Void
    ) throws {
        let prefix = Self.metaPrefix
        if length > prefix.count, memcmp(pointer, prefix, prefix.count) == 0 {
            let typeStart = pointer + prefix.count
            guard let quote = memchr(typeStart, 0x22, min(length - prefix.count, 48)) else { return }
            let typeLength = typeStart.distance(to: UnsafeRawPointer(quote))
            let type = String(decoding: UnsafeRawBufferPointer(start: typeStart, count: typeLength), as: UTF8.self)
            guard Self.wantedMeta.contains(type) else { return }
        } else {
            let isMessage = memmem(pointer, length, Self.userMarker, Self.userMarker.count) != nil
                || memmem(pointer, length, Self.assistantMarker, Self.assistantMarker.count) != nil
            guard isMessage else { return }
        }

        let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: length, deallocator: .none)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "custom-title":
            accumulator.customTitle = object["customTitle"] as? String
        case "ai-title":
            accumulator.aiTitle = object["aiTitle"] as? String
        case "last-prompt":
            accumulator.lastPrompt = (object["lastPrompt"] as? String).map { String($0.prefix(400)) }
        case "pr-link":
            accumulator.prURL = object["prUrl"] as? String
            accumulator.prNumber = object["prNumber"] as? Int
        case "user", "assistant":
            try handleMessage(object, isUser: type == "user", &accumulator, emit)
        default:
            return
        }
    }

    private func handleMessage(
        _ object: [String: Any],
        isUser: Bool,
        _ accumulator: inout Accumulator,
        _ emit: (String, String, Double?) throws -> Void
    ) throws {
        if object["isSidechain"] as? Bool == true { return }
        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)
        if let timestamp {
            if accumulator.firstTimestamp == nil { accumulator.firstTimestamp = timestamp }
            accumulator.lastTimestamp = max(accumulator.lastTimestamp ?? 0, timestamp)
        }
        // The launch folder identifies the project; later values drift when the agent changes directory.
        if accumulator.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { accumulator.cwd = cwd }
        if let branch = object["gitBranch"] as? String, !branch.isEmpty { accumulator.branch = branch }
        if accumulator.entrypoint == nil { accumulator.entrypoint = object["entrypoint"] as? String }

        if isUser, object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return }
        guard let message = object["message"] as? [String: Any] else { return }
        if !isUser { recordUsage(message, &accumulator) }

        var texts: [String] = []
        if let content = message["content"] as? String {
            texts.append(content)
        } else if let parts = message["content"] as? [[String: Any]] {
            for part in parts where part["type"] as? String == "text" {
                if let text = part["text"] as? String { texts.append(text) }
            }
        }

        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isUser {
                guard Self.isTypedPrompt(trimmed) else { continue }
                accumulator.promptCount += 1
                if accumulator.firstPrompt == nil { accumulator.firstPrompt = String(trimmed.prefix(400)) }
            }
            try emit(isUser ? "u" : "a", trimmed, timestamp)
        }
    }

    /// Adds one assistant message's token usage. A message is written as several lines that
    /// repeat the same usage, so it is counted once per message id.
    private func recordUsage(_ message: [String: Any], _ accumulator: inout Accumulator) {
        guard let usage = message["usage"] as? [String: Any], let id = message["id"] as? String,
              id != accumulator.lastUsageMessageID else { return }
        accumulator.lastUsageMessageID = id
        let fresh = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        let cached = usage["cache_read_input_tokens"] as? Int ?? 0
        accumulator.inputTokens += fresh
        accumulator.cachedTokens += cached
        accumulator.outputTokens += usage["output_tokens"] as? Int ?? 0
        if fresh + cached > 0 { accumulator.contextTokens = fresh + cached }
        if let model = message["model"] as? String, !model.hasPrefix("<") { accumulator.model = model }
    }

    private static let machinePrefixes = [
        "<local-command", "<command-name>", "<command-message>", "<command-args>", "<task-notification>",
        "<system-reminder>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>",
        "Caveat: The messages below", "[Request interrupted",
    ]

    /// Filters out lines the harness writes on the user's behalf (command output, notifications).
    private static func isTypedPrompt(_ text: String) -> Bool {
        !machinePrefixes.contains { text.hasPrefix($0) }
    }

    /// Parses `2026-09-07T06:50:05.161Z` without going through a date formatter.
    static func parseTimestamp(_ string: String) -> Double? {
        let bytes = Array(string.utf8)
        guard bytes.count >= 19 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let digit = Int(bytes[index]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
        var fraction = 0.0
        if bytes.count >= 23, bytes[19] == 46, let millis = number(20, 3) { fraction = Double(millis) / 1000 }

        let adjustedYear = month <= 2 ? year - 1 : year
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction
    }
}
