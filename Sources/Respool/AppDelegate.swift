import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var library: Library?
    private var controller: PanelController?
    private var statusItem: NSStatusItem?
    private var hotKeys: [HotKey] = []
    private var notifier: Notifier?
    private var observers = Set<AnyCancellable>()
    private var clock: Timer?
    private var onboarding: OnboardingController?

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
            alert.messageText = L10n.launchFailed
            alert.informativeText = L10n.indexUnopened("\(error)")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let controller = PanelController(library: library)
        library.onOpen = { [weak self, weak controller, weak library] session, method in
            guard let library else { return }
            // A link into another organization does nothing; any other way of opening still works.
            if method == .automatic || method == .desktop, library.isInOtherOrganization(session.id) {
                library.show(notice: Self.otherOrganizationNotice(for: session))
                return
            }
            controller?.dismiss()
            Opener.open(
                session, method: method, live: library.live[session.id], desktopID: library.desktopID(for: session.id)
            ) { outcome in
                switch outcome {
                case .failed:
                    controller?.present()
                    library.show(notice: L10n.chatFailed)
                case .openedInEditor:
                    self?.announceCopiedCommand(for: session.title)
                case .opened, .alreadyInTerminal:
                    break
                }
            }
        }
        library.onOpenInDesktop = { [weak controller, weak library] session in
            guard let library else { return }
            if let live = library.live[session.id], live.isInTerminal {
                library.show(notice: L10n.chatOpenInTerminal)
                return
            }
            if library.isInOtherOrganization(session.id) {
                library.show(notice: Self.otherOrganizationNotice(for: session))
                return
            }
            controller?.dismiss()
            Opener.openInDesktop(session, desktopID: library.desktopID(for: session.id)) { outcome in
                guard outcome == .failed else { return }
                controller?.present()
                library.show(notice: L10n.chatFailedInClaude)
            }
        }
        library.onStartSession = { [weak self, weak controller, weak library] folder, prompt, method in
            controller?.dismiss()
            guard Opener.startSession(in: folder, prompt: prompt, method: method) else {
                controller?.present()
                library?.show(notice: L10n.sessionFailed)
                return
            }
            if method.isEditor {
                self?.announceCopiedCommand(for: URL(fileURLWithPath: folder).lastPathComponent)
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
                body = live.waitingFor.map(L10n.waitingFor) ?? L10n.waiting
            } else {
                body = L10n.finished
            }
            notifier?.post(sessionID: id, title: session?.title ?? "Claude Code", body: body)
        }
        self.notifier = notifier

        library.restoreTimer()
        installStatusItem()
        // The quick shortcuts open the panel if it is closed, then put the cursor in their field.
        func capture(_ action: @escaping (Library) -> Void) -> () -> Void {
            { [weak controller, weak library] in
                controller?.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let library { action(library) }
                }
            }
        }
        hotKeys = [
            HotKey(.panel) { [weak controller] in controller?.toggle() },
            HotKey(.quickTask, action: capture { $0.quickTask() }),
            HotKey(.quickNote, action: capture { $0.quickNote() }),
        ]
        hotKeys.forEach(library.register)

        library.$attention
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &observers)
        library.$opensInTabs
            .sink { Opener.usesTabs = $0 }
            .store(in: &observers)
        library.$runningTimer
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &observers)
        // Once a second, so the menu bar shows the timer moving. Idle unless a timer is running;
        // in the common modes, so it keeps ticking while a menu is open.
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            if self?.library?.runningTimer != nil { self?.updateStatusTitle() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        // A sleeping Mac is not being worked on.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak library] _ in library?.stopTimer() }
        library.startMonitoring()

        let onboarding = OnboardingController(library: library)
        onboarding.onFinish = { [weak controller] in controller?.show() }
        library.onShowWelcome = { [weak controller, weak onboarding] in
            controller?.hide()
            onboarding?.show()
        }
        self.onboarding = onboarding

        // Loaded before the first screen, so the welcome can say what was found.
        library.reloadSync()
        if OnboardingController.isDue {
            onboarding.show()
        } else {
            controller.show()
        }
    }

    private static func otherOrganizationNotice(for session: SessionRecord) -> String {
        if let name = session.organizationName {
            return L10n.inAccount(name)
        }
        return L10n.inOtherAccount
    }

    /// Opening the app again (from Finder or Spotlight) brings the panel up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding?.isShown != true { controller?.show() }
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

    /// Shows, next to the menu bar icon, how many sessions need attention and how long the
    /// timer has been running.
    private func updateStatusTitle() {
        guard let button = statusItem?.button, let library else { return }
        var parts: [String] = []
        if !library.attention.isEmpty { parts.append("\(library.attention.count)") }
        if let timer = library.runningTimer {
            parts.append(Format.shortClock(Date().timeIntervalSince(timer.started)))
        }
        button.imagePosition = parts.isEmpty ? .imageOnly : .imageLeading
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    /// An editor has no way to be handed a command, so it is left on the clipboard and said so.
    private func announceCopiedCommand(for title: String) {
        library?.show(notice: L10n.commandCopied)
        if library?.notificationsEnabled == true {
            notifier?.post(sessionID: "command-copied", title: title, body: L10n.commandCopied)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        library?.recordHeartbeatSync()
    }

    @objc private func statusItemClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp, let statusItem else {
            controller?.toggle()
            return
        }
        let menu = NSMenu()
        let refresh = NSMenuItem(title: L10n.refresh, action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let login = NSMenuItem(title: L10n.launchAtLogin, action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
