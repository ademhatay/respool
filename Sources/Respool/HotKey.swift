import AppKit
import Carbon.HIToolbox

/// A key combination that opens the panel from anywhere.
struct Shortcut: Equatable {
    var keyCode: Int
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: Int
    var label: String

    static let standard = Shortcut(keyCode: kVK_Space, modifiers: optionKey | shiftKey, label: "⌥⇧Space")

    static func saved() -> Shortcut {
        let defaults = UserDefaults.standard
        guard let label = defaults.string(forKey: "shortcutLabel"), !label.isEmpty else { return .standard }
        return Shortcut(
            keyCode: defaults.integer(forKey: "shortcutKeyCode"),
            modifiers: defaults.integer(forKey: "shortcutModifiers"),
            label: label
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: "shortcutKeyCode")
        defaults.set(modifiers, forKey: "shortcutModifiers")
        defaults.set(label, forKey: "shortcutLabel")
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

/// Registers the panel's system-wide shortcut. Uses the Carbon hot key API, which needs no
/// permission prompt.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private(set) var shortcut: Shortcut
    private(set) var isRegistered = false

    init(action: @escaping () -> Void) {
        self.action = action
        shortcut = Shortcut.saved()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
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
        let identifier = EventHotKeyID(signature: OSType(0x5253_504C), id: 1)
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
            new.save()
            return true
        }
        shortcut = previous
        register()
        return false
    }
}
