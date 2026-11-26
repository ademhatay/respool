import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var library: Library?
    private var controller: PanelController?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var notifier: Notifier?
    private var observers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunning() {
            NSApp.terminate(nil)
            return
        }

        let library: Library
        do {
            library = try Library()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Respool başlatılamadı"
            alert.informativeText = "Dizin dosyası açılamadı: \(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let controller = PanelController(library: library)
        library.onOpen = { [weak controller, weak library] session in
            guard let library else { return }
            if library.isInOtherOrganization(session.id) {
                library.show(notice: Self.otherOrganizationNotice(for: session))
                return
            }
            controller?.hide()
            Opener.open(session, live: library.live[session.id], desktopID: library.desktopID(for: session.id)) { outcome in
                guard outcome == .failed else { return }
                controller?.show()
                library.show(notice: "Sohbet açılamadı")
            }
        }
        library.onOpenInDesktop = { [weak controller, weak library] session in
            guard let library else { return }
            if let live = library.live[session.id], live.isInTerminal {
                library.show(notice: "Bu sohbet bir terminalde açık")
                return
            }
            if library.isInOtherOrganization(session.id) {
                library.show(notice: Self.otherOrganizationNotice(for: session))
                return
            }
            controller?.hide()
            Opener.openInDesktop(session, desktopID: library.desktopID(for: session.id)) { outcome in
                guard outcome == .failed else { return }
                controller?.show()
                library.show(notice: "Sohbet Claude'da açılamadı")
            }
        }
        library.onStartSession = { [weak controller, weak library] folder, prompt in
            controller?.hide()
            guard Opener.startSession(in: folder, prompt: prompt) else {
                controller?.show()
                library?.show(notice: "Oturum başlatılamadı")
                return
            }
        }
        self.library = library
        self.controller = controller

        let notifier = Notifier { [weak library] sessionID in
            guard let library, let session = library.session(withID: sessionID) else { return }
            library.open(session)
        }
        library.onAttention = { [weak notifier] id, session, live in
            // No banner while the app that hosts the session is in front; it shows the change itself.
            // The session still counts toward the menu bar number.
            let front = NSWorkspace.shared.frontmostApplication
            if live.isInTerminal {
                if LiveSessions.hostApp(of: live.pid)?.processIdentifier == front?.processIdentifier { return }
            } else if front?.bundleIdentifier == "com.anthropic.claudefordesktop" {
                return
            }
            let body: String
            if live.state == .waiting {
                body = live.waitingFor.map { "Sizi bekliyor: \($0)" } ?? "Sizi bekliyor"
            } else {
                body = "Bitti, sıra sizde"
            }
            notifier?.post(sessionID: id, title: session?.title ?? "Claude Code", body: body)
        }
        self.notifier = notifier

        installStatusItem()
        let hotKey = HotKey { [weak controller] in controller?.toggle() }
        library.hotKey = hotKey
        self.hotKey = hotKey

        library.$attention
            .receive(on: RunLoop.main)
            .sink { [weak self] waiting in self?.showCount(waiting.count) }
            .store(in: &observers)
        library.startMonitoring()

        library.reload()
        controller.show()
    }

    private static func otherOrganizationNotice(for session: SessionRecord) -> String {
        if let name = session.organizationName {
            return "\(name) hesabında. Claude'da hesabı değiştirin."
        }
        return "Başka bir hesapta. Claude'da hesabı değiştirin."
    }

    /// Opening the app again (from Finder or Spotlight) brings the panel up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return false
    }

    private func isAlreadyRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Respool")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Respool"
        }
        statusItem = item
    }

    /// Shows how many sessions need attention next to the menu bar icon.
    private func showCount(_ count: Int) {
        guard let button = statusItem?.button else { return }
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.title = count > 0 ? " \(count)" : ""
    }

    @objc private func statusItemClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp, let statusItem else {
            controller?.toggle()
            return
        }
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Yenile", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let login = NSMenuItem(title: "Girişte başlat", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Respool'dan çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() {
        library?.refresh()
    }

    @objc private func toggleLoginItem() {
        library?.setLaunchesAtLogin(!LoginItem.isEnabled)
    }
}
