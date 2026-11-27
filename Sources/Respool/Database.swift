import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible {
    let description: String
}

/// A thin wrapper over one SQLite connection. Each connection is used from a single queue.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw DBError(description: message)
        }
        sqlite3_busy_timeout(handle, 8000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw DBError(description: message)
        }
    }

    func prepared(_ sql: String) throws -> Prepared {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        return Prepared(statement: statement, owner: self)
    }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        let statement = try prepared(sql)
        try statement.run(params)
    }

    func query(_ sql: String, _ params: [Any?] = [], _ body: (Row) -> Void) throws {
        let statement = try prepared(sql)
        try statement.each(params, body)
    }

    fileprivate func lastError() -> DBError {
        DBError(description: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }
}

final class Prepared {
    private let statement: OpaquePointer
    private unowned let owner: Database

    fileprivate init(statement: OpaquePointer, owner: Database) {
        self.statement = statement
        self.owner = owner
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func run(_ params: [Any?] = []) throws {
        sqlite3_reset(statement)
        bind(params)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw owner.lastError() }
    }

    func each(_ params: [Any?] = [], _ body: (Row) -> Void) throws {
        sqlite3_reset(statement)
        bind(params)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                body(Row(statement: statement))
            } else if code == SQLITE_DONE {
                return
            } else {
                throw owner.lastError()
            }
        }
    }

    private func bind(_ params: [Any?]) {
        sqlite3_clear_bindings(statement)
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil:
                sqlite3_bind_null(statement, index)
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int64:
                sqlite3_bind_int64(statement, index, number)
            case let number as Double:
                sqlite3_bind_double(statement, index, number)
            case let flag as Bool:
                sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case let date as Date:
                sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            default:
                sqlite3_bind_null(statement, index)
            }
        }
    }
}

struct Row {
    fileprivate let statement: OpaquePointer

    func text(_ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func optionalInt(_ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(index)
    }

    func double(_ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    func date(_ index: Int32) -> Date? {
        double(index).map { Date(timeIntervalSince1970: $0) }
    }
}

enum Schema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS sessions(
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        cwd TEXT,
        custom_title TEXT,
        ai_title TEXT,
        last_prompt TEXT,
        first_prompt TEXT,
        first_ts REAL,
        last_ts REAL,
        entrypoint TEXT,
        branch TEXT,
        pr_url TEXT,
        pr_number INTEGER,
        msg_count INTEGER NOT NULL DEFAULT 0,
        file_size INTEGER NOT NULL DEFAULT 0,
        file_mtime REAL NOT NULL DEFAULT 0,
        indexed_offset INTEGER NOT NULL DEFAULT 0,
        tok_input INTEGER NOT NULL DEFAULT 0,
        tok_cached INTEGER NOT NULL DEFAULT 0,
        tok_output INTEGER NOT NULL DEFAULT 0,
        context_tokens INTEGER,
        model TEXT
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
        text, session_id UNINDEXED, role UNINDEXED, ts UNINDEXED,
        tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TABLE IF NOT EXISTS cwd_projects(
        cwd TEXT PRIMARY KEY, key TEXT NOT NULL, name TEXT NOT NULL, durable INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS pins(session_id TEXT PRIMARY KEY, position REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS notes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        created REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        created REAL NOT NULL,
        done_at REAL,
        bucket TEXT,
        due TEXT,
        project_key TEXT,
        position REAL
    );
    CREATE TABLE IF NOT EXISTS project_names(key TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS project_merges(key TEXT PRIMARY KEY, target TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS tags(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        color INTEGER NOT NULL DEFAULT 4
    );
    CREATE TABLE IF NOT EXISTS session_tags(
        session_id TEXT NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY(session_id, tag_id)
    );
    CREATE TABLE IF NOT EXISTS organization_names(id TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS time_entries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_key TEXT NOT NULL,
        started REAL NOT NULL,
        ended REAL NOT NULL,
        open INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS project_open(key TEXT PRIMARY KEY, method TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS session_hosts(session_id TEXT PRIMARY KEY, method TEXT NOT NULL, seen REAL NOT NULL);
    """
}

extension Schema {
    static let version = 2

    /// Brings an index written by an older version up to date. The index only mirrors the
    /// transcripts, so it is rebuilt rather than converted; pins, tasks and tags are kept.
    static func migrate(_ db: Database) throws {
        var current = 0
        try db.query("PRAGMA user_version") { row in current = row.int(0) }
        guard current < version else { return }
        for column in [
            "tok_input INTEGER NOT NULL DEFAULT 0", "tok_cached INTEGER NOT NULL DEFAULT 0",
            "tok_output INTEGER NOT NULL DEFAULT 0", "context_tokens INTEGER", "model TEXT",
        ] {
            _ = try? db.exec("ALTER TABLE sessions ADD COLUMN \(column)")
        }
        try db.exec("DELETE FROM sessions; DELETE FROM messages; PRAGMA user_version = \(version);")
    }

    /// Adds columns that later versions introduced to tables holding the user's own data.
    static func addColumns(_ db: Database) {
        _ = try? db.exec("ALTER TABLE tasks ADD COLUMN bucket TEXT")
        _ = try? db.exec("ALTER TABLE tasks ADD COLUMN due TEXT")
        _ = try? db.exec("ALTER TABLE tasks ADD COLUMN project_key TEXT")
        _ = try? db.exec("ALTER TABLE tasks ADD COLUMN position REAL")
        // Version 0.4 filed to-dos under "today" or "this week"; they become dated or undated.
        _ = try? db.run("UPDATE tasks SET due = ? WHERE bucket = 'today' AND due IS NULL", [Format.dayKey(Date())])
        _ = try? db.exec("UPDATE tasks SET bucket = NULL WHERE bucket IS NOT NULL")
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let transcripts = home.appendingPathComponent(".claude/projects", isDirectory: true)

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Respool", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `RESPOOL_DB` points the app at another index file, which the self-test uses.
    static var database: String {
        ProcessInfo.processInfo.environment["RESPOOL_DB"] ?? support.appendingPathComponent("respool.db").path
    }
}
