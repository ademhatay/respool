import AppKit

/// Hands a session back to Claude. Respool never edits transcripts; it only asks Claude to resume them.
enum Opener {
    static let claudePath: String? = {
        let home = Paths.home.path
        let candidates = [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.claude/local/claude",
            home + "/.npm-global/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return shell("command -v claude")
    }()

    enum Outcome {
        case opened
        case failed
        /// The session is running in a terminal, so that terminal was brought forward instead.
        case alreadyInTerminal
    }

    /// Opens a session where it lives: a session the desktop app tracks opens there, a session
    /// running in a terminal brings that terminal forward, and any other is resumed in a new one.
    static func open(_ session: SessionRecord, live: LiveSession?, desktopID: String?, completion: @escaping (Outcome) -> Void) {
        if let live, live.isInTerminal {
            LiveSessions.activateHost(of: live.pid)
            completion(.alreadyInTerminal)
        } else if desktopID != nil {
            openInDesktop(session, desktopID: desktopID, completion: completion)
        } else {
            completion(openInTerminal(session) ? .opened : .failed)
        }
    }

    /// Opens the session in the Claude desktop app.
    ///
    /// A session the desktop app already tracks is opened through its own link. Any other session
    /// is handed over with `claude --desktop --resume <id>`, which only runs attached to a terminal,
    /// so it is started under a pseudo-terminal.
    static func openInDesktop(_ session: SessionRecord, desktopID: String?, completion: @escaping (Outcome) -> Void) {
        if let desktopID, let url = URL(string: "claude://claude.ai/epitaxy/" + desktopID), NSWorkspace.shared.open(url) {
            completion(.opened)
            return
        }
        guard let claudePath else {
            completion(.failed)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", claudePath, "--desktop", "--resume", session.id]
        process.currentDirectoryURL = workingDirectory(for: session)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            DispatchQueue.main.async { completion(finished.terminationStatus == 0 ? .opened : .failed) }
        }
        do {
            try process.run()
        } catch {
            completion(.failed)
        }
    }

    /// Resumes the session in a new Terminal window.
    @discardableResult
    static func openInTerminal(_ session: SessionRecord) -> Bool {
        let folder = workingDirectory(for: session).path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/zsh -l
        cd '\(folder)'
        exec claude --resume \(session.id)

        """
        let url = Paths.support.appendingPathComponent("resume.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    static func revealFolder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func workingDirectory(for session: SessionRecord) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: session.cwd)
        }
        return Paths.home
    }

    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}

/// The organization Claude Code is signed in to, which is the only place its name is written down.
enum ClaudeAccount {
    static func organization() -> (id: String, name: String)? {
        let url = Paths.home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any],
              let id = account["organizationUuid"] as? String,
              let name = account["organizationName"] as? String, !name.isEmpty else { return nil }
        // A personal plan is stored as "<email>'s Organization"; show that as a plain label instead.
        if name.hasSuffix("'s Organization") || name.hasSuffix("’s Organization") { return (id, "Kişisel") }
        return (id, name)
    }
}

/// Reads which sessions the Claude desktop app already tracks, so they can be opened by link.
enum DesktopSessions {
    private static let root = Paths.home
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    private static let localPattern = try! Regex(#""sessionId"\s*:\s*"(local_[0-9a-f-]+)""#)
    private static let cliPattern = try! Regex(#""cliSessionId"\s*:\s*"([0-9a-f-]{36})""#)

    struct Record: Hashable {
        let desktopID: String
        let organization: String
    }

    struct Index {
        var records: [String: Record] = [:]
        /// The organization the desktop app last wrote to, taken as the one it is signed in to.
        var currentOrganization: String?
    }

    /// Maps a transcript's session id to the desktop app's record of the same session.
    static func load() -> Index {
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        var index = Index()
        var newest = Date.distantPast
        for account in children(root) {
            for organization in children(account) {
                for file in children(organization)
                where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
                    guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                    let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
                    try? handle.close()
                    guard let local = head.firstMatch(of: localPattern)?.output[1].substring,
                          let cli = head.firstMatch(of: cliPattern)?.output[1].substring else { continue }
                    index.records[String(cli)] = Record(
                        desktopID: String(local), organization: organization.lastPathComponent
                    )
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if modified > newest {
                        newest = modified
                        index.currentOrganization = organization.lastPathComponent
                    }
                }
            }
        }
        return index
    }
}
