import SwiftUI

enum PanelField: Hashable {
    case search
    case task(String)
    case rename(String)
    case tagName
    case organization(String)
    case todo
}

/// Places in the panel's list that are scrolled to by name.
enum ScrollAnchor: Hashable {
    static let top = "top"
}

struct PanelView: View {
    @ObservedObject var library: Library
    let close: () -> Void
    @FocusState private var focus: PanelField?

    var body: some View {
        VStack(spacing: 0) {
            if library.showingSettings {
                SettingsView(library: library, focus: $focus)
            } else if let outline = library.outline {
                OutlineView(library: library, outline: outline)
            } else {
                searchBar
                filterBar
                content
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
            TextField("Sohbetlerde ara", text: $library.query)
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
                .help("Aramayı temizle")
            }
            Menu {
                Button("Yenile") { library.refresh() }
                Button("Yeni etiket…") { library.tagEditor = TagEditor() }
                Button("Ayarlar…") { library.showingSettings = true }
                Divider()
                Button("Respool'dan çık") { NSApp.terminate(nil) }
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
    }

    // MARK: - Filters

    @ViewBuilder private var filterBar: some View {
        let showsOrganizations = library.showsOrganizations && library.organizations.count > 1
        let showsTags = library.tagEditor != nil || !library.tags.isEmpty
        if showsOrganizations || showsTags {
            VStack(alignment: .leading, spacing: 8) {
                if showsOrganizations {
                    Picker("Hesap", selection: $library.organizationFilter) {
                        Text("Tümü").tag(String?.none)
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
            }
        }
    }

    @ViewBuilder private var browseRows: some View {
        if library.showsTodos {
            TodoSection(library: library, focus: $focus)
        }

        if !library.pinned.isEmpty {
            CollapsibleHeader(
                library: library, title: "Sabitlenenler",
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
                library: library, title: "Son sohbetler",
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

        CollapsibleHeader(
            library: library, title: "Projeler",
            section: PanelSection.projects, count: library.projects.count
        ) {
            ProjectListMenu(library: library)
        }
        if !library.isCollapsed(PanelSection.projects) {
            ForEach(library.projects) { project in
                ProjectSection(library: library, project: project, focus: $focus)
            }
            if library.projects.isEmpty, !library.allProjects.isEmpty {
                Text("Bütün projeler gizli ya da süzülüyor.")
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
                Text("Sonuç yok")
                    .font(.system(size: 13, weight: .medium))
                Text("“\(library.query)” hiçbir sohbette geçmiyor.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.horizontal, 24)
        } else {
            SectionHeader(title: "\(results.count) sohbet")
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
                Text("Bu etikette sohbet yok")
                    .font(.system(size: 13, weight: .medium))
                Text("Bir sohbete sağ tıklayıp Etiketler menüsünden “\(name)” etiketini verin.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .padding(.horizontal, 24)
        } else {
            SectionHeader(title: "\(name) · \(sessions.count) sohbet")
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
                Text("Sohbetler dizine ekleniyor")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 6)
                Text("\(progress.done) / \(progress.total)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Henüz sohbet yok")
                    .font(.system(size: 13, weight: .medium))
                Text("Claude Code'da bir sohbet başlattığınızda burada görünür.")
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
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var statusText: String {
        if let notice = library.notice { return notice }
        if let progress = library.indexing, progress.total > 0 {
            return "Dizine ekleniyor \(progress.done) / \(progress.total)"
        }
        // Says how many projects are left out, when the list is thinner than the index.
        let shown = library.projects.count, total = library.allProjects.count
        let projects = shown == total ? "\(shown)" : "\(shown)/\(total)"
        return "\(library.sessionCount) sohbet · \(projects) proje"
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
            .help(collapsed ? "Bölümü göster" : "Bölümü gizle")
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
                        IconButton(symbol: "plus", help: "Görev ekle", style: style, action: onAddTask)
                    }
                    IconButton(symbol: "list.bullet", help: "İstem dökümü", style: style) {
                        library.showOutline(for: session)
                    }
                    IconButton(
                        symbol: pinned ? "pin.slash" : "pin",
                        help: pinned ? "Sabitlemeyi kaldır" : "Sabitle",
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
        Button("Claude uygulamasında aç") { library.openInDesktop(session) }
        Button("Terminalde sürdür") {
            if !Opener.openInTerminal(session) { library.show(notice: "Terminal açılamadı") }
        }
        .disabled(live != nil)
        Button("İstem dökümü") { library.showOutline(for: session) }
        Divider()
        Button(pinned ? "Sabitlemeyi kaldır" : "Sabitle") { library.togglePin(session) }
        Button("Görev ekle") { library.beginTask(linkedTo: .session(id: session.id, title: session.title)) }
        Menu("Etiketler") {
            ForEach(library.tags) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { session.tagIDs.contains(tag.id) },
                    set: { _ in library.toggle(tag, on: session) }
                ))
            }
            if !library.tags.isEmpty { Divider() }
            Button("Yeni etiket…") { library.tagEditor = TagEditor(sessionID: session.id) }
        }
        Divider()
        Button("Klasörü Finder'da göster") { Opener.revealFolder(session.cwd) }
        Button("Oturum kimliğini kopyala") { Opener.copy(session.id) }
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
            library: library, title: "Yapılacaklar",
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
            groupTitle("Gecikmiş")
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
            groupTitle("Tarihsiz")
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
            TextField("Görev ekle", text: $draft)
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
                .help("Yeni görevler bu güne eklenir. Başka bir gün için takvimden gün seçin.")
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
            .help("Bağlantıyı kaldır")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help("Görev buna bağlanacak: \(link.title)")
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
            arrow("chevron.left", expanded ? "Önceki ay" : "Önceki hafta", step: -1)
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
            .help(expanded ? "Hafta görünümüne geç" : "Ay görünümüne geç")
            arrow("chevron.right", expanded ? "Sonraki ay" : "Sonraki hafta", step: 1)
            Spacer(minLength: 4)
            Button("Bugün") { withAnimation(.easeOut(duration: 0.15)) { library.showToday() } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .contentShape(Rectangle())
                .help("Bugüne dön")
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
        return open == 0 ? item.session.placeLabel : "\(item.session.placeLabel) · \(open) açık görev"
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            TextField("Görev ekle", text: $draft)
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
            .help(task.done ? "Yapılmadı olarak işaretle" : "Tamamlandı olarak işaretle")

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
                .help("Görevi Claude'da başlat")
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
            .help("Görevi sil")
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
        Menu("Tarih") {
            let tomorrow = Format.dayKey(Library.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            Toggle("Bugün", isOn: isDue(library.today))
            Toggle("Yarın", isOn: isDue(tomorrow))
            // Today and tomorrow are above; the rest of what the calendar shows follows.
            let upcoming = library.calendarDays.map(Format.dayKey).filter { $0 > tomorrow }
            if !upcoming.isEmpty {
                Divider()
                ForEach(upcoming, id: \.self) { day in
                    Toggle(library.dayLabel(day), isOn: isDue(day))
                }
            }
            Divider()
            Toggle("Tarihsiz", isOn: isDue(nil))
        }
        Menu("Projeye bağla") {
            ForEach(library.allProjects) { project in
                Button(project.name) { library.link(task, toProject: project.key) }
            }
            if !task.sessionID.isEmpty || task.projectKey != nil {
                Divider()
                Button("Bağlantıyı kaldır") { library.link(task, toProject: nil) }
            }
        }
        Divider()
        Button("Sil", role: .destructive) { library.delete(task) }
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

// MARK: - Tags and organizations

enum TagPalette {
    static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
    static let names = ["Kırmızı", "Turuncu", "Sarı", "Yeşil", "Mavi", "Mor", "Gri"]

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
            Button("Yeniden adlandır") {
                library.tagEditor = TagEditor(tagID: tag.id, name: tag.name, color: tag.color)
            }
            Menu("Renk") {
                ForEach(TagPalette.names.indices, id: \.self) { index in
                    Button(TagPalette.names[index]) { library.recolor(tag, to: index) }
                }
            }
            Divider()
            Button("Etiketi sil", role: .destructive) { library.delete(tag) }
        }
    }
}

/// Names a new tag or renames an existing one, and picks its color.
struct TagEditorRow: View {
    @ObservedObject var library: Library
    var focus: FocusState<PanelField?>.Binding

    var body: some View {
        HStack(spacing: 9) {
            TextField("Etiket adı", text: Binding(
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
                    TextField("Hesap adı", text: Binding(
                        get: { drafts[organization.id] ?? organization.name },
                        set: { drafts[organization.id] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused(focus, equals: .organization(organization.id))
                    .onSubmit(save)
                    Text(organization.isCurrent ? "şu an açık · \(organization.sessionCount)" : "\(organization.sessionCount)")
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
                    Button("Adları kaydet", action: save)
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
                    Text(live.label + (live.isInTerminal ? ", terminalde" : ", Claude'da"))
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
            StatTile(value: Format.count(session.messageCount), label: "İstem")
            StatTile(value: duration(of: session), label: "Süre")
            StatTile(value: Format.bytes(session.fileSize), label: "Boyut")
        }

        section("Token") {
            HStack(spacing: 6) {
                StatTile(value: Format.tokens(session.inputTokens), label: "Girdi")
                StatTile(value: Format.tokens(session.cachedTokens), label: "Önbellek")
                StatTile(value: Format.tokens(session.outputTokens), label: "Çıktı")
            }
        }

        section("Etkinlik") { activityChart }

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

    private func duration(of session: SessionRecord) -> String {
        guard let first = session.firstActivity, let last = session.lastActivity else { return "—" }
        return Format.duration(last.timeIntervalSince(first))
    }

    // MARK: Project

    @ViewBuilder private func projectBody(_ project: ProjectGroup) -> some View {
        let sessions = project.sessions
        VStack(alignment: .leading, spacing: 5) {
            Text(project.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            Text("Son etkinlik " + Format.date(project.lastActivity))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
            StatTile(value: Format.count(sessions.count), label: "Sohbet")
            StatTile(value: Format.count(sessions.reduce(0) { $0 + $1.messageCount }), label: "İstem")
            StatTile(value: Format.bytes(sessions.reduce(0) { $0 + $1.fileSize }), label: "Boyut")
        }

        section("Token") {
            HStack(spacing: 6) {
                StatTile(value: Format.tokens(sessions.reduce(0) { $0 + $1.inputTokens }), label: "Girdi")
                StatTile(value: Format.tokens(sessions.reduce(0) { $0 + $1.cachedTokens }), label: "Önbellek")
                StatTile(value: Format.tokens(sessions.reduce(0) { $0 + $1.outputTokens }), label: "Çıktı")
            }
        }

        section("Son 30 gün") { activityChart }

        if !project.folders.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(project.folders.prefix(5), id: \.self) { folder in
                    fact("folder", Format.path(folder))
                }
                if project.folders.count > 5 {
                    Text("ve \(project.folders.count - 5) klasör daha")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                }
            }
        }
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
        let series = library.hoverActivity?.key == subject.key ? library.hoverActivity : nil
        return VStack(spacing: 4) {
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
                Text("Bağlam")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.tokens(tokens) + " token")
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
                Text("Bu sohbette yazılmış bir istem bulunamadı.")
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
            .help("Geri")
            VStack(alignment: .leading, spacing: 2) {
                Text(outline.session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(outline.session.placeLabel) · \(outline.entries.count) istem")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 3)
            Spacer(minLength: 8)
            Button("Aç") { library.open(outline.session) }
                .controlSize(.small)
                .help("Sohbeti aç")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var days: [(title: String, entries: [OutlineEntry])] {
        var groups: [(title: String, entries: [OutlineEntry])] = []
        for entry in outline.entries {
            let title = entry.date.map(Format.day) ?? "Tarihsiz"
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
            Button("Kopyala") {
                Opener.copy(entry.text)
                library.show(notice: "İstem kopyalandı")
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
                .help("Geri")
                Text("Ayarlar")
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
                        SettingsRow(title: "Kısayol") { shortcutButton }
                    }
                    SettingsGroup {
                        SettingsRow(title: "Girişte başlat") {
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
                        SettingsRow(title: "Bildirimler") {
                            Toggle("", isOn: $library.notificationsEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingsGroup {
                        SettingsRow(title: "Yapılacakları göster") {
                            Toggle("", isOn: $library.showsTodos)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    SettingsGroup {
                        SettingsRow(title: "Hesapları göster") {
                            Toggle("", isOn: $library.showsOrganizations)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    if library.showsOrganizations {
                        if library.organizations.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Hesap adları")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                OrganizationEditor(library: library, focus: focus)
                            }
                        } else {
                            Text("Bu bilgisayarda tek bir organizasyonun sohbetleri var; seçici görünmeyecek.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                    if !library.hiddenProjectList.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gizli projeler")
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
                                            Button("Geri getir") { library.unhide(project) }
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

    private var shortcutButton: some View {
        Button {
            if library.recordingShortcut {
                library.cancelShortcutRecording()
            } else {
                library.beginShortcutRecording()
            }
        } label: {
            Text(shortcutText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(library.recordingShortcut ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .padding(.horizontal, 10)
                .frame(minWidth: 96, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(library.recordingShortcut ? 0.04 : 0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(library.recordingShortcut ? 0.8 : 0), lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(library.recordingShortcut ? "Vazgeçmek için esc" : "Kısayolu değiştir")
    }

    private var shortcutText: String {
        if library.recordingShortcut { return "Tuşlara basın…" }
        return library.shortcutLabel.isEmpty ? "Atanmadı" : library.shortcutLabel
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
                        Text("\(project.sessions.count - visible.count) sohbet daha")
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
                TextField("Proje adı", text: $draft)
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
            if hovering {
                IconButton(symbol: "terminal", help: "Bu projede yeni sohbet başlat", style: RowStyle(selected: false)) {
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
        Button("Yeni sohbet başlat") { library.startSession(in: project) }
        Button("Görev ekle") { library.beginTask(linkedTo: .project(key: project.key, name: project.name)) }
        Button("Yeniden adlandır") { library.renamingProject = project.key }
        Menu("Şununla birleştir") {
            ForEach(library.allProjects.filter { $0.key != project.key }) { other in
                Button(other.name) { library.merge(project, into: other) }
            }
        }
        if !project.mergedKeys.isEmpty {
            Button("Birleştirmeyi geri al") { library.separate(project) }
        }
        Divider()
        Button("Gizle") { library.hide(project) }
        if let folder = project.folders.first {
            Button("Klasörü Finder'da göster") { Opener.revealFolder(folder) }
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
                    .help("Projeleri sırala ya da süz")
            }
    }

    @ViewBuilder private var choices: some View {
        Menu("Sıralama") {
            ForEach(ProjectSort.allCases, id: \.self) { sort in
                Toggle(sort.title, isOn: Binding(
                    get: { library.projectSort == sort },
                    set: { _ in library.projectSort = sort }
                ))
            }
        }
        Divider()
        Toggle("Tek sohbetlik projeleri gizle", isOn: $library.hidesSingleSessionProjects)
        Toggle("Son 30 günde etkin olmayanları gizle", isOn: $library.hidesInactiveProjects)
        if !library.hiddenProjects.isEmpty {
            Divider()
            Button("Gizli projeleri yönet…") { library.showingSettings = true }
        }
    }

    private var leavesSomethingOut: Bool {
        library.hidesSingleSessionProjects || library.hidesInactiveProjects || !library.hiddenProjects.isEmpty
    }
}
