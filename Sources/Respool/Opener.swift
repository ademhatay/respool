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
        /// The project was opened in an editor and the command to resume is on the clipboard.
        case openedInEditor
    }

    /// Opens a session where it lives: a session the desktop app tracks opens there, a session
    /// running in a terminal brings that terminal forward, and any other is resumed in a new one.
    ///
    /// A method other than the automatic one sends a session that is not running to the app it
    /// names. A running session is never resumed a second time, so it always opens where it runs.
    static func open(
        _ session: SessionRecord, method: OpenMethod = .automatic, live: LiveSession?, desktopID: String?,
        completion: @escaping (Outcome) -> Void
    ) {
        if let live, live.isInTerminal {
            LiveSessions.activateHost(of: live.pid)
            completion(.alreadyInTerminal)
            return
        }
        if live != nil {
            openInDesktop(session, desktopID: desktopID, completion: completion)
            return
        }
        switch method {
        case .automatic:
            if desktopID != nil {
                openInDesktop(session, desktopID: desktopID, completion: completion)
            } else {
                completion(openInTerminal(session) ? .opened : .failed)
            }
        case .desktop:
            openInDesktop(session, desktopID: desktopID, completion: completion)
        case .terminal, .iterm:
            completion(openInTerminal(session, with: method) ? .opened : .failed)
        case .vscode, .cursor, .zed:
            let folder = workingDirectory(for: session)
            guard openFolder(folder, in: method) else {
                completion(.failed)
                return
            }
            runBesideEditor(command(cd: folder.path, "claude --resume \(session.id)"), in: method) { ran in
                completion(ran || openInTerminal(session, with: companionTerminal) ? .openedInEditor : .failed)
            }
        }
    }

    private static func application(for method: OpenMethod) -> URL? {
        method.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Opens a file or folder with the app a method names. False when that app is not installed.
    private static func open(_ url: URL, with method: OpenMethod) -> Bool {
        guard let app = application(for: method) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static func openFolder(_ folder: URL, in editor: OpenMethod) -> Bool {
        open(folder, with: editor)
    }

    /// Set from Settings: run a chat opened with an editor in the editor's own terminal.
    static var usesEditorTerminal = false

    /// Runs a command in the editor's terminal when that is chosen and allowed. Calls back with
    /// false when it was not done, so the caller falls back to a terminal beside the editor.
    private static func runBesideEditor(_ command: String, in editor: OpenMethod, completion: @escaping (Bool) -> Void) {
        guard usesEditorTerminal else {
            completion(false)
            return
        }
        guard EditorTerminal.isAllowed else {
            EditorTerminal.askForPermission()
            completion(false)
            return
        }
        EditorTerminal.run(command, in: editor, completion: completion)
    }

    private static func command(cd folder: String, _ command: String) -> String {
        "cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "' && " + command
    }

    /// The terminal a chat runs in when it is opened with an editor: iTerm when it is there.
    static var companionTerminal: OpenMethod {
        application(for: .iterm) != nil ? .iterm : .terminal
    }

    /// The app a way of opening ends up in, for showing its icon.
    static func appURL(for method: OpenMethod) -> URL? {
        if method == .desktop {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
        }
        return application(for: method == .automatic ? .terminal : method)
    }

    /// Set from Settings: resume in a new tab of iTerm's front window rather than a new window.
    static var usesTabs = true

    /// Runs a script in the terminal a method names, or in the one that opens scripts by default.
    private static func run(_ script: URL, with method: OpenMethod?) -> Bool {
        if method == .iterm, usesTabs, application(for: .iterm) != nil {
            runInTab(script)
            return true
        }
        if let method, method.bundleID != nil { return open(script, with: method) }
        return NSWorkspace.shared.open(script)
    }

    static let tabScript = """
    on run argv
        set scriptPath to item 1 of argv
        tell application "iTerm"
            activate
            if (count of windows) is 0 then
                create window with default profile command scriptPath
            else
                tell current window to create tab with default profile command scriptPath
            end if
        end tell
    end run
    """

    /// Asks iTerm for a new tab that runs the script. Terminal has no such command, so this is
    /// iTerm's alone. If iTerm will not be scripted (the user said no when macOS asked), the
    /// script opens in a new window instead.
    private static func runInTab(_ script: URL) {
        // iTerm splits its command at spaces, so the script is run from a path that has none.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("respool-" + script.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: script, to: copy)) != nil, !copy.path.contains(" ") else {
            _ = open(script, with: .iterm)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", tabScript, copy.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            DispatchQueue.main.async { _ = open(script, with: .iterm) }
        }
        if (try? process.run()) == nil { _ = open(script, with: .iterm) }
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

    /// Resumes the session in a new terminal window.
    @discardableResult
    static func openInTerminal(_ session: SessionRecord, with method: OpenMethod? = nil) -> Bool {
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
        return run(url, with: method)
    }

    /// Starts a new Claude Code session in a folder, with the given text as its first prompt
    /// or with none to type when it is blank. An editor opens the folder instead and the
    /// command is left on the clipboard.
    @discardableResult
    static func startSession(in folder: String, prompt: String, method: OpenMethod = .automatic) -> Bool {
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let argument = trimmed.isEmpty ? "" : " " + quoted(trimmed)
        let editor = method.isEditor ? method : nil
        if let editor, !openFolder(URL(fileURLWithPath: folder), in: editor) { return false }
        if let editor, usesEditorTerminal, EditorTerminal.isAllowed {
            EditorTerminal.run(command(cd: folder, "claude" + argument), in: editor) { _ in }
            return true
        }
        if editor != nil, usesEditorTerminal { EditorTerminal.askForPermission() }
        let script = """
        #!/bin/zsh -l
        cd \(quoted(folder))
        exec claude\(argument)

        """
        let url = Paths.support.appendingPathComponent("start.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return false
        }
        if editor != nil { return run(url, with: companionTerminal) }
        return run(url, with: method == .desktop ? nil : method)
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
        if name.hasSuffix("'s Organization") || name.hasSuffix("’s Organization") { return (id, L10n.personal) }
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
