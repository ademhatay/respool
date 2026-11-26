import AppKit
import Foundation

/// How long Claude Code keeps a session's transcript, and where Respool puts copies of the ones
/// that are about to go.
///
/// Claude Code deletes the transcript of a terminal session it has not written to for
/// `cleanupPeriodDays` days, thirty by default, the next time it starts. Sessions the desktop
/// app keeps are not cleaned up that way.
enum Retention {
    /// Days a transcript is kept after it was last written. `cleanupPeriodDays` in Claude Code's
    /// own settings; thirty unless the file says otherwise. Settings an organization serves are
    /// not read, so they can lengthen this without Respool knowing.
    static let days: Int = {
        let url = Paths.home.appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let days = object["cleanupPeriodDays"] as? Int, days >= 1 {
            return days
        }
        return 30
    }()

    /// A session counts as about to go during this many days before the limit.
    static let warningWindow = 7

    /// Beside the index. The self-test names another index, and gets its own folder with it.
    static let folder: URL = {
        if ProcessInfo.processInfo.environment["RESPOOL_DB"] != nil {
            return URL(fileURLWithPath: Paths.database).deletingLastPathComponent().appendingPathComponent("Respool Backups")
        }
        return Paths.support.appendingPathComponent("Backups", isDirectory: true)
    }()

    static func backupURL(for session: SessionRecord) -> URL {
        folder.appendingPathComponent(session.id + ".jsonl")
    }

    static func isBackedUp(_ session: SessionRecord) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(for: session).path)
    }

    /// Copies a session's transcript into the backups folder, over an older copy if there is one.
    /// False when no copy is there afterwards.
    static func backUp(_ session: SessionRecord) -> Bool {
        let manager = FileManager.default
        let destination = backupURL(for: session)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: URL(fileURLWithPath: session.path), to: destination)
            return true
        } catch {
            return false
        }
    }
}
