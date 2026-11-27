import SwiftUI

enum PanelField: Hashable {
    case search
    case task(String)
    case rename(String)
    case tagName
    case organization(String)
    case todo
    case note
}

/// Places in the panel's list that are scrolled to by name.
enum ScrollAnchor: Hashable {
    static let top = "top"
    static let notes = "notes-section"
}

struct PanelView: View {
    @ObservedObject var library: Library
    let close: () -> Void
    @FocusState private var focus: PanelField?

    var body: some View {
        VStack(spacing: 0) {
            if library.showingReleaseNotes {
                ReleaseNotesView(library: library)
            } else if library.showingSettings {
                SettingsView(library: library, focus: $focus)
            } else if let outline = library.outline {
                OutlineView(library: library, outline: outline)
            } else {
                searchBar
                filterBar
                if !library.unbackedExpiringSessions.isEmpty {
                    ExpiryBanner(library: library)
                }
                content
            }
            if let timer = library.runningTimer {
                TimerBar(library: library, timer: timer)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onChange(of: focus) { _, field in
            library.searchFocused = field == nil || field == .search
        }
        .onChange(of: library.focusRequest) { _, _ in
            DispatchQueue.main.async { focus = .search }
        }
        .onAppear {
            DispatchQueue.main.async { focus = .search }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.searchPlaceholder, text: $library.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focus, equals: .search)
            if !library.query.isEmpty {
                Button {
                    library.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.clearSearch)
            }
            Menu {
                Button(L10n.refresh) { library.refresh() }
                Button(L10n.newTag) { library.tagEditor = TagEditor() }
                Button(L10n.settingsMenu) { library.showingSettings = true }
                if let version = library.availableUpdate {
                    Button(L10n.updateMenu(version)) { library.showingReleaseNotes = true }
                }
                Divider()
                Button(L10n.quit) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07))
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(WindowDragArea())
    }

    // MARK: - Filters

    @ViewBuilder private var filterBar: some View {
        let showsOrganizations = library.showsOrganizations && library.organizations.count > 1
        let showsTags = library.tagEditor != nil || !library.tags.isEmpty
        if showsOrganizations || showsTags {
            VStack(alignment: .leading, spacing: 8) {
                if showsOrganizations {
                    Picker(L10n.account, selection: $library.organizationFilter) {
                        Text(L10n.all).tag(String?.none)
                        ForEach(library.organizations) { organization in
                            Text(shortened(organization.name)).tag(String?.some(organization.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if library.tagEditor != nil {
                    TagEditorRow(library: library, focus: $focus)
                } else if !library.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(library.tags) { tag in
                                TagChip(library: library, tag: tag)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    /// Keeps the account switcher's segments an even width when a name is long.
    private func shortened(_ name: String) -> String {
        name.count > 16 ? String(name.prefix(15)) + "…" : name
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !library.hasLoaded {
            Spacer()
        } else if library.sessionCount == 0 {
            emptyLibrary
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        Color.clear.frame(height: 0).id(ScrollAnchor.top)
                        if let results = library.results {
                            resultRows(results)
                        } else if let tagged = library.tagged {
                            taggedRows(tagged)
                        } else {
                            browseRows
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .onChange(of: library.selection) { _, key in
                    guard let key else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key) }
                }
                .onChange(of: library.todoFocusRequest) { _, _ in
                    proxy.scrollTo(ScrollAnchor.top, anchor: .top)
                    DispatchQueue.main.async { focus = .todo }
                }
                .onChange(of: library.noteFocusRequest) { _, _ in
                    proxy.scrollTo(ScrollAnchor.notes, anchor: .top)
                    DispatchQueue.main.async { focus = .note }
                }
            }
        }
    }

    @ViewBuilder private var browseRows: some View {
        if library.showsTodos {
            TodoSection(library: library, focus: $focus)
        }

        NotesSection(library: library, focus: $focus)

        if !library.pinned.isEmpty {
            CollapsibleHeader(
                library: library, title: L10n.pinnedTitle,
                section: PanelSection.pinned, count: library.pinned.count
            )
            if !library.isCollapsed(PanelSection.pinned) {
                ForEach(library.pinned) { item in
                    PinnedCard(library: library, item: item, focus: $focus)
                }
            }
        }

        if !library.recent.isEmpty {
            CollapsibleHeader(
                library: library, title: L10n.recentTitle,
                section: PanelSection.recent, count: library.recent.count
            )
            if !library.isCollapsed(PanelSection.recent) {
                ForEach(library.recent) { session in
                    SessionRow(
                        library: library, session: session,
                        rowKey: RowKey.recent(session.id), detail: session.placeLabel
                    )
                }
            }
        }

        TimeSection(library: library)

        WeekSection(library: library, focus: $focus)

        CollapsibleHeader(
            library: library, title: L10n.projectsTitle,
            section: PanelSection.projects, count: library.projects.count
        ) {
            ProjectListMenu(library: library)
        }
        if !library.isCollapsed(PanelSection.projects) {
            ForEach(library.projects) { project in
                ProjectSection(library: library, project: project, focus: $focus)
            }
            if library.projects.isEmpty, !library.allProjects.isEmpty {
                Text(L10n.allProjectsHidden)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func resultRows(_ results: [SearchHit]) -> some View {
        if results.isEmpty {
            VStack(spacing: 4) {
                Text(L10n.noResults)
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.noMatch(library.query))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.horizontal, 24)
        } else {
            SectionHeader(title: L10n.sessions(results.count))
            ForEach(results) { hit in
                SessionRow(
                    library: library, session: hit.session,
                    rowKey: RowKey.hit(hit.id),
                    detail: hit.snippet == nil ? hit.session.placeLabel : nil,
                    snippet: hit.snippet, detailLines: 2
                )
            }
        }
    }

    @ViewBuilder private func taggedRows(_ sessions: [SessionRecord]) -> some View {
        let name = library.tags.first { $0.id == library.tagFilter }?.name ?? ""
        if sessions.isEmpty {
            VStack(spacing: 4) {
                Text(L10n.noTaggedChats)
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.tagHint(name))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.horizontal, 24)
        } else {
            SectionHeader(title: "\(name) · \(L10n.sessions(sessions.count))")
            ForEach(sessions) { session in
                SessionRow(
                    library: library, session: session,
                    rowKey: RowKey.tagged(session.id), detail: session.placeLabel
                )
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 6) {
            Spacer()
            if let progress = library.indexing {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 160)
                Text(L10n.indexing)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 6)
                Text("\(progress.done) / \(progress.total)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.noChats)
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.noChatsHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(library.shortcutLabel)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(WindowDragArea())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var statusText: String {
        if let notice = library.notice { return notice }
        if let progress = library.indexing, progress.total > 0 {
            return L10n.indexing + " \(progress.done) / \(progress.total)"
        }
        // Says how many projects are left out, when the list is thinner than the index.
        let shown = library.projects.count, total = library.allProjects.count
        return L10n.statusLine(library.sessionCount, projectsShown: shown, projectsTotal: total)
    }
}

// MARK: - Building blocks

/// A section title that hides or shows its section when clicked. `trailing` sits at its right
/// edge, outside the button, for a control of the section's own.
struct CollapsibleHeader<Trailing: View>: View {
    @ObservedObject var library: Library
    let title: String
    let section: String
    var count = 0
    @ViewBuilder let trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        let collapsed = library.isCollapsed(section)
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { library.toggleSection(section) }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if collapsed, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .opacity(hovering || collapsed ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(collapsed ? L10n.showSection : L10n.hideSection)
            trailing()
                .padding(.trailing, 4)
        }
    }
}

extension CollapsibleHeader where Trailing == EmptyView {
    init(library: Library, title: String, section: String, count: Int = 0) {
        self.init(library: library, title: title, section: section, count: count) { EmptyView() }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

/// Text colors for a row, which invert when the row is the keyboard selection.
struct RowStyle {
    let selected: Bool

    var title: AnyShapeStyle {
        selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }
    var detail: AnyShapeStyle {
        selected ? AnyShapeStyle(Color.white.opacity(0.78)) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
    var faint: AnyShapeStyle {
        selected ? AnyShapeStyle(Color.white.opacity(0.62)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
    }
    func background(hovering: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let style: RowStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.detail)
                .frame(width: 22, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SessionRow: View {
    @ObservedObject var library: Library
    let session: SessionRecord
    let rowKey: String
    var detail: String?
    var snippet: Snippet?
    var detailLines = 1
    var inset: CGFloat = 0
    var onAddTask: (() -> Void)?

    @State private var hovering = Snapshot.showsHover

    var body: some View {
        let style = RowStyle(selected: library.selection == rowKey)
        let pinned = library.isPinned(session.id)
        let live = library.live[session.id]

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.title)
                        .font(.system(size: 13))
                        .foregroundStyle(style.title)
                        .lineLimit(1)
                    ForEach(library.tags(for: session).prefix(3)) { tag in
                        TagMark(color: style.selected ? Color.white : TagPalette.color(tag.color))
                            .help(tag.name)
                    }
                    if let expiry = library.expiry(of: session) {
                        ExpiryMark(expiry: expiry, selected: style.selected)
                    }
                }
                if let snippet {
                    Text(highlighted(snippet, style: style))
                        .font(.system(size: 11))
                        .foregroundStyle(style.detail)
                        .lineLimit(detailLines)
                } else if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(style.detail)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if let live {
                        LiveIndicator(
                            live: live, selected: style.selected,
                            finished: library.attention.contains(session.id)
                        )
                    }
                    Text(RelativeTime.short(session.lastActivity))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(style.faint)
                }
                .opacity(hovering ? 0 : 1)
                HStack(spacing: 0) {
                    if let onAddTask {
                        IconButton(symbol: "plus", help: L10n.addTask, style: style, action: onAddTask)
                    }
                    IconButton(symbol: "list.bullet", help: L10n.promptOutline, style: style) {
                        library.showOutline(for: session)
                    }
                    IconButton(
                        symbol: pinned ? "pin.slash" : "pin",
                        help: pinned ? L10n.unpin : L10n.pin,
                        style: style
                    ) {
                        library.togglePin(session)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .frame(height: 16)
        }
        .padding(.leading, 8 + inset)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.background(hovering: hovering))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { library.open(session) }
        .contextMenu { menu(pinned: pinned, live: live) }
        .modifier(HoverDetail(library: library, subject: .session(session)))
        .id(rowKey)
    }

    @ViewBuilder private func menu(pinned: Bool, live: LiveSession?) -> some View {
        Menu(L10n.openWith) {
            ForEach(library.openMethods.filter { $0 != .automatic }, id: \.self) { method in
                Button(method.title) {
                    if method == .desktop {
                        library.openInDesktop(session)
                    } else {
                        library.open(session, with: method)
                    }
                }
                // A running session is not resumed a second time somewhere else.
                .disabled(live != nil && method != .desktop)
            }
        }
        Button(L10n.promptOutline) { library.showOutline(for: session) }
        Divider()
        Button(pinned ? L10n.unpin : L10n.pin) { library.togglePin(session) }
        Button(L10n.addTask) { library.beginTask(linkedTo: .session(id: session.id, title: session.title)) }
        Menu(L10n.tags) {
            ForEach(library.tags) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { session.tagIDs.contains(tag.id) },
                    set: { _ in library.toggle(tag, on: session) }
                ))
            }
            if !library.tags.isEmpty { Divider() }
            Button(L10n.newTag) { library.tagEditor = TagEditor(sessionID: session.id) }
        }
        Divider()
        Button(L10n.backUpTranscript) { library.backUp([session]) }
        Button(L10n.showInFinder) { Opener.revealFolder(session.cwd) }
        Button(L10n.copySessionID) { Opener.copy(session.id) }
    }

    private func highlighted(_ snippet: Snippet, style: RowStyle) -> AttributedString {
        var text = AttributedString(snippet.text)
        for match in snippet.matches {
            let start = text.index(text.startIndex, offsetByCharacters: match.lowerBound)
            let end = text.index(text.startIndex, offsetByCharacters: match.upperBound)
            text[start..<end].font = .system(size: 11, weight: .semibold)
            text[start..<end].foregroundColor = style.selected ? .white : .primary
        }
        return text
    }
}

/// The mark on a session Claude Code may soon delete: a warning, or a calm sign once a copy of
/// the transcript has been taken.
struct ExpiryMark: View {
    let expiry: (days: Int, backedUp: Bool)
    let selected: Bool

    var body: some View {
        Image(systemName: expiry.backedUp ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selected ? Color.white : (expiry.backedUp ? Color.secondary : Color.orange))
            .help(text)
    }

    private var text: String {
        if expiry.backedUp {
            return expiry.days == 0 ? L10n.backedUp : L10n.backedUpDaysLeft(expiry.days)
        }
        if expiry.days == 0 { return L10n.mayDeleteNow }
        return L10n.mayDeleteIn(expiry.days)
    }
}

/// Says that Claude Code is about to delete some sessions, and offers to copy their transcripts.
struct ExpiryBanner: View {
    @ObservedObject var library: Library

    var body: some View {
        let sessions = library.unbackedExpiringSessions
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(L10n.expiringChats(sessions.count))
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.backUp) { library.backUp(sessions) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .help("""
        Claude Code, \(Retention.days) gündür yazılmayan terminal sohbetlerinin dökümünü siler. \
        Bir kopyası alınan sohbetler işaretlenir; kopyalar Respool'un klasöründeki Backups içinde durur.
        """)
    }
}

/// Shows that a session is running: a spinner while Claude works, a dot when it is your turn.
struct LiveIndicator: View {
    let live: LiveSession
    let selected: Bool
    /// The session finished its work and has not been looked at since.
    var finished = false

    var body: some View {
        switch live.state {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.8)
                .frame(width: 10, height: 10)
        case .waiting:
            Circle()
                .fill(selected ? Color.white : Color.orange)
                .frame(width: 7, height: 7)
        case .idle:
            Circle()
                .fill(selected ? Color.white : (finished ? Color.green : Color.accentColor))
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - To-dos

/// The to-do section: a calendar, then the tasks planned for the day it has selected.
struct TodoSection: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    @State private var draft = ""

    var body: some View {
        CollapsibleHeader(
            library: library, title: L10n.todosTitle,
            section: PanelSection.todos, count: library.openListedTaskCount
        )
        if !library.isCollapsed(PanelSection.todos) {
            TaskCalendar(library: library)
            lists
            addRow
        }
    }

    @ViewBuilder private var lists: some View {
        let day = library.selectedDay
        // Tasks whose day has passed are late wherever they are listed, so they only join today's.
        let overdue = day == library.today ? library.overdueTasks : []
        if !overdue.isEmpty {
            groupTitle(L10n.overdue)
            ForEach(overdue) { task in
                TaskRow(library: library, task: task, listedDay: day, list: overdue)
            }
        }
        let due = library.tasks(on: day)
        ForEach(due) { task in
            TaskRow(library: library, task: task, listedDay: day, list: due)
        }
        let undated = library.undatedTasks
        if !undated.isEmpty {
            groupTitle(L10n.noDate)
            ForEach(undated) { task in
                TaskRow(library: library, task: task, listedDay: day, list: undated)
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 1)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            TextField(L10n.addTask, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus, equals: .todo)
                .onSubmit {
                    library.addTodo(draft)
                    draft = ""
                    DispatchQueue.main.async { focus.wrappedValue = .todo }
                }
            if let link = library.taskLink {
                linkChip(link)
            }
            // Says which day the calendar has selected, since that is where a new task goes.
            Text(library.dayLabel(library.selectedDay))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help(L10n.newTaskDayHelp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .onAppear {
            // The row was just created because a session or project asked for a task; take the focus.
            guard library.taskLink != nil else { return }
            DispatchQueue.main.async { focus.wrappedValue = .todo }
        }
    }

    /// The session or project the next task will be attached to, with a way to take that back.
    private func linkChip(_ link: TaskLink) -> some View {
        HStack(spacing: 4) {
            Image(systemName: link.symbol)
                .font(.system(size: 9, weight: .medium))
            Text(link.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
            Button {
                library.taskLink = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.removeLink)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help(L10n.taskLinkHelp(link.title))
    }
}

/// A week, or a whole month when expanded, with a mark under each day that has open tasks.
struct TaskCalendar: View {
    @ObservedObject var library: Library

    @State private var hovering: Date?

    /// Monday first, whatever day the calendar's own week starts on.
    private static let weekdays: [String] = {
        let symbols = Library.calendar.shortWeekdaySymbols
        let start = Library.calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }()

    var body: some View {
        let days = library.calendarDays
        VStack(spacing: 3) {
            header(days: days)
            HStack(spacing: 0) {
                ForEach(Self.weekdays, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(stride(from: 0, to: days.count, by: 7)), id: \.self) { start in
                HStack(spacing: 0) {
                    ForEach(days[start..<min(start + 7, days.count)], id: \.self) { day in
                        cell(day)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func header(days: [Date]) -> some View {
        let expanded = library.calendarExpanded
        return HStack(spacing: 2) {
            arrow("chevron.left", expanded ? L10n.previousMonth : L10n.previousWeek, step: -1)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { library.calendarExpanded.toggle() }
            } label: {
                Text(title(days))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? L10n.weekView : L10n.monthView)
            arrow("chevron.right", expanded ? L10n.nextMonth : L10n.nextWeek, step: 1)
            Spacer(minLength: 4)
            Button(L10n.today) { withAnimation(.easeOut(duration: 0.15)) { library.showToday() } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .contentShape(Rectangle())
                .help(L10n.backToToday)
                .opacity(library.selectedDay == library.today ? 0.5 : 1)
        }
    }

    private func arrow(_ symbol: String, _ help: String, step: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { library.shiftCalendar(by: step) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func title(_ days: [Date]) -> String {
        if library.calendarExpanded, let month = Library.calendar.dateInterval(of: .month, for: library.calendarAnchor) {
            return Format.month(month.start)
        }
        if let first = days.first, let last = days.last { return Format.calendarTitle(from: first, to: last) }
        return ""
    }

    private func cell(_ date: Date) -> some View {
        let key = Format.dayKey(date)
        let isToday = key == library.today
        let isSelected = key == library.selectedDay
        let inMonth = Library.calendar.isDate(date, equalTo: library.calendarAnchor, toGranularity: .month)
        let ink: Color = isToday ? (isSelected ? .white : .accentColor) : (inMonth ? .primary : .secondary)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { library.selectedDay = key }
        } label: {
            VStack(spacing: 3) {
                Text(String(Library.calendar.component(.day, from: date)))
                    .font(.system(size: 12, weight: isToday || isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(isSelected ? (isToday ? Color.accentColor : Color.primary.opacity(0.14)) : .clear)
                    )
                    .overlay(
                        // Today is ringed even on a day that is not selected.
                        Circle().strokeBorder(isToday && !isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                Circle()
                    .fill(library.openTaskCount(on: key) > 0 ? Color.accentColor : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering == date && !isSelected ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovering = inside ? date : (hovering == date ? nil : hovering) }
        .help(Format.day(date))
    }
}

// MARK: - Notes

/// Lines jotted down from anywhere with the quick-note shortcut, newest first.
struct NotesSection: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    @State private var draft = ""

    var body: some View {
        CollapsibleHeader(
            library: library, title: L10n.notesTitle,
            section: PanelSection.notes, count: library.notes.count
        )
        .id(ScrollAnchor.notes)
        if !library.isCollapsed(PanelSection.notes) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                TextField(L10n.notePlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused(focus, equals: .note)
                    .onSubmit {
                        library.addNote(draft)
                        draft = ""
                        DispatchQueue.main.async { focus.wrappedValue = .note }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            ForEach(library.notes) { note in
                NoteRow(library: library, note: note)
            }
        }
    }
}

struct NoteRow: View {
    @ObservedObject var library: Library
    let note: NoteItem

    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text)
                    .font(.system(size: 12))
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if let created = note.created {
                    Text(Format.shortDate(created))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button {
                library.delete(note)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.deleteNote)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            Button(L10n.copy) {
                Opener.copy(note.text)
                library.show(notice: L10n.noteCopied)
            }
            Button(L10n.turnIntoTask) { library.makeTask(from: note) }
            Divider()
            Button(L10n.deleteNote, role: .destructive) { library.delete(note) }
        }
    }
}

// MARK: - Pinned sessions and their tasks

struct PinnedCard: View {
    @ObservedObject var library: Library
    let item: PinnedSession
    var focus: FocusState<PanelField?>.Binding

    @State private var draft = ""
    @State private var targeted = false
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionRow(
                library: library, session: item.session,
                rowKey: RowKey.pin(item.id), detail: detailText,
                onAddTask: startAdding
            )
            // Only the session's own row is dragged, so the tasks under it can drag themselves.
            .draggable("pin:\(item.id)")
            ForEach(item.tasks) { task in
                TaskRow(library: library, task: task, showsLink: false, list: item.tasks)
            }
            if library.addingTaskFor == item.id {
                addField
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(targeted ? 0.12 : 0))
        )
        // The whole card takes the drop: it is a bigger target than the row alone.
        .dropDestination(for: String.self) { items, location in
            guard let id = items.first.flatMap(DragPayload.pin) else { return false }
            library.movePin(id, in: library.pinned.map(\.id), nextTo: item.id, after: location.y > height / 2)
            return true
        } isTargeted: { targeted = $0 }
        .background(HeightReader { height = $0 })
        .onChange(of: focus.wrappedValue) { _, field in
            if field != .task(item.id), draft.isEmpty, library.addingTaskFor == item.id {
                library.addingTaskFor = nil
            }
        }
    }

    private var detailText: String {
        let open = item.openCount
        return open == 0 ? item.session.placeLabel : L10n.openTasksLine(item.session.placeLabel, open)
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            TextField(L10n.addTask, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus, equals: .task(item.id))
                .onSubmit(submit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func startAdding() {
        library.addingTaskFor = item.id
        DispatchQueue.main.async { focus.wrappedValue = .task(item.id) }
    }

    private func submit() {
        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            library.addingTaskFor = nil
            library.focusRequest += 1
        } else {
            library.addTask(draft, to: item.id)
            draft = ""
            DispatchQueue.main.async { focus.wrappedValue = .task(item.id) }
        }
    }
}

/// One task. Under a pinned session it shows its date; in the to-do list it also names the
/// session or project it is attached to.
struct TaskRow: View {
    @ObservedObject var library: Library
    let task: TaskItem
    /// The day the list around this row is about. A task planned for another day says which.
    var listedDay: String?
    /// False under a pinned session, whose name is already on the line above.
    var showsLink = true
    /// The tasks shown together with this one, in order. Among them, open tasks can be dragged.
    var list: [TaskItem] = []

    @State private var hovering = Snapshot.showsHover

    private var isOverdue: Bool {
        !task.done && task.due.map { $0 < library.today } == true
    }

    private var link: (symbol: String, title: String)? {
        showsLink ? library.linkTitle(for: task) : nil
    }

    /// The task's day, when it is not the day being listed.
    private var dateLabel: String? {
        guard let due = task.due, due != listedDay else { return nil }
        return library.dayLabel(due)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                library.toggle(task)
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(task.done ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.done ? L10n.markNotDone : L10n.markDone)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.text)
                    .font(.system(size: 12))
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
            Spacer(minLength: 4)
            if link != nil {
                Button {
                    library.run(task)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.startTaskInClaude)
                .opacity(hovering ? 1 : 0)
            }
            Button {
                library.delete(task)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.deleteTask)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .modifier(TaskOrdering(library: library, task: task, list: list))
    }

    /// What the task is attached to, and when it is due when that is another day.
    @ViewBuilder private var detail: some View {
        if link != nil || dateLabel != nil {
            HStack(spacing: 4) {
                if let link {
                    Image(systemName: link.symbol)
                        .font(.system(size: 9, weight: .medium))
                    Text(link.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if link != nil, dateLabel != nil {
                    Text("·")
                }
                if let dateLabel {
                    Text(dateLabel)
                        .foregroundStyle(isOverdue ? Color.orange : Color.secondary)
                        .fixedSize()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder private var menu: some View {
        Menu(L10n.date) {
            let tomorrow = Format.dayKey(Library.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            Toggle(L10n.today, isOn: isDue(library.today))
            Toggle(L10n.tomorrow, isOn: isDue(tomorrow))
            // Today and tomorrow are above; the rest of what the calendar shows follows.
            let upcoming = library.calendarDays.map(Format.dayKey).filter { $0 > tomorrow }
            if !upcoming.isEmpty {
                Divider()
                ForEach(upcoming, id: \.self) { day in
                    Toggle(library.dayLabel(day), isOn: isDue(day))
                }
            }
            Divider()
            Toggle(L10n.noDate, isOn: isDue(nil))
        }
        Menu(L10n.linkToProject) {
            ForEach(library.allProjects) { project in
                Button(project.name) { library.link(task, toProject: project.key) }
            }
            if !task.sessionID.isEmpty || task.projectKey != nil {
                Divider()
                Button(L10n.removeLink) { library.link(task, toProject: nil) }
            }
        }
        Divider()
        Button(L10n.delete, role: .destructive) { library.delete(task) }
    }

    private func isDue(_ day: String?) -> Binding<Bool> {
        Binding(
            get: { task.due == day },
            set: { _ in library.setDue(task, to: day) }
        )
    }
}

/// What a drag carries as plain text: what kind of thing it is and its id.
enum DragPayload {
    static func task(_ text: String) -> Int64? {
        text.prefix(5) == "task:" ? Int64(text.dropFirst(5)) : nil
    }

    static func pin(_ text: String) -> String? {
        text.prefix(4) == "pin:" ? String(text.dropFirst(4)) : nil
    }
}

/// Lets an open task be dragged onto another row of its list, above or below it, to change
/// the order.
struct TaskOrdering: ViewModifier {
    let library: Library
    let task: TaskItem
    let list: [TaskItem]

    @State private var targeted = false
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        if task.done || list.filter({ !$0.done }).count < 2 {
            content
        } else {
            content
                .draggable("task:\(task.id)")
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(targeted ? 0.16 : 0))
                )
                .dropDestination(for: String.self) { items, location in
                    guard let id = items.first.flatMap(DragPayload.task) else { return false }
                    library.moveTask(id, in: list, nextTo: task.id, after: location.y > height / 2)
                    return true
                } isTargeted: { targeted = $0 }
                .background(HeightReader { height = $0 })
        }
    }
}

/// Reports how tall the view it sits behind is. A drop uses that to tell the upper half of a
/// row from its lower one.
struct HeightReader: View {
    let report: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, value in report(value) }
        }
    }
}

// MARK: - This week

/// This week's work: a row for each day that had any, which opens onto the sessions used that day.
struct WeekSection: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    var body: some View {
        if library.showsWeek, !library.week.isEmpty {
            CollapsibleHeader(
                library: library, title: L10n.weekTitle,
                section: PanelSection.week,
                count: Set(library.week.flatMap(\.work).map(\.id)).count
            )
            if !library.isCollapsed(PanelSection.week) {
                ForEach(library.week) { day in
                    DayRow(library: library, day: day)
                    if library.isDayExpanded(day.day) {
                        ForEach(day.work) { work in
                            SessionRow(
                                library: library, session: work.session,
                                rowKey: RowKey.day(day.day, work.id),
                                detail: L10n.promptsLine(work.session.placeLabel, work.prompts),
                                inset: 16
                            )
                        }
                    }
                }
            }
        }
    }
}

/// One day of the week: how many sessions were used, and how much was asked in them.
struct DayRow: View {
    @ObservedObject var library: Library
    let day: DaySummary

    @State private var hovering = false

    var body: some View {
        let expanded = library.isDayExpanded(day.day)
        Button {
            withAnimation(.easeOut(duration: 0.15)) { library.toggleDay(day.day) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Text(library.dayLabel(day.day))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(L10n.daySummary(day.work.count, day.prompts))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? L10n.hideDay : L10n.showDay)
    }
}

// MARK: - Time

/// The colors projects are drawn in on the time charts. The busiest projects take them in turn;
/// the rest share a gray.
enum TimePalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo]
    static var count: Int { colors.count }

    static func color(_ index: Int?) -> Color {
        guard let index, colors.indices.contains(index) else { return Color.gray }
        return colors[index]
    }
}

/// How long each project was worked on: a chart of the period, then a row for each project.
struct TimeSection: View {
    @ObservedObject var library: Library

    @State private var showsAll = false
    private static let shown = 5

    var body: some View {
        if library.showsTime {
            let report = library.timeReport
            CollapsibleHeader(library: library, title: L10n.timeTitle, section: PanelSection.time) {
                periodButton(total: report.total)
            }
            if !library.isCollapsed(PanelSection.time) {
                if report.rows.isEmpty {
                    Text(L10n.noTimeYet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    let axis = DayAxis(report: report)
                    Group {
                        if library.timePeriod == .today {
                            DayTimeline(rows: report.rows, axis: axis)
                        } else {
                            DayColumns(report: report, compact: library.timePeriod == .month)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    let rows = showsAll ? report.rows : Array(report.rows.prefix(Self.shown))
                    let peak = report.rows.first?.total ?? 1
                    ForEach(rows) { row in
                        TimeRow(
                            library: library, row: row, peak: peak,
                            axis: library.timePeriod == .today ? axis : nil
                        )
                    }
                    if report.rows.count > rows.count {
                        Button {
                            showsAll = true
                        } label: {
                            Text(L10n.moreTimeRows(report.rows.count - rows.count))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Names the period and its total; a click moves on to the next period.
    private func periodButton(total: TimeInterval) -> some View {
        Button {
            library.timePeriod = library.timePeriod.next
        } label: {
            HStack(spacing: 5) {
                Text(library.timePeriod.title)
                    .foregroundStyle(.secondary)
                if total >= 60 {
                    Text(Format.worked(total))
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.changePeriod)
        .padding(.top, 10)
    }
}

/// The hours a day's timeline runs across: from the hour work began to the hour it is now,
/// and never less than four hours, so a short morning is not stretched across the panel.
struct DayAxis: Hashable {
    var start: Double
    var end: Double

    init(report: TimeReport) {
        let hour = 3600.0
        let first = report.rows.flatMap { $0.timed + $0.guessed }.map(\.start).min() ?? report.end
        var head = report.start + ((first - report.start) / hour).rounded(.down) * hour
        let tail = report.start + ((report.end - report.start) / hour).rounded(.up) * hour
        if tail - head < 4 * hour { head = max(report.start, tail - 4 * hour) }
        start = head
        end = max(tail, head + hour)
    }

    func fraction(_ stamp: Double) -> CGFloat {
        CGFloat(min(max((stamp - start) / (end - start), 0), 1))
    }

    /// The hours to name under the timeline, at most five of them.
    var marks: [Double] {
        let hours = Int(((end - start) / 3600).rounded())
        let step = max(1, Int((Double(hours) / 4).rounded(.up)))
        return stride(from: 0, through: hours, by: step).map { start + Double($0) * 3600 }
    }
}

/// Draws stretches of time along a day's axis. What the timer measured is drawn solid and
/// what the prompts suggest is drawn lighter.
struct TimeTrack: View {
    let rows: [ProjectTime]
    let axis: DayAxis
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                ForEach(rows) { row in
                    let color = TimePalette.color(row.color)
                    ForEach(row.guessed, id: \.self) { span in
                        piece(span, color.opacity(0.5), width: proxy.size.width)
                    }
                    ForEach(row.timed, id: \.self) { span in
                        piece(span, color, width: proxy.size.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        }
        .frame(height: height)
    }

    private func piece(_ span: TimeSpan, _ color: Color, width: CGFloat) -> some View {
        let head = axis.fraction(span.start) * width
        let tail = axis.fraction(span.end) * width
        return Rectangle()
            .fill(color)
            .frame(width: max(tail - head, 1.5))
            .offset(x: head)
    }
}

/// Every project's day on one line. Where several were worked on at once they share the
/// line's height, so no color hides another.
struct SharedTrack: View {
    let rows: [ProjectTime]
    let axis: DayAxis

    private static let height: CGFloat = 16

    private struct Slice: Hashable {
        var span: TimeSpan
        /// The colors of the projects at work in the span, the busiest first.
        var colors: [Int?]
    }

    /// Cuts the day wherever a project starts or stops, and notes who is at work in each piece.
    private var slices: [Slice] {
        let spans = rows.map { TimeMath.merged($0.timed + $0.guessed) }
        let cuts = Set(spans.flatMap { $0.flatMap { [$0.start, $0.end] } }).sorted()
        var slices: [Slice] = []
        for (head, tail) in zip(cuts, cuts.dropFirst()) {
            let middle = (head + tail) / 2
            let colors = rows.indices
                .filter { index in spans[index].contains { $0.start <= middle && middle < $0.end } }
                .map { rows[$0].color }
            if !colors.isEmpty { slices.append(Slice(span: TimeSpan(start: head, end: tail), colors: colors)) }
        }
        return slices
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                ForEach(slices, id: \.self) { slice in
                    let head = axis.fraction(slice.span.start) * proxy.size.width
                    let tail = axis.fraction(slice.span.end) * proxy.size.width
                    VStack(spacing: 0) {
                        ForEach(slice.colors.indices, id: \.self) { index in
                            Rectangle().fill(TimePalette.color(slice.colors[index]))
                        }
                    }
                    // A hair wider than its share, so neighbors meet without a seam.
                    .frame(width: max(tail - head + 0.5, 1.5))
                    .offset(x: head)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(height: Self.height)
    }
}

/// Today as one line: every project in its color, with the hours underneath.
struct DayTimeline: View {
    let rows: [ProjectTime]
    let axis: DayAxis

    var body: some View {
        VStack(spacing: 4) {
            SharedTrack(rows: rows, axis: axis)
            GeometryReader { proxy in
                let marks = axis.marks
                ForEach(marks.indices, id: \.self) { index in
                    let x = axis.fraction(marks[index]) * proxy.size.width
                    Text(Format.time(Date(timeIntervalSince1970: marks[index])))
                        .fixedSize()
                        .alignmentGuide(.leading) { size in
                            // The first hour hangs from its mark and the last one ends at it.
                            index == 0 ? 0 : (index == marks.count - 1 ? size.width : size.width / 2)
                        }
                        .offset(x: x)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 11)
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }
}

/// A week or a month as a column for each day, the projects stacked in their colors.
struct DayColumns: View {
    let report: TimeReport
    let compact: Bool

    private static let height: CGFloat = 46

    var body: some View {
        let peak = max(report.days.map(\.total).max() ?? 0, 1)
        let order = report.rows.map(\.key)
        let colors = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.key, TimePalette.color($0.color)) })
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: compact ? 2 : 6) {
                ForEach(report.days) { day in
                    column(day, peak: peak, order: order, colors: colors)
                }
            }
            .frame(height: Self.height, alignment: .bottom)
            HStack(spacing: compact ? 2 : 6) {
                ForEach(report.days) { day in
                    Text(label(day))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func column(_ day: DayTime, peak: TimeInterval, order: [String], colors: [String: Color]) -> some View {
        let total = day.total
        VStack(spacing: 0) {
            if total < 60 {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 2)
            } else {
                let full = max(4, Self.height * CGFloat(total / peak))
                VStack(spacing: 0) {
                    ForEach(order.reversed().filter { day.parts[$0] != nil }, id: \.self) { key in
                        Rectangle()
                            .fill(colors[key] ?? Color.gray)
                            .frame(height: full * CGFloat((day.parts[key] ?? 0) / total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: compact ? 1.5 : 3, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .help(Format.shortDay(day.date) + (total >= 60 ? " · " + Format.worked(total) : ""))
    }

    /// A week names every day; a month only the first of each week, where there is room.
    private func label(_ day: DayTime) -> String {
        let number = Library.calendar.component(.day, from: day.date)
        if compact { return (number - 1) % 7 == 0 ? "\(number)" : " " }
        return Format.weekday(day.date)
    }
}

/// One project in the time section: its color, its name and how long, with either its own
/// line on the day's axis or a bar measured against the busiest project.
struct TimeRow: View {
    @ObservedObject var library: Library
    let row: ProjectTime
    let peak: TimeInterval
    /// The day's axis, when the period is short enough to draw the project's own timeline.
    let axis: DayAxis?

    @State private var hovering = Snapshot.showsHover

    var body: some View {
        let running = library.isTiming(row.key)
        let color = TimePalette.color(row.color)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(row.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering || running {
                    IconButton(
                        symbol: running ? "stop.fill" : "play.fill",
                        help: running ? L10n.stopTimer : L10n.startTimer,
                        style: RowStyle(selected: false)
                    ) {
                        library.toggleTimer(forProject: row.key)
                    }
                }
                Text(Format.worked(row.total))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The project's own line sits under the shared one, on the same hours.
            if let axis {
                TimeTrack(rows: [row], axis: axis, height: 4)
            } else {
                bar(color).padding(.leading, 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(L10n.timeBreakdown(timer: Format.worked(row.manual), automatic: Format.worked(row.automatic)))
        .contextMenu {
            Button(running ? L10n.stopTimer : L10n.startTimer) { library.toggleTimer(forProject: row.key) }
            if let entry = library.lastTimeEntries[row.key] {
                Button(L10n.deleteLastEntry(Format.worked(entry.length))) {
                    library.deleteLastTimeEntry(forProject: row.key)
                }
            }
        }
    }

    /// The project against the busiest one. The part the timer measured is solid.
    private func bar(_ color: Color) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width * CGFloat(row.total / max(peak, 1)), 3)
            let timed = width * CGFloat(min(row.manual / max(row.total, 1), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.opacity(0.5)).frame(width: width)
                if timed >= 1 { Capsule().fill(color).frame(width: max(timed, 3)) }
            }
        }
        .frame(height: 4)
    }
}

/// The running timer, kept in view above the footer wherever the list is scrolled to.
struct TimerBar: View {
    @ObservedObject var library: Library
    let timer: RunningTimer

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            Text(timer.projectName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: timer.started, by: 1)) { context in
                Text(Format.clock(context.date.timeIntervalSince(timer.started)))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                library.stopTimer()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.09)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.stopTimer)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

/// A part of the panel the window can be dragged by.
struct WindowDragArea: NSViewRepresentable {
    final class Handle: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}
}

// MARK: - Tags and organizations

enum TagPalette {
    static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
    static var names: [String] { L10n.colorNames }

    static func color(_ index: Int) -> Color {
        colors[min(max(index, 0), colors.count - 1)]
    }
}

/// The small colored square that marks a tag. Square, so it is not mistaken for the round
/// indicator that shows a session is running.
struct TagMark: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

/// A tag in the filter row. Clicking it shows only the sessions that carry the tag.
struct TagChip: View {
    @ObservedObject var library: Library
    let tag: Tag

    var body: some View {
        let selected = library.tagFilter == tag.id
        let color = TagPalette.color(tag.color)
        Button {
            library.tagFilter = selected ? nil : tag.id
        } label: {
            HStack(spacing: 5) {
                TagMark(color: color)
                Text(tag.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(selected ? color.opacity(0.28) : Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.rename) {
                library.tagEditor = TagEditor(tagID: tag.id, name: tag.name, color: tag.color)
            }
            Menu(L10n.color) {
                ForEach(TagPalette.names.indices, id: \.self) { index in
                    Button(TagPalette.names[index]) { library.recolor(tag, to: index) }
                }
            }
            Divider()
            Button(L10n.deleteTag, role: .destructive) { library.delete(tag) }
        }
    }
}

/// Names a new tag or renames an existing one, and picks its color.
struct TagEditorRow: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    var body: some View {
        HStack(spacing: 9) {
            TextField(L10n.tagName, text: Binding(
                get: { library.tagEditor?.name ?? "" },
                set: { library.tagEditor?.name = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused(focus, equals: .tagName)
            .onSubmit { library.commitTagEditor() }

            ForEach(TagPalette.names.indices, id: \.self) { index in
                Button {
                    library.tagEditor?.color = index
                } label: {
                    Circle()
                        .fill(TagPalette.color(index))
                        .frame(width: 12, height: 12)
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(
                                Color.primary.opacity(library.tagEditor?.color == index ? 0.75 : 0), lineWidth: 1.5
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(TagPalette.names[index])
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
        .onAppear {
            DispatchQueue.main.async { focus.wrappedValue = .tagName }
        }
    }
}

/// Lets the user name their organizations, since Claude only stores the name of one.
struct OrganizationEditor: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(library.organizations) { organization in
                HStack(spacing: 8) {
                    TextField(L10n.accountName, text: Binding(
                        get: { drafts[organization.id] ?? organization.name },
                        set: { drafts[organization.id] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused(focus, equals: .organization(organization.id))
                    .onSubmit(save)
                    Text(L10n.accountState(organization.sessionCount, current: organization.isCurrent))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
            if hasChanges {
                HStack {
                    Spacer()
                    Button(L10n.saveNames, action: save)
                        .controlSize(.small)
                }
            }
        }
    }

    private var hasChanges: Bool {
        library.organizations.contains { organization in
            drafts[organization.id].map { $0 != organization.name } ?? false
        }
    }

    private func save() {
        for organization in library.organizations {
            if let draft = drafts[organization.id] { library.rename(organization, to: draft) }
        }
        drafts = [:]
        focus.wrappedValue = nil
    }
}

// MARK: - Detail card

/// Reports the row to the library once the pointer has rested on it, so its details can be shown
/// level with the pointer. Moving to another row while a card is up switches without the wait.
struct HoverDetail: ViewModifier {
    let library: Library
    let subject: HoverSubject

    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pending?.cancel()
            pending = nil
            if inside {
                let work = DispatchWorkItem {
                    library.hover = HoverTarget(subject: subject, screenY: NSEvent.mouseLocation.y)
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (library.hover == nil ? 0.7 : 0.05), execute: work)
            } else {
                // Leave the card up for a moment, so the next row can take it over.
                let work = DispatchWorkItem {
                    if library.hover?.subject.key == subject.key { library.hover = nil }
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        }
    }
}

/// The facts about one session or project, shown beside the panel.
struct DetailCard: View {
    static let width: CGFloat = 320

    @ObservedObject var library: Library
    let subject: HoverSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch subject {
            case .session(let session): sessionBody(session)
            case .project(let project): projectBody(project)
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: Session

    @ViewBuilder private func sessionBody(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(session.placeLabel)
                    .foregroundStyle(.secondary)
                if let live = library.live[session.id] {
                    Text("·").foregroundStyle(.tertiary)
                    LiveIndicator(live: live, selected: false)
                    Text(live.label + (live.isInTerminal ? L10n.inTerminal : L10n.inClaude))
                }
            }
            .font(.system(size: 11))
            let tags = library.tags(for: session)
            if !tags.isEmpty {
                HStack(spacing: 10) {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            TagMark(color: TagPalette.color(tag.color))
                            Text(tag.name).font(.system(size: 11))
                        }
                    }
                }
                .padding(.top, 1)
            }
        }

        if let context = session.contextTokens {
            ContextGauge(tokens: context)
        }

        HStack(spacing: 6) {
            StatTile(value: Format.count(session.messageCount), label: L10n.prompts)
            StatTile(value: series?.worked.map(Format.worked) ?? "—", label: L10n.worked)
            StatTile(value: Format.bytes(session.fileSize), label: L10n.size)
        }

        section(L10n.tokens) {
            HStack(spacing: 6) {
                StatTile(value: Format.tokens(session.inputTokens), label: L10n.input)
                StatTile(value: Format.tokens(session.cachedTokens), label: L10n.cache)
                StatTile(value: Format.tokens(session.outputTokens), label: L10n.output)
            }
        }

        section(L10n.activity) { activityChart }

        VStack(alignment: .leading, spacing: 5) {
            if let model = session.model { fact("cpu", model) }
            if let branch = session.branch, branch != "HEAD" { fact("arrow.triangle.branch", branch) }
            if let number = session.prNumber { fact("arrow.triangle.pull", "Pull request #\(number)") }
            fact("folder", Format.path(session.cwd))
        }

        if let prompt = session.lastPrompt, !prompt.isEmpty {
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.18)).frame(width: 2)
                }
        }
    }

    /// The chart and total for what the card describes, once they have been read.
    private var series: ActivitySeries? {
        library.hoverActivity?.key == subject.key ? library.hoverActivity : nil
    }

    // MARK: Project

    @ViewBuilder private func projectBody(_ project: ProjectGroup) -> some View {
        let sessions = project.sessions
        VStack(alignment: .leading, spacing: 5) {
            Text(project.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            Text(L10n.lastActivity(Format.date(project.lastActivity)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
            StatTile(value: Format.count(sessions.count), label: L10n.chats)
            StatTile(value: Format.count(sessions.reduce(0) { $0 + $1.messageCount }), label: L10n.prompts)
            StatTile(value: Format.bytes(sessions.reduce(0) { $0 + $1.fileSize }), label: L10n.size)
        }

        section(L10n.tokens) {
            HStack(spacing: 6) {
                StatTile(value: Format.tokens(sessions.reduce(0) { $0 + $1.inputTokens }), label: L10n.input)
                StatTile(value: Format.tokens(sessions.reduce(0) { $0 + $1.cachedTokens }), label: L10n.cache)
                StatTile(value: Format.tokens(sessions.reduce(0) { $0 + $1.outputTokens }), label: L10n.output)
            }
        }

        section(L10n.timeTitle) {
            HStack(spacing: 6) {
                StatTile(value: worked(on: project, in: .today), label: L10n.today)
                StatTile(value: worked(on: project, in: .week), label: L10n.weekTitle)
                StatTile(value: series?.worked.map(Format.worked) ?? "—", label: L10n.totalTime)
            }
        }

        section(L10n.last30Days) { activityChart }

        if !project.folders.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(project.folders.prefix(5), id: \.self) { folder in
                    fact("folder", Format.path(folder))
                }
                if project.folders.count > 5 {
                    Text(L10n.moreFolders(project.folders.count - 5))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private func worked(on project: ProjectGroup, in period: TimePeriod) -> String {
        library.time(for: project.key, in: period).map { Format.worked($0.total) } ?? "—"
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var activityChart: some View {
        VStack(spacing: 4) {
            ActivityChart(buckets: series?.buckets ?? Array(repeating: 0, count: Library.activityBuckets))
            HStack {
                Text(series?.startLabel ?? " ")
                Spacer()
                Text(series?.endLabel ?? " ")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// One figure with its label, sized so three sit side by side.
struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// How full the context was on the session's latest turn, on a fixed scale up to one million
/// tokens with a mark at 200K, the two context sizes Claude Code runs with.
struct ContextGauge: View {
    let tokens: Int

    private static let scale = 1_000_000.0
    private static let mark = 200_000.0

    var body: some View {
        let fraction = min(Double(tokens) / Self.scale, 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.context)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.tokens(tokens) + " " + L10n.tokenWord)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(fraction > 0.8 ? Color.orange : Color.accentColor)
                        .frame(width: max(proxy.size.width * fraction, 6))
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: 10)
                        .offset(x: proxy.size.width * Self.mark / Self.scale)
                }
            }
            .frame(height: 6)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Text("200K").offset(x: proxy.size.width * Self.mark / Self.scale - 11)
                    Text("1M").frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 11)
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }
}

/// A row of bars, one per slice of time, scaled to the busiest slice.
struct ActivityChart: View {
    let buckets: [Int]

    private static let height: CGFloat = 34

    var body: some View {
        let peak = max(buckets.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(buckets.indices, id: \.self) { index in
                let count = buckets[index]
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(count == 0 ? Color.primary.opacity(0.10) : Color.accentColor)
                    .frame(height: count == 0 ? 2 : max(4, Self.height * CGFloat(count) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.height, alignment: .bottom)
    }
}

// MARK: - Prompt outline

/// Everything the user asked in one session, oldest first, grouped by day.
struct OutlineView: View {
    @ObservedObject var library: Library
    let outline: SessionOutline

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if outline.entries.isEmpty {
                Text(L10n.outlineEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(days, id: \.title) { day in
                            SectionHeader(title: day.title)
                            ForEach(day.entries) { entry in
                                OutlineRow(library: library, entry: entry)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                library.closeOutline()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.back)
            VStack(alignment: .leading, spacing: 2) {
                Text(outline.session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.promptsLine(outline.session.placeLabel, outline.entries.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 3)
            Spacer(minLength: 8)
            Button(L10n.open) { library.open(outline.session) }
                .controlSize(.small)
                .help(L10n.openChat)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var days: [(title: String, entries: [OutlineEntry])] {
        var groups: [(title: String, entries: [OutlineEntry])] = []
        for entry in outline.entries {
            let title = entry.date.map(Format.day) ?? L10n.noDate
            if groups.last?.title == title {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((title, [entry]))
            }
        }
        return groups
    }
}

struct OutlineRow: View {
    @ObservedObject var library: Library
    let entry: OutlineEntry

    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Format.time(entry.date))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 12))
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            Button(L10n.copy) {
                Opener.copy(entry.text)
                library.show(notice: L10n.promptCopied)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    library.cancelShortcutRecording()
                    library.showingSettings = false
                    library.focusRequest += 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.back)
                Text(L10n.settingsTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsGroup {
                        VStack(spacing: 0) {
                            SettingsRow(title: L10n.openPanelShortcut) { shortcutButton(.panel) }
                            SettingsRow(title: L10n.quickTaskShortcut) { shortcutButton(.quickTask) }
                            SettingsRow(title: L10n.quickNoteShortcut) { shortcutButton(.quickNote) }
                        }
                    }
                    SettingsGroup {
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
                    }
                    SettingsGroup {
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
                    }
                    SettingsGroup {
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
                    SettingsGroup {
                        SettingsRow(title: L10n.notifications) {
                            Toggle("", isOn: $library.notificationsEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingsGroup {
                        SettingsRow(title: L10n.showTodos) {
                            Toggle("", isOn: $library.showsTodos)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingsGroup {
                        SettingsRow(title: L10n.showWeek) {
                            Toggle("", isOn: $library.showsWeek)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingsGroup {
                        VStack(spacing: 0) {
                            SettingsRow(title: L10n.showTime) {
                                Toggle("", isOn: $library.showsTime)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                            SettingsRow(title: L10n.automaticTime) {
                                Toggle("", isOn: $library.tracksTimeAutomatically)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                            if library.tracksTimeAutomatically {
                                SettingsRow(title: L10n.idleGap) {
                                    Picker(L10n.idleGap, selection: $library.idleGapMinutes) {
                                        ForEach(Library.idleGapChoices, id: \.self) { minutes in
                                            Text(L10n.minutes(minutes)).tag(minutes)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .fixedSize()
                                }
                            }
                        }
                    }
                    SettingsGroup {
                        VStack(spacing: 0) {
                            SettingsRow(title: L10n.themeTitle) {
                                Picker(L10n.themeTitle, selection: $library.appearanceChoice) {
                                    Text(L10n.systemLanguage).tag("")
                                    Text(L10n.themeLight).tag("light")
                                    Text(L10n.themeDark).tag("dark")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                            SettingsRow(title: L10n.languageTitle) {
                                Picker(L10n.languageTitle, selection: $library.languageChoice) {
                                    Text(L10n.systemLanguage).tag("")
                                    Text("Türkçe").tag("tr")
                                    Text("English").tag("en")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }
                    SettingsGroup {
                        VStack(spacing: 0) {
                            SettingsRow(title: L10n.versionTitle(library.installedVersion)) {
                                updateStatus
                                Button(L10n.checkNow) { library.checkForUpdates() }
                                    .controlSize(.small)
                                    .disabled(library.updateState == .checking)
                            }
                            SettingsRow(title: L10n.releaseNotes) {
                                Button(L10n.view) { library.showingReleaseNotes = true }
                                    .controlSize(.small)
                            }
                            SettingsRow(title: L10n.checkAutomatically) {
                                Toggle("", isOn: $library.checksForUpdates)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                        }
                    }
                    if library.backupCount > 0 {
                        SettingsGroup {
                            SettingsRow(title: L10n.backups(library.backupCount, Format.bytes(library.backupBytes))) {
                                Button(L10n.show) { Opener.revealFolder(Retention.folder.path) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    SettingsGroup {
                        SettingsRow(title: L10n.showAccounts) {
                            Toggle("", isOn: $library.showsOrganizations)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    if library.showsOrganizations {
                        if library.organizations.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.accountNames)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                OrganizationEditor(library: library, focus: focus)
                            }
                        } else {
                            Text(L10n.oneOrganization)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                    if !library.hiddenProjectList.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.hiddenProjects)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            SettingsGroup {
                                VStack(spacing: 0) {
                                    ForEach(library.hiddenProjectList) { project in
                                        HStack {
                                            Text(project.name)
                                                .font(.system(size: 13))
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            Button(L10n.bringBack) { library.unhide(project) }
                                                .controlSize(.small)
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(height: 34)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// What the last check found, beside the button that checks again.
    @ViewBuilder private var updateStatus: some View {
        switch library.updateState {
        case .unknown:
            EmptyView()
        case .checking:
            statusLabel(L10n.checking, .secondary)
        case .current:
            statusLabel(L10n.upToDate, .secondary)
        case .failed:
            statusLabel(L10n.checkFailed, .secondary)
        case .available(let version):
            Button {
                library.showingReleaseNotes = true
            } label: {
                statusLabel(L10n.updateAvailable(version), Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func statusLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func shortcutButton(_ kind: ShortcutKind) -> some View {
        let recording = library.recordingKind == kind
        return Button {
            if recording {
                library.cancelShortcutRecording()
            } else {
                library.beginShortcutRecording(kind)
            }
        } label: {
            Text(shortcutText(kind))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(recording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .padding(.horizontal, 10)
                .frame(minWidth: 96, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(recording ? 0.04 : 0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(recording ? 0.8 : 0), lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? L10n.escToCancel : L10n.changeShortcut)
    }

    private func shortcutText(_ kind: ShortcutKind) -> String {
        if library.recordingKind == kind { return L10n.pressKeys }
        let label = library.shortcutLabels[kind] ?? ""
        return label.isEmpty ? L10n.notAssigned : label
    }
}

/// What changed in each version, as its release on GitHub describes it.
struct ReleaseNotesView: View {
    @ObservedObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    library.showingReleaseNotes = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.back)
                Text(L10n.releaseNotes)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(WindowDragArea())

            if library.releases.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(library.releases) { release in
                            card(release)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyText: String {
        switch library.updateState {
        case .checking, .unknown: return L10n.checking
        case .failed: return L10n.checkFailed
        default: return L10n.noReleases
        }
    }

    private func card(_ release: Release) -> some View {
        let isNew = Updates.isNewer(release.version, than: library.installedVersion) && library.availableUpdate != nil
        let isInstalled = release.version == library.installedVersion
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(release.version)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if isNew {
                    badge(L10n.newBadge, Color.accentColor)
                } else if isInstalled {
                    badge(L10n.installedBadge, Color.secondary)
                }
                Spacer(minLength: 8)
                if let date = release.date {
                    Text(Format.releaseDate(date))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.lines(of: release.notes).enumerated()), id: \.offset) { _, line in
                    if line.bullet {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(line.text).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(line.text)
                            .fontWeight(line.heading ? .semibold : .regular)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12))
            if isNew, let url = URL(string: release.url) {
                Button(L10n.openOnGitHub) { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    /// The notes line by line, with Markdown's list and heading marks taken as what they mean.
    static func lines(of notes: String) -> [(text: AttributedString, bullet: Bool, heading: Bool)] {
        notes.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            var bullet = false, heading = false
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                bullet = true
                line = String(line.dropFirst(2))
            } else if line.hasPrefix("#") {
                heading = true
                line = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            }
            let text = (try? AttributedString(markdown: line)) ?? AttributedString(line)
            return (text, bullet, heading)
        }
    }
}

/// One rounded block of settings rows.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}

// MARK: - Projects

struct ProjectSection: View {
    @ObservedObject var library: Library
    let project: ProjectGroup
    var focus: FocusState<PanelField?>.Binding

    @State private var hovering = Snapshot.showsHover
    @State private var draft = ""

    var body: some View {
        let expanded = library.expanded.contains(project.key)
        VStack(alignment: .leading, spacing: 1) {
            header(expanded: expanded)
            if expanded {
                let visible = library.visibleSessions(in: project)
                let repeated = repeatedTitles(in: visible)
                ForEach(visible) { session in
                    SessionRow(
                        library: library, session: session,
                        rowKey: RowKey.project(session.id),
                        detail: repeated.contains(session.title) ? firstLine(session.lastPrompt) : nil,
                        inset: 16
                    )
                }
                if visible.count < project.sessions.count {
                    Button {
                        library.showingAll.insert(project.key)
                    } label: {
                        Text(L10n.moreSessions(project.sessions.count - visible.count))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 24)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Sessions that share a title get their last prompt as a second line, so they can be told apart.
    private func repeatedTitles(in sessions: ArraySlice<SessionRecord>) -> Set<String> {
        var counts: [String: Int] = [:]
        for session in sessions { counts[session.title, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map { String($0) }
    }

    private func header(expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            if library.renamingProject == project.key {
                TextField(L10n.projectName, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused(focus, equals: .rename(project.key))
                    .onSubmit { library.rename(project, to: draft) }
                    .onAppear {
                        draft = project.name
                        DispatchQueue.main.async { focus.wrappedValue = .rename(project.key) }
                    }
            } else {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(project.sessions.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hovering || library.isTiming(project.key) {
                let timing = library.isTiming(project.key)
                IconButton(
                    symbol: timing ? "stop.fill" : "play.fill",
                    help: timing ? L10n.stopTimer : L10n.startTimer, style: RowStyle(selected: false)
                ) {
                    library.toggleTimer(forProject: project.key)
                }
            }
            if hovering {
                IconButton(symbol: "terminal", help: L10n.startChatHere, style: RowStyle(selected: false)) {
                    library.startSession(in: project)
                }
            }
            Text(RelativeTime.short(project.lastActivity))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { library.toggleExpanded(project.key) }
        }
        .contextMenu { menu }
        .modifier(HoverDetail(library: library, subject: .project(project)))
    }

    @ViewBuilder private var menu: some View {
        Button(L10n.startChat) { library.startSession(in: project) }
        Button(L10n.addTask) { library.beginTask(linkedTo: .project(key: project.key, name: project.name)) }
        Button(library.isTiming(project.key) ? L10n.stopTimer : L10n.startTimer) {
            library.toggleTimer(forProject: project.key)
        }
        Menu(L10n.openMethodMenu) {
            Toggle(L10n.useGeneralSetting, isOn: Binding(
                get: { library.projectOpenMethods[project.key] == nil },
                set: { _ in library.setOpenMethod(nil, for: project) }
            ))
            Divider()
            ForEach(library.openMethods, id: \.self) { method in
                Toggle(method.title, isOn: Binding(
                    get: { library.projectOpenMethods[project.key] == method },
                    set: { _ in library.setOpenMethod(method, for: project) }
                ))
            }
        }
        Button(L10n.rename) { library.renamingProject = project.key }
        Menu(L10n.mergeInto) {
            ForEach(library.allProjects.filter { $0.key != project.key }) { other in
                Button(other.name) { library.merge(project, into: other) }
            }
        }
        if !project.mergedKeys.isEmpty {
            Button(L10n.undoMerge) { library.separate(project) }
        }
        Divider()
        Button(L10n.hide) { library.hide(project) }
        if let folder = project.folders.first {
            Button(L10n.showInFinder) { Opener.revealFolder(folder) }
        }
    }
}

/// Sorts and filters the project list. The choices stay as they are left, and the icon is
/// tinted while anything is being left out.
struct ProjectListMenu: View {
    @ObservedObject var library: Library

    var body: some View {
        // AppKit draws a menu's label in its own color, so the icon is drawn here and the menu
        // on top of it has a clear label: it takes the click and shows nothing.
        Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(leavesSomethingOut ? Color.accentColor : Color.secondary)
            .frame(width: 22, height: 22)
            .overlay {
                Menu { choices } label: { Color.clear.frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L10n.sortOrFilter)
            }
    }

    @ViewBuilder private var choices: some View {
        Menu(L10n.sortBy) {
            ForEach(ProjectSort.allCases, id: \.self) { sort in
                Toggle(sort.title, isOn: Binding(
                    get: { library.projectSort == sort },
                    set: { _ in library.projectSort = sort }
                ))
            }
        }
        Divider()
        Toggle(L10n.hideSingleSessionProjects, isOn: $library.hidesSingleSessionProjects)
        Toggle(L10n.hideInactiveProjects, isOn: $library.hidesInactiveProjects)
        if !library.hiddenProjects.isEmpty {
            Divider()
            Button(L10n.manageHidden) { library.showingSettings = true }
        }
    }

    private var leavesSomethingOut: Bool {
        library.hidesSingleSessionProjects || library.hidesInactiveProjects || !library.hiddenProjects.isEmpty
    }
}
