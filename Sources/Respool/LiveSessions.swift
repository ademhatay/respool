import AppKit

/// A session that has a running Claude Code process right now.
struct LiveSession: Hashable {
    enum State: Hashable {
        case working
        case waiting
        case idle
    }

    let pid: Int32
    let state: State
    /// What the session is waiting for, when Claude Code says so (for example a permission).
    let waitingFor: String?
    /// Set when the session runs inside the Claude desktop app.
    let desktopID: String?

    var isInTerminal: Bool { desktopID == nil }

    var label: String {
        switch state {
        case .working: return L10n.working
        case .waiting: return L10n.waiting
        case .idle: return L10n.idle
        }
    }
}

/// Reads the registry Claude Code keeps of its running sessions (`~/.claude/sessions/<pid>.json`).
/// The format is internal to Claude Code, so everything here is read defensively.
enum LiveSessions {
    private static let folder = Paths.home.appendingPathComponent(".claude/sessions", isDirectory: true)

    static func load() -> [String: LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var live: [String: LiveSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["sessionId"] as? String,
                  let pid = object["pid"] as? Int,
                  isRunning(Int32(pid)) else { continue }
            let state: LiveSession.State
            switch object["status"] as? String {
            case "busy": state = .working
            case "waiting": state = .waiting
            default: state = .idle
            }
            live[sessionID] = LiveSession(
                pid: Int32(pid),
                state: state,
                waitingFor: object["waitingFor"] as? String,
                desktopID: object["hostSessionId"] as? String
            )
        }
        return live
    }

    /// The app whose window hosts the process (Terminal, iTerm, an editor).
    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 {
            guard let parent = parent(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                return app
            }
            current = parent
        }
        return nil
    }

    /// Brings that app forward.
    @discardableResult
    static func activateHost(of pid: Int32) -> Bool {
        hostApp(of: pid)?.activate() ?? false
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
