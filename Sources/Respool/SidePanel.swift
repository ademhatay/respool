import AppKit
import Combine
import SwiftUI

enum Metrics {
    static let panelWidth: CGFloat = 400
    static let panelRadius: CGFloat = 18
    static let screenInset: CGFloat = 8
    static let minimumSize = NSSize(width: 320, height: 320)
    static let maximumWidth: CGFloat = 900
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
    /// How far, and which way, the panel travels as it opens and closes.
    private var slide = CGSize(width: 24, height: 0)
    private let detailPanel: NSPanel
    private let detailBackdrop = NSVisualEffectView()
    private var hoverObserver: AnyCancellable?
    private var appearanceObserver: AnyCancellable?
    private(set) var isShown = false
    /// True while the panel is sliding in or out, when its frame changes are not the user's.
    private var isSettling = true

    init(library: Library) {
        self.library = library
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: true
        )
        detailPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DetailCard.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        detailPanel.level = .floating
        detailPanel.isOpaque = false
        detailPanel.backgroundColor = .clear
        detailPanel.hasShadow = true
        detailPanel.ignoresMouseEvents = true
        detailPanel.animationBehavior = .none
        detailBackdrop.material = .popover
        detailBackdrop.blendingMode = .behindWindow
        detailBackdrop.state = .active
        detailBackdrop.maskImage = Self.roundedMask(radius: 14)
        detailPanel.contentView = detailBackdrop
        hoverObserver = library.$hover.removeDuplicates().sink { [weak self] target in
            self?.showDetail(target)
        }

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.minSize = Metrics.minimumSize
        panel.maxSize = NSSize(width: Metrics.maximumWidth, height: 10_000)
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

        appearanceObserver = library.$appearanceChoice.sink { [weak self] choice in
            // Nil hands the choice back to the system.
            let appearance: NSAppearance? = choice == "light"
                ? NSAppearance(named: .aqua) : (choice == "dark" ? NSAppearance(named: .darkAqua) : nil)
            self?.panel.appearance = appearance
            self?.detailPanel.appearance = appearance
        }

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
        let edge = library.panelEdge
        var target = Self.frame(for: edge, in: screen.visibleFrame)
        if edge == .free, let saved = Self.savedFrame {
            // The panel returns to the screen it was left on, if that screen is still there.
            let home = NSScreen.screens.first { $0.visibleFrame.intersects(saved) } ?? screen
            target = Self.fitted(saved, in: home.visibleFrame)
        }
        slide = Self.slide(for: edge)
        isSettling = true
        panel.setFrame(target.offsetBy(dx: slide.width, dy: slide.height), display: true)
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
            self?.isSettling = false
        }
    }

    // MARK: - Placement

    private static let frameKey = "panelFrame"

    /// Where the panel was last dragged or resized to.
    static var savedFrame: NSRect? {
        guard let text = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(text)
        return frame.width >= 1 && frame.height >= 1 ? frame : nil
    }

    /// A frame brought wholly onto a screen, shrunk first if it is larger than the screen.
    static func fitted(_ frame: NSRect, in visible: NSRect) -> NSRect {
        let inset = Metrics.screenInset
        let width = min(max(frame.width, Metrics.minimumSize.width), min(Metrics.maximumWidth, visible.width - inset * 2))
        let height = min(max(frame.height, Metrics.minimumSize.height), visible.height - inset * 2)
        let x = min(max(frame.minX, visible.minX + inset), visible.maxX - width - inset)
        let y = min(max(frame.minY, visible.minY + inset), visible.maxY - height - inset)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// The user moved or resized the panel: it now stays wherever it is put.
    private func rememberFrame() {
        guard isShown, !isSettling else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        if library.panelEdge != .free { library.panelEdge = .free }
        slide = Self.slide(for: .free)
        library.hover = nil
        panel.invalidateShadow()
    }

    func windowDidMove(_ notification: Notification) {
        rememberFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrame()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        isSettling = true
        lastHidden = Date()
        liveTimer?.invalidate()
        liveTimer = nil
        library.hover = nil
        let frame = panel.frame.offsetBy(dx: slide.width, dy: slide.height)
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

    /// Shows the detail card to the left of the panel, level with the row it describes.
    private func showDetail(_ target: HoverTarget?) {
        guard isShown, let target, let screen = panel.screen else {
            if detailPanel.parent != nil { panel.removeChildWindow(detailPanel) }
            detailPanel.orderOut(nil)
            return
        }
        let hosting = NSHostingView(rootView: DetailCard(library: library, subject: target.subject))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        detailBackdrop.subviews.forEach { $0.removeFromSuperview() }
        detailBackdrop.addSubview(hosting)

        let visible = screen.visibleFrame
        let y = min(max(target.screenY - size.height / 2, visible.minY + Metrics.screenInset),
                    visible.maxY - size.height - Metrics.screenInset)
        // Beside the panel, on whichever side has room.
        let leftX = panel.frame.minX - size.width - 8
        let x = leftX >= visible.minX ? leftX : panel.frame.maxX + 8
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let wasVisible = detailPanel.isVisible
        detailPanel.setFrame(frame, display: true)
        if !wasVisible {
            detailPanel.alphaValue = 0
            panel.addChildWindow(detailPanel, ordered: .above)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                detailPanel.animator().alphaValue = 1
            }
        }
        detailPanel.invalidateShadow()
    }

    /// Where the panel sits for an edge. At the sides it runs the height of the screen; at the
    /// top and bottom it keeps its width, centered, and takes about two thirds of the height.
    static func frame(for edge: PanelEdge, in visible: NSRect) -> NSRect {
        let inset = Metrics.screenInset
        let width = Metrics.panelWidth
        let fullHeight = visible.height - inset * 2
        let partHeight = min(fullHeight, max(480, (visible.height * 0.66).rounded()))
        switch edge {
        case .right, .free:
            return NSRect(x: visible.maxX - width - inset, y: visible.minY + inset, width: width, height: fullHeight)
        case .left:
            return NSRect(x: visible.minX + inset, y: visible.minY + inset, width: width, height: fullHeight)
        case .top:
            return NSRect(x: visible.midX - width / 2, y: visible.maxY - partHeight - inset, width: width, height: partHeight)
        case .bottom:
            return NSRect(x: visible.midX - width / 2, y: visible.minY + inset, width: width, height: partHeight)
        }
    }

    /// The offset the panel starts from, away from the screen, so it slides in from its edge.
    static func slide(for edge: PanelEdge) -> CGSize {
        switch edge {
        case .right: return CGSize(width: 24, height: 0)
        case .left: return CGSize(width: -24, height: 0)
        case .top: return CGSize(width: 0, height: 24)
        case .bottom: return CGSize(width: 0, height: -24)
        case .free: return CGSize(width: 0, height: -10)
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

    static func roundedMask(radius: CGFloat) -> NSImage {
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
