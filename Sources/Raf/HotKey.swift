import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses the Carbon hot key API, which needs no permission prompt.
final class HotKey {
    static let displayName = "⌥⇧Space"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private(set) var isRegistered = false

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey | shiftKey, action: @escaping () -> Void) {
        self.action = action
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
        let identifier = EventHotKeyID(signature: OSType(0x5241_4621), id: 1)
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), identifier, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        isRegistered = status == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
