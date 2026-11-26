import AppKit
import SwiftUI

enum Metrics {
    static let panelWidth: CGFloat = 400
    static let panelRadius: CGFloat = 18
    static let screenInset: CGFloat = 8
}

/// A borderless panel that can take keyboard focus without activating the app,
/// so the app you were working in stays frontmost.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let library: Library
    private var keyMonitor: Any?
    private var lastHidden = Date.distantPast
    private var liveTimer: Timer?
    private(set) var isShown = false

    init(library: Library) {
        self.library = library
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.delegate = self

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.roundedMask(radius: Metrics.panelRadius)

        let hosting = NSHostingView(rootView: PanelView(library: library, close: { [weak self] in self?.hide() }))
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        panel.contentView = backdrop

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func toggle() {
        if isShown {
            hide()
        } else if Date().timeIntervalSince(lastHidden) > 0.25 {
            // Clicking the menu bar icon first dismisses the panel; do not reopen it on the same click.
            show()
        }
    }

    func show() {
        guard !isShown else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let target = NSRect(
            x: visible.maxX - Metrics.panelWidth - Metrics.screenInset,
            y: visible.minY + Metrics.screenInset,
            width: Metrics.panelWidth,
            height: visible.height - Metrics.screenInset * 2
        )
        panel.setFrame(target.offsetBy(dx: 24, dy: 0), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        isShown = true
        library.panelDidOpen()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.library.refreshLive()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.panel.invalidateShadow()
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        lastHidden = Date()
        liveTimer?.invalidate()
        liveTimer = nil
        let frame = panel.frame.offsetBy(dx: 24, dy: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isShown, event.window === panel else { return event }
        if library.recordingShortcut {
            library.captureShortcut(event)
            return nil
        }
        switch Int(event.keyCode) {
        case 53: // escape
            if library.handleEscape() { hide() }
            return nil
        case 125 where library.searchFocused: // down
            library.moveSelection(1)
            return nil
        case 126 where library.searchFocused: // up
            library.moveSelection(-1)
            return nil
        case 36, 76: // return, enter
            if library.searchFocused, library.openSelection() { return nil }
            return event
        default:
            return event
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
