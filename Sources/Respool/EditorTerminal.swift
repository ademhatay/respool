import AppKit
import ApplicationServices

/// Runs a command in an editor's own terminal. Editors take no such command from outside, so
/// this does what a person would: brings the editor forward, asks its command palette for a
/// new terminal, and pastes the command there. It needs the Accessibility permission, which
/// macOS asks the user for once.
enum EditorTerminal {
    /// True when macOS lets Respool send keys to other apps.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own request for the permission, and opens the right pane of System Settings.
    static func askForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// What to type into the editor's command palette for a new terminal.
    private static func paletteCommand(for editor: OpenMethod) -> String? {
        switch editor {
        case .zed: return "workspace: new terminal"
        case .vscode, .cursor: return "Terminal: Create New Terminal"
        default: return nil
        }
    }

    /// Waits for the editor to come forward with the folder open, then runs `command` in a new
    /// terminal there. Calls `completion` with false when the editor never came forward.
    static func run(_ command: String, in editor: OpenMethod, completion: @escaping (Bool) -> Void) {
        guard let palette = paletteCommand(for: editor), let bundleID = editor.bundleID else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // The editor is ready once it is in front; a window that is still opening needs a moment more.
            var waited = 0.0
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID, waited < 10 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            guard waited < 10 else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            Thread.sleep(forTimeInterval: waited > 0.5 ? 1.2 : 0.4)

            let saved = DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) }
            func paste(_ text: String) {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                press(Key.v, flags: .maskCommand)
            }
            press(Key.p, flags: [.maskCommand, .maskShift])
            Thread.sleep(forTimeInterval: 0.45)
            paste(palette)
            Thread.sleep(forTimeInterval: 0.35)
            press(Key.enter)
            // The shell in the new terminal needs a moment to start before it reads anything.
            Thread.sleep(forTimeInterval: 1.0)
            paste(command)
            Thread.sleep(forTimeInterval: 0.2)
            press(Key.enter)
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                if let saved { NSPasteboard.general.setString(saved, forType: .string) }
                completion(true)
            }
        }
    }

    /// Key codes, which are the same whatever the keyboard layout.
    private enum Key {
        static let p: CGKeyCode = 35
        static let v: CGKeyCode = 9
        static let enter: CGKeyCode = 36
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
