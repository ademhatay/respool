import AppKit
import Carbon.HIToolbox

/// A key combination that opens the panel from anywhere.
struct Shortcut: Equatable {
    var keyCode: Int
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: Int
    var label: String

    static let standard = Shortcut(keyCode: kVK_Space, modifiers: optionKey | shiftKey, label: "⌥⇧Space")

    /// Opens the panel on the task field.
    static let quickTask = Shortcut(keyCode: kVK_ANSI_T, modifiers: optionKey | shiftKey, label: "⌥⇧T")
    /// Opens the panel on the note field.
    static let quickNote = Shortcut(keyCode: kVK_ANSI_N, modifiers: optionKey | shiftKey, label: "⌥⇧N")

    /// The shortcut saved under a name, or the fallback when none was ever recorded.
    static func saved(as name: String, fallback: Shortcut) -> Shortcut {
        let defaults = UserDefaults.standard
        guard let label = defaults.string(forKey: name + "Label"), !label.isEmpty else { return fallback }
        return Shortcut(
            keyCode: defaults.integer(forKey: name + "KeyCode"),
            modifiers: defaults.integer(forKey: name + "Modifiers"),
            label: label
        )
    }

    func save(as name: String) {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: name + "KeyCode")
        defaults.set(modifiers, forKey: name + "Modifiers")
        defaults.set(label, forKey: name + "Label")
    }

    /// Builds a shortcut from a key press, or nil when it has no ⌘, ⌥ or ⌃ and would
    /// swallow ordinary typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        var mask = 0
        var symbols = ""
        if flags.contains(.control) { mask |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { mask |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { mask |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { mask |= cmdKey; symbols += "⌘" }
        self.init(keyCode: Int(event.keyCode), modifiers: mask, label: symbols + Self.keyName(for: event))
    }

    init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(for event: NSEvent) -> String {
        if let name = namedKeys[Int(event.keyCode)] { return name }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty ? "?" : characters
    }
}

/// Which of the app's system-wide shortcuts a hot key is. The raw value names its saved settings.
enum ShortcutKind: String, CaseIterable {
    case panel = "shortcut"
    case quickTask = "taskShortcut"
    case quickNote = "noteShortcut"

    var fallback: Shortcut {
        switch self {
        case .panel: return .standard
        case .quickTask: return .quickTask
        case .quickNote: return .quickNote
        }
    }

    fileprivate var identifier: UInt32 {
        switch self {
        case .panel: return 1
        case .quickTask: return 2
        case .quickNote: return 3
        }
    }
}

/// Registers one of the app's system-wide shortcuts. Uses the Carbon hot key API, which needs no
/// permission prompt.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private(set) var shortcut: Shortcut
    private(set) var isRegistered = false
    let kind: ShortcutKind

    init(_ kind: ShortcutKind = .panel, action: @escaping () -> Void) {
        self.kind = kind
        self.action = action
        shortcut = Shortcut.saved(as: kind.rawValue, fallback: kind.fallback)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Every hot key's handler sees every press, so each answers only to its own.
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                guard pressed.id == hotKey.kind.identifier else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { hotKey.action() }
                return noErr
            },
            1, &spec, context, &handlerRef
        )
        register()
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    @discardableResult
    func register() -> Bool {
        unregister()
        let identifier = EventHotKeyID(signature: OSType(0x5253_504C), id: kind.identifier)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), identifier,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        isRegistered = status == noErr
        return isRegistered
    }

    /// Stops listening, so the current combination can be pressed while recording a new one.
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isRegistered = false
    }

    /// Switches to a new shortcut, keeping the old one if the system refuses the new one.
    func change(to new: Shortcut) -> Bool {
        let previous = shortcut
        shortcut = new
        if register() {
            new.save(as: kind.rawValue)
            return true
        }
        shortcut = previous
        register()
        return false
    }
}
