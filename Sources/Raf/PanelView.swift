import SwiftUI

enum PanelField: Hashable {
    case search
    case task(String)
    case rename(String)
}

struct PanelView: View {
    @ObservedObject var library: Library
    let close: () -> Void
    @FocusState private var focus: PanelField?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
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
                Toggle("Girişte başlat", isOn: Binding(
                    get: { library.launchesAtLogin },
                    set: { library.setLaunchesAtLogin($0) }
                ))
                Divider()
                Button("Raf'tan çık") { NSApp.terminate(nil) }
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
        if library.pinned.isEmpty {
            pinHint
        } else {
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
                    rowKey: RowKey.recent(session.id), detail: session.projectName
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
                    detail: hit.snippet == nil ? hit.session.projectName : nil,
                    snippet: hit.snippet, detailLines: 2
                )
            }
        }
    }

    private var pinHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pin")
                .font(.system(size: 11, weight: .medium))
            Text("Sık döndüğünüz sohbetleri sabitleyin. Sabitlediğiniz her sohbete görev ekleyebilirsiniz.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 2)
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
                Text(session.title)
                    .font(.system(size: 13))
                    .foregroundStyle(style.title)
                    .lineLimit(1)
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
        .help(helpText(live: live))
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
        Divider()
        Button("Klasörü Finder'da göster") { Opener.revealFolder(session.cwd) }
        Button("Oturum kimliğini kopyala") { Opener.copy(session.id) }
    }

    private func helpText(live: LiveSession?) -> String {
        var lines: [String] = []
        if let live {
            let place = live.isInTerminal ? "terminalde" : "Claude uygulamasında"
            let reason = live.waitingFor.map { " (\($0))" } ?? ""
            lines.append("\(live.label), \(place)\(reason)")
        }
        if let prompt = session.lastPrompt, !prompt.isEmpty { lines.append(prompt) }
        lines.append(session.cwd)
        return lines.joined(separator: "\n")
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
        return open == 0 ? item.session.projectName : "\(item.session.projectName) · \(open) açık görev"
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
        .help(project.folders.joined(separator: "\n"))
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
