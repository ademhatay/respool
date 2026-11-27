import AppKit
import SwiftUI

private final class WelcomePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The first-run screen: a panel in the middle of the screen with the few choices worth
/// making before the app is used. It is shown once, and again from Settings on request.
final class OnboardingController: NSObject {
    private let library: Library
    private var panel: NSPanel?
    private var keyMonitor: Any?
    /// Called when the screen is dismissed.
    var onFinish: (() -> Void)?

    static var isDue: Bool { !UserDefaults.standard.bool(forKey: "didOnboard") }

    init(library: Library) {
        self.library = library
    }

    var isShown: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: OnboardingView(library: library, finish: { [weak self] in self?.close() }))
        let size = hosting.fittingSize
        let panel = WelcomePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = library.appearanceChoice == "light"
            ? NSAppearance(named: .aqua) : (library.appearanceChoice == "dark" ? NSAppearance(named: .darkAqua) : nil)

        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = PanelController.roundedMask(radius: OnboardingView.radius)
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        panel.contentView = backdrop

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // A little above the middle, where the eye rests.
            panel.setFrameOrigin(NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.midY - size.height / 2 + visible.height * 0.06).rounded()
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if self.library.recordingShortcut {
                self.library.captureShortcut(event)
                return nil
            }
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                self.close()
                return nil
            }
            return event
        }
    }

    func close() {
        guard let panel else { return }
        library.cancelShortcutRecording()
        UserDefaults.standard.set(true, forKey: "didOnboard")
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        self.panel = nil
        panel.orderOut(nil)
        onFinish?()
    }
}

struct OnboardingView: View {
    static let radius: CGFloat = 20
    static let width: CGFloat = 440

    @ObservedObject var library: Library
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(L10n.welcomeTitle)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 10)
            Text(L10n.welcomeLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            if library.sessionCount > 0 {
                Text(L10n.welcomeFound(library.sessionCount, library.allProjects.count))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }

            SettingsGroup {
                VStack(spacing: 0) {
                    SettingsRow(title: L10n.openPanelShortcut) { ShortcutButton(library: library, kind: .panel) }
                    SettingsRow(title: L10n.panelPosition) {
                        Picker(L10n.panelPosition, selection: $library.panelEdge) {
                            ForEach(PanelEdge.edges, id: \.self) { edge in
                                Text(edge.title).tag(edge)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow(title: L10n.openChatsIn) {
                        Picker(L10n.openChatsIn, selection: $library.openMethod) {
                            ForEach(library.openMethods, id: \.self) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    SettingsRow(title: L10n.launchAtLogin) {
                        Toggle("", isOn: Binding(
                            get: { library.launchesAtLogin },
                            set: { library.setLaunchesAtLogin($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 20)

            Button(action: finish) {
                Text(L10n.welcomeStart)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
