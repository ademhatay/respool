import Foundation

struct ProjectIdentity: Hashable {
    let key: String
    let name: String
    /// False when the folder was missing (for example an unmounted volume) and should be retried.
    let durable: Bool
}

/// Works out which logical project a working directory belongs to, so the same repository
/// checked out in several folders shows up as one project.
enum ProjectResolver {
    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    static func resolve(cwd: String) -> ProjectIdentity {
        var folder = cwd
        if let range = folder.range(of: "/.claude/worktrees/") {
            folder = String(folder[..<range.lowerBound])
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
        guard exists else { return fallback(folder, durable: false) }

        if let remote = git(["-C", folder, "config", "--get", "remote.origin.url"]), let slug = slug(fromRemote: remote) {
            let name = slug.split(separator: "/").last.map(String.init) ?? slug
            return ProjectIdentity(key: "git:" + slug.lowercased(), name: name, durable: true)
        }
        if let top = git(["-C", folder, "rev-parse", "--show-toplevel"]), !top.isEmpty {
            return fallback(top, durable: true)
        }
        return fallback(folder, durable: true)
    }

    static func fallback(_ folder: String, durable: Bool) -> ProjectIdentity {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return ProjectIdentity(key: "name:" + normalize(name), name: name.isEmpty ? folder : name, durable: durable)
    }

    /// `git@github.com:Org/repo.git` and `https://github.com/Org/repo.git` both become `Org/repo`.
    static func slug(fromRemote remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }

    private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Resolves every working directory the index has seen and caches the answer.
    static func refresh(db: Database) {
        var cached: [String: Bool] = [:]
        try? db.query("SELECT cwd, durable FROM cwd_projects") { row in
            if let cwd = row.text(0) { cached[cwd] = row.int(1) == 1 }
        }
        var folders: [String] = []
        try? db.query("SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL") { row in
            if let cwd = row.text(0) { folders.append(cwd) }
        }
        for cwd in folders where cached[cwd] != true {
            let identity = resolve(cwd: cwd)
            _ = try? db.run(
                "INSERT OR REPLACE INTO cwd_projects(cwd, key, name, durable) VALUES(?, ?, ?, ?)",
                [cwd, identity.key, identity.name, identity.durable]
            )
        }
    }
}
