import AppKit
import SwiftUI

/// One thing the quick switcher can jump to.
enum SwitcherItem: Identifiable, Hashable {
    case session(SessionRecord)
    case project(ProjectGroup)

    var id: String {
        switch self {
        case .session(let session): return "s:" + session.id
        case .project(let project): return "p:" + project.key
        }
    }
}

extension Library {
    /// What the quick switcher offers for what was typed: projects whose name matches, then
    /// sessions whose title or project matches, the best and most recent first. With nothing
    /// typed, the pinned sessions and the latest ones.
    func switcherItems(for text: String, limit: Int = 9) -> [SwitcherItem] {
        let query = text.trimmingCharacters(in: .whitespaces)
        let sessions = projects.flatMap(\.sessions) + pinned.map(\.session)
        var seen = Set<String>()
        let unique = sessions.filter { seen.insert($0.id).inserted }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        guard !query.isEmpty else {
            let first = pinned.map(\.session) + unique
            var shown = Set<String>()
            return first.filter { shown.insert($0.id).inserted }.prefix(limit).map { .session($0) }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func score(_ text: String) -> Int? {
            guard let range = text.range(of: query, options: options) else { return nil }
            if range.lowerBound == text.startIndex { return 0 }
            // The start of a word comes before the middle of one.
            let before = text[text.index(before: range.lowerBound)]
            return before.isLetter || before.isNumber ? 2 : 1
        }
        var projectHits: [(project: ProjectGroup, rank: Int)] = []
        for project in projects {
            if let rank = score(project.name) { projectHits.append((project, rank)) }
        }
        projectHits.sort { first, second in
            if first.rank != second.rank { return first.rank < second.rank }
            return (first.project.lastActivity ?? .distantPast) > (second.project.lastActivity ?? .distantPast)
        }
        var sessionHits: [(session: SessionRecord, rank: Int)] = []
        for session in unique {
            if let rank = score(session.title) {
                sessionHits.append((session, rank))
            } else if let rank = score(session.projectName) {
                sessionHits.append((session, rank + 3))
            }
        }
        // A stable sort keeps the most recent first among equals.
        let ordered = sessionHits.enumerated().sorted { first, second in
            first.element.rank == second.element.rank ? first.offset < second.offset : first.element.rank < second.element.rank
        }
        var items: [SwitcherItem] = projectHits.prefix(3).map { .project($0.project) }
        items += ordered.prefix(limit).map { .session($0.element.session) }
        return Array(items.prefix(limit))
    }

    /// The editor a session goes to with ⌘↩: its project's own editor, else the first installed.
    var preferredEditor: OpenMethod? {
        openMethods.first { $0.isEditor }
    }

    func preferredEditor(for session: SessionRecord) -> OpenMethod? {
        let chosen = openMethod(forProject: session.projectKey)
        if chosen.isEditor { return chosen }
        if let host = sessionHosts[session.id], host.isEditor { return host }
        return preferredEditor
    }
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A search box in the middle of the screen that jumps straight to a chat or a project.
final class SwitcherController: NSObject, NSWindowDelegate {
    private let library: Library
    private let model = SwitcherModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    /// Shows a project's page in the side panel.
    var onShowProject: ((ProjectGroup) -> Void)?

    init(library: Library) {
        self.library = library
        super.init()
    }

    var isShown: Bool { panel != nil }

    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        guard panel == nil else { return }
        model.query = ""
        model.selection = 0
        model.items = library.switcherItems(for: "")

        let view = SwitcherView(library: library, model: model, choose: { [weak self] item, modifiers in
            self?.choose(item, modifiers: modifiers)
        })
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: SwitcherView.width, height: SwitcherView.height)
        let panel = SwitcherPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.appearance = library.appearanceChoice == "light"
            ? NSAppearance(named: .aqua) : (library.appearanceChoice == "dark" ? NSAppearance(named: .darkAqua) : nil)

        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = PanelController.roundedMask(radius: SwitcherView.radius)
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)
        panel.contentView = backdrop

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // A third of the way down, where Spotlight and Raycast sit.
            panel.setFrameOrigin(NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.maxY - visible.height * 0.28 - size.height).rounded()
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        library.refreshLive()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func close() {
        guard let panel else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        self.panel = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Arrow keys move, return chooses, escape closes. Everything else goes to the search field.
    private func handle(_ event: NSEvent) -> Bool {
        if PanelController.performEditCommand(for: event) { return true }
        let count = model.items.count
        switch Int(event.keyCode) {
        case 53:
            close()
        case 125 where count > 0:
            model.selection = (model.selection + 1) % count
        case 126 where count > 0:
            model.selection = (model.selection - 1 + count) % count
        case 36, 76:
            guard model.items.indices.contains(model.selection) else { return true }
            choose(model.items[model.selection], modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        default:
            return false
        }
        return true
    }

    /// ↩ opens a chat where it belongs, ⌘↩ in its editor, ⌥↩ in a terminal. ↩ on a project
    /// shows its page; ⌘↩ starts a new chat in it.
    private func choose(_ item: SwitcherItem, modifiers: NSEvent.ModifierFlags) {
        close()
        switch item {
        case .session(let session):
            if modifiers.contains(.command), let editor = library.preferredEditor(for: session) {
                library.open(session, with: editor)
            } else if modifiers.contains(.option) {
                library.open(session, with: Opener.companionTerminal)
            } else {
                library.open(session)
            }
        case .project(let project):
            if modifiers.contains(.command) {
                library.startSession(in: project)
            } else {
                onShowProject?(project)
            }
        }
    }
}

final class SwitcherModel: ObservableObject {
    @Published var query = ""
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
}

struct SwitcherView: View {
    static let width: CGFloat = 620
    static let height: CGFloat = 470
    static let radius: CGFloat = 16

    @ObservedObject var library: Library
    @ObservedObject var model: SwitcherModel
    let choose: (SwitcherItem, NSEvent.ModifierFlags) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField(L10n.switcherPlaceholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onChange(of: model.query) { _, text in
                        model.items = library.switcherItems(for: text)
                        model.selection = 0
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: 60)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)

            if model.items.isEmpty {
                Text(L10n.noResults)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 2) {
                    if model.query.isEmpty {
                        Text(L10n.recentTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                    }
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == model.selection)
                            .onTapGesture { choose(item, []) }
                            .onHover { if $0 { model.selection = index } }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
            }

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    @ViewBuilder private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            switch item {
            case .session(let session):
                AppMark(method: library.destination(of: session))
                    .scaleEffect(1.3)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Text(session.placeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let live = library.live[session.id] {
                    LiveIndicator(live: live, selected: false)
                }
                Text(RelativeTime.short(session.lastActivity))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            case .project(let project):
                Image(systemName: "folder.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(L10n.sessions(project.sessions.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(L10n.projectTag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// What the keys do for the selected row.
    private var footer: some View {
        let selected = model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
        return HStack(spacing: 16) {
            Spacer()
            switch selected {
            case .project:
                hint("↩", L10n.projectPage)
                hint("⌘↩", L10n.newChat)
            case .session(let session):
                hint("↩", L10n.open)
                if let editor = library.preferredEditor(for: session) { hint("⌘↩", editor.title) }
                hint("⌥↩", Opener.companionTerminal.title)
            case nil:
                EmptyView()
            }
            hint("esc", L10n.close)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.09)))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}
