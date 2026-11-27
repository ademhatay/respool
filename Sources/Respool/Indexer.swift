import Foundation

struct IndexStats {
    var total = 0
    var updated = 0
    var removed = 0
    var messages = 0
    /// True when the transcripts folder could not be read, so nothing was changed.
    var unreachable = false
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
        /// The first message whose usage was counted, and what it added, so that a message cut
        /// in two by a split between pieces of one file is counted once when they are joined.
        var firstUsage: (id: String, fresh: Int, cached: Int, output: Int)?

        /// Joins what the next piece of the same file found onto this one.
        mutating func append(_ next: Accumulator) {
            if cwd == nil { cwd = next.cwd }
            customTitle = next.customTitle ?? customTitle
            aiTitle = next.aiTitle ?? aiTitle
            lastPrompt = next.lastPrompt ?? lastPrompt
            if firstPrompt == nil { firstPrompt = next.firstPrompt }
            if firstTimestamp == nil { firstTimestamp = next.firstTimestamp }
            if let last = next.lastTimestamp { lastTimestamp = max(lastTimestamp ?? 0, last) }
            if entrypoint == nil { entrypoint = next.entrypoint }
            branch = next.branch ?? branch
            prURL = next.prURL ?? prURL
            prNumber = next.prNumber ?? prNumber
            promptCount += next.promptCount
            inputTokens += next.inputTokens
            cachedTokens += next.cachedTokens
            outputTokens += next.outputTokens
            if let repeated = next.firstUsage, repeated.id == lastUsageMessageID {
                inputTokens -= repeated.fresh
                cachedTokens -= repeated.cached
                outputTokens -= repeated.output
            }
            contextTokens = next.contextTokens ?? contextTokens
            model = next.model ?? model
            if firstUsage == nil { firstUsage = next.firstUsage }
            lastUsageMessageID = next.lastUsageMessageID ?? lastUsageMessageID
        }
    }

    /// What reading one transcript produced, before any of it is written.
    private struct Parsed {
        let file: FileEntry
        let offset: Int
        let isKnown: Bool
        var accumulator = Accumulator()
        var messages: [(role: String, text: String, timestamp: Double?)] = []
        var consumed = 0
    }

    /// How many transcripts are read at once. Each is held in memory while it is parsed.
    private static let parallelism = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

    /// - Parameters:
    ///   - progress: called with how many of the changed transcripts are done, and how many there are.
    ///   - written: called after each batch is saved, so the list can show what is there so far.
    @discardableResult
    func run(progress: ((Int, Int) -> Void)? = nil, written: (() -> Void)? = nil) -> IndexStats {
        var stats = IndexStats()
        // A folder that cannot be read (an external disk that is not mounted, say) is not the
        // same as a folder whose transcripts were deleted: the index is left as it is.
        guard let files = discover() else {
            stats.unreachable = true
            return stats
        }
        stats.total = files.count

        var known: [String: Known] = [:]
        try? db.query("SELECT id, path, file_size, file_mtime, indexed_offset FROM sessions") { row in
            guard let id = row.text(0), let path = row.text(1) else { return }
            known[id] = Known(path: path, size: row.int(2), mtime: row.double(3) ?? 0, offset: row.int(4))
        }

        // The most recently written first, so the sessions in use show up before the old ones.
        // Very large transcripts go before all of them: one started last would keep a single
        // core busy long after the rest were done.
        let pending = files
            .filter { file in
                guard let old = known[file.id] else { return true }
                return old.path != file.path || old.size != file.size || abs(old.mtime - file.mtime) > 0.001
            }
            .sorted { first, second in
                let big = 24 * 1024 * 1024
                if (first.size > big) != (second.size > big) { return first.size > big }
                return first.size > big ? first.size > second.size : first.mtime > second.mtime
            }

        // Transcripts are parsed side by side on every core, each as soon as a core is free,
        // and handed to one writer, since the database takes one writer. The writer saves them
        // a handful at a time, each handful in one transaction.
        let writer = DispatchQueue(label: "respool.index.writer")
        let workers = DispatchQueue(label: "respool.index.parse", qos: .userInitiated, attributes: .concurrent)
        let slots = DispatchSemaphore(value: Self.parallelism)
        let group = DispatchGroup()
        var waiting: [Parsed] = []
        var done = 0
        var lastFlush = Date()

        func flush() {
            guard !waiting.isEmpty else { return }
            do {
                try db.exec("BEGIN IMMEDIATE")
                for result in waiting {
                    stats.messages += try write(result)
                    stats.updated += 1
                }
                try db.exec("COMMIT")
            } catch {
                try? db.exec("ROLLBACK")
            }
            waiting.removeAll()
            lastFlush = Date()
            written?()
        }

        progress?(0, pending.count)
        for file in pending {
            slots.wait()
            group.enter()
            let old = known[file.id]
            let canAppend = old.map { $0.path == file.path && $0.offset > 0 && file.size >= $0.offset } ?? false
            workers.async {
                let result = try? Self.parse(file, from: canAppend ? old!.offset : 0, isKnown: old != nil)
                slots.signal()
                writer.async {
                    if let result { waiting.append(result) }
                    done += 1
                    progress?(done, pending.count)
                    // Often enough at first that the list fills quickly, then in larger handfuls.
                    if waiting.count >= 24 || Date().timeIntervalSince(lastFlush) > 0.6 { flush() }
                    group.leave()
                }
            }
        }
        group.wait()
        writer.sync { flush() }
        if !pending.isEmpty { progress?(pending.count, pending.count) }

        // A folder that suddenly holds nothing at all is more likely an empty mount point than
        // every session deleted at once; nothing is removed then either.
        let present = Set(files.map(\.id))
        let gone = known.keys.filter { !present.contains($0) }
        if !(files.isEmpty && !known.isEmpty) {
            for id in gone {
                _ = try? db.run("DELETE FROM messages WHERE session_id = ?", [id])
                _ = try? db.run("DELETE FROM sessions WHERE id = ?", [id])
                stats.removed += 1
            }
        }
        return stats
    }

    /// The transcripts on disk, or nil when their folder cannot be read at all.
    private func discover() -> [FileEntry]? {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var best: [String: FileEntry] = [:]
        guard let folders = try? manager.contentsOfDirectory(at: Paths.transcripts, includingPropertiesForKeys: nil) else {
            return nil
        }
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

    /// Reads a transcript from `offset` and keeps what the index needs. Touches no database,
    /// so several run at once.
    private static func parse(_ file: FileEntry, from offset: Int, isKnown: Bool) throws -> Parsed {
        var result = Parsed(file: file, offset: offset, isKnown: isKnown)
        var accumulator = Accumulator()
        var messages: [(role: String, text: String, timestamp: Double?)] = []
        result.consumed = try parse(path: file.path, from: offset, into: &accumulator) { role, text, timestamp in
            messages.append((role, String(text.prefix(Self.maxTextLength)), timestamp))
        }
        result.accumulator = accumulator
        result.messages = messages
        return result
    }

    /// Saves one parsed transcript. Runs inside the batch's transaction.
    private func write(_ parsed: Parsed) throws -> Int {
        let file = parsed.file
        let accumulator = parsed.accumulator
        let consumed = parsed.consumed
        if parsed.offset == 0, parsed.isKnown {
            try db.run("DELETE FROM messages WHERE session_id = ?", [file.id])
            try db.run("DELETE FROM sessions WHERE id = ?", [file.id])
        }
        let insert = try db.prepared("INSERT INTO messages(text, session_id, role, ts) VALUES(?, ?, ?, ?)")
        for message in parsed.messages {
            try insert.run([message.text, file.id, message.role, message.timestamp])
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
        return parsed.messages.count
    }

    // MARK: - Parsing

    private static let metaPrefix = Array(#"{"type":""#.utf8)
    private static let userMarker = Array(#""type":"user""#.utf8)
    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let wantedMeta: Set<String> = ["custom-title", "ai-title", "last-prompt", "pr-link"]
    private static let toolResultMarker = Array(#""type":"tool_result""#.utf8)
    private static let textPartMarker = Array(#""type":"text""#.utf8)
    private static let timestampMarker = Array(#""timestamp":""#.utf8)

    /// The line's own time. Claude Code writes it after the message, so the last one in the
    /// line is taken: an earlier one would belong to text a tool printed.
    private static func timestamp(in pointer: UnsafeRawPointer, _ length: Int) -> Double? {
        let marker = timestampMarker
        var found: Int?
        var position = 0
        while position < length,
              let hit = memmem(pointer + position, length - position, marker, marker.count) {
            found = pointer.distance(to: UnsafeRawPointer(hit)) + marker.count
            position = found!
        }
        guard let start = found, start + 24 <= length else { return nil }
        let text = String(decoding: UnsafeRawBufferPointer(start: pointer + start, count: 24), as: UTF8.self)
        return parseTimestamp(text)
    }

    /// Returns the byte offset up to which complete lines were consumed.
    ///
    /// The part from `start` on is read in one go rather than mapped: on an external disk,
    /// faulting a mapped file in page by page is several times slower than one long read.
    private static func parse(
        path: String,
        from start: Int,
        into accumulator: inout Accumulator,
        emit: (String, String, Double?) throws -> Void
    ) throws -> Int {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        if start > 0 { try handle.seek(toOffset: UInt64(start)) }
        let data = try handle.readToEnd() ?? Data()
        let count = data.count
        guard count > 0 else { return start }
        var consumed = start

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            // A large file is cut at line breaks into pieces read side by side, then joined.
            let pieces = count > Self.splitSize ? Self.parallelism : 1
            var bounds = [0]
            for piece in 1..<pieces {
                let guess = count * piece / pieces
                guard guess > bounds.last!, let newline = memchr(base + guess, 0x0A, count - guess) else { continue }
                bounds.append(base.distance(to: UnsafeRawPointer(newline)) + 1)
            }
            bounds.append(count)
            if bounds.count == 2 {
                let end = try scan(base, from: 0, to: count, &accumulator, emit)
                consumed = start + end
                return
            }
            var results = [(Accumulator, [(String, String, Double?)], Int)?](repeating: nil, count: bounds.count - 1)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: bounds.count - 1) { piece in
                var part = Accumulator()
                var found: [(String, String, Double?)] = []
                let end = try? scan(base, from: bounds[piece], to: bounds[piece + 1], &part) { found.append(($0, $1, $2)) }
                lock.lock()
                results[piece] = (part, found, end ?? bounds[piece])
                lock.unlock()
            }
            for result in results {
                guard let (part, found, end) = result else { continue }
                accumulator.append(part)
                for message in found { try emit(message.0, message.1, message.2) }
                consumed = start + end
            }
        }
        return consumed
    }

    /// Files larger than this are read in pieces on several cores.
    private static let splitSize = 12 * 1024 * 1024

    /// Reads the whole lines between two offsets. Returns where the last complete line ended.
    private static func scan(
        _ base: UnsafeRawPointer, from first: Int, to last: Int,
        _ accumulator: inout Accumulator,
        _ emit: (String, String, Double?) throws -> Void
    ) throws -> Int {
        var position = first
        var consumed = first
        while position < last {
            guard let newline = memchr(base + position, 0x0A, last - position) else { break }
            let end = base.distance(to: UnsafeRawPointer(newline))
            let length = end - position
            if length > 2, length <= maxLineBytes {
                try handleLine(base + position, length, &accumulator, emit)
            }
            position = end + 1
            consumed = position
        }
        return consumed
    }

    private static func handleLine(
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
            let isUser = memmem(pointer, length, Self.userMarker, Self.userMarker.count) != nil
            let isMessage = isUser || memmem(pointer, length, Self.assistantMarker, Self.assistantMarker.count) != nil
            guard isMessage else { return }
            // What a tool printed comes back as a user line, often a very long one, with nothing in
            // it the index keeps but its time. That is read off the bytes instead of decoding it all.
            if isUser, memmem(pointer, length, Self.toolResultMarker, Self.toolResultMarker.count) != nil,
               memmem(pointer, length, Self.textPartMarker, Self.textPartMarker.count) == nil {
                if let timestamp = Self.timestamp(in: pointer, length) {
                    if accumulator.firstTimestamp == nil { accumulator.firstTimestamp = timestamp }
                    accumulator.lastTimestamp = max(accumulator.lastTimestamp ?? 0, timestamp)
                }
                return
            }
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

    private static func handleMessage(
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
    private static func recordUsage(_ message: [String: Any], _ accumulator: inout Accumulator) {
        guard let usage = message["usage"] as? [String: Any], let id = message["id"] as? String,
              id != accumulator.lastUsageMessageID else { return }
        accumulator.lastUsageMessageID = id
        let fresh = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        let cached = usage["cache_read_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        if accumulator.firstUsage == nil { accumulator.firstUsage = (id, fresh, cached, output) }
        accumulator.inputTokens += fresh
        accumulator.cachedTokens += cached
        accumulator.outputTokens += output
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
