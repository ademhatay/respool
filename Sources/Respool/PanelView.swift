import SwiftUI

enum PanelField: Hashable {
    case search
    case task(String)
    case rename(String)
    case tagName
    case organization(String)
}

struct PanelView: View {
    @ObservedObject var library: Library
    let close: () -> Void
    @FocusState private var focus: PanelField?

    var body: some View {
        VStack(spacing: 0) {
            if library.showingSettings {
                SettingsView(library: library, focus: $focus)
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
            }
        }
    }

    @ViewBuilder private var browseRows: some View {
        if !library.pinned.isEmpty {
            SectionHeader(title: "Sabitlenenler")
            ForEach(library.pinned) { item in
                PinnedCard(library: library, item: item, focus: $focus)
            }
        }

        if !library.recent.isEmpty {
            SectionHeader(title: "Son sohbetler")
            ForEach(library.recent) { session in
                SessionRow(
                    library: library, session: session,
                    rowKey: RowKey.recent(session.id), detail: session.placeLabel
                )
            }
        }

        SectionHeader(title: "Projeler")
        ForEach(library.projects) { project in
            ProjectSection(library: library, project: project, focus: $focus)
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
        return "\(library.sessionCount) sohbet · \(library.projects.count) proje"
    }
}

// MARK: - Building blocks

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

    @State private var hovering = false

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
                        LiveIndicator(live: live, selected: style.selected)
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
        Divider()
        Button(pinned ? "Sabitlemeyi kaldır" : "Sabitle") { library.togglePin(session) }
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
                .fill(selected ? Color.white : Color.accentColor)
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Pinned sessions and their tasks

struct PinnedCard: View {
    @ObservedObject var library: Library
    let item: PinnedSession
    var focus: FocusState<PanelField?>.Binding

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionRow(
                library: library, session: item.session,
                rowKey: RowKey.pin(item.id), detail: detailText,
                onAddTask: startAdding
            )
            ForEach(item.tasks) { task in
                TaskRow(library: library, task: task)
            }
            if library.addingTaskFor == item.id {
                addField
            }
        }
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

struct TaskRow: View {
    @ObservedObject var library: Library
    let task: TaskItem

    @State private var hovering = false

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

            Text(task.text)
                .font(.system(size: 12))
                .strikethrough(task.done)
                .foregroundStyle(task.done ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
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

private struct RowFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Reports the row to the library once the pointer has rested on it, so its details can be shown.
struct HoverDetail: ViewModifier {
    let library: Library
    let subject: HoverSubject

    @State private var frame: CGRect = .zero
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.preference(key: RowFrameKey.self, value: proxy.frame(in: .global))
            })
            .onPreferenceChange(RowFrameKey.self) { frame = $0 }
            .onHover { inside in
                pending?.cancel()
                pending = nil
                if inside {
                    let work = DispatchWorkItem { library.hover = HoverTarget(subject: subject, rowMidY: frame.midY) }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                } else if library.hover?.subject == subject {
                    library.hover = nil
                }
            }
    }
}

/// The facts about one session or project, shown beside the panel.
struct DetailCard: View {
    static let width: CGFloat = 300

    @ObservedObject var library: Library
    let subject: HoverSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch subject {
            case .session(let session): sessionBody(session)
            case .project(let project): projectBody(project)
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    @ViewBuilder private func sessionBody(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.placeLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if let live = library.live[session.id] {
            HStack(spacing: 6) {
                LiveIndicator(live: live, selected: false)
                Text(live.label + (live.isInTerminal ? ", terminalde" : ", Claude uygulamasında"))
                    .font(.system(size: 11))
            }
        }
        let tags = library.tags(for: session)
        if !tags.isEmpty {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    HStack(spacing: 4) {
                        TagMark(color: TagPalette.color(tag.color))
                        Text(tag.name).font(.system(size: 11))
                    }
                }
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            line("Son etkinlik", Format.date(session.lastActivity))
            line("Başlangıç", Format.date(session.firstActivity))
            line("İstem", "\(session.messageCount)")
            if let context = session.contextTokens {
                line("Bağlam", Format.tokens(context) + " token")
            }
            line("Girdi", Format.tokens(session.inputTokens) + " token")
            line("Önbellekten", Format.tokens(session.cachedTokens) + " token")
            line("Çıktı", Format.tokens(session.outputTokens) + " token")
            line("Boyut", Format.bytes(session.fileSize))
            if let model = session.model { line("Model", model) }
            if let branch = session.branch { line("Dal", branch) }
            if let number = session.prNumber { line("PR", "#\(number)") }
            line("Klasör", Format.path(session.cwd))
        }
        if let prompt = session.lastPrompt, !prompt.isEmpty {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func projectBody(_ project: ProjectGroup) -> some View {
        let sessions = project.sessions
        VStack(alignment: .leading, spacing: 3) {
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text("\(sessions.count) sohbet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            line("Son etkinlik", Format.date(project.lastActivity))
            line("İlk sohbet", Format.date(sessions.compactMap(\.firstActivity).min()))
            line("İstem", "\(sessions.reduce(0) { $0 + $1.messageCount })")
            line("Girdi", Format.tokens(sessions.reduce(0) { $0 + $1.inputTokens }) + " token")
            line("Önbellekten", Format.tokens(sessions.reduce(0) { $0 + $1.cachedTokens }) + " token")
            line("Çıktı", Format.tokens(sessions.reduce(0) { $0 + $1.outputTokens }) + " token")
            line("Boyut", Format.bytes(sessions.reduce(0) { $0 + $1.fileSize }))
        }
        if !project.folders.isEmpty {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(project.folders.prefix(6), id: \.self) { folder in
                    Text(Format.path(folder))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
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

    @State private var hovering = false
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
        Button("Yeniden adlandır") { library.renamingProject = project.key }
        Menu("Şununla birleştir") {
            ForEach(library.projects.filter { $0.key != project.key }) { other in
                Button(other.name) { library.merge(project, into: other) }
            }
        }
        if !project.mergedKeys.isEmpty {
            Button("Birleştirmeyi geri al") { library.separate(project) }
        }
        if let folder = project.folders.first {
            Divider()
            Button("Klasörü Finder'da göster") { Opener.revealFolder(folder) }
        }
    }
}
