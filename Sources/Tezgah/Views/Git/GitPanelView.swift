import AppKit
import SwiftUI

/// The git side panel (inspector). Diffs open as tabs in the main area.
struct GitPanelView: View {
    let project: Project
    private var git: GitRepository { project.git }

    var body: some View {
        Group {
            if git.isRepository {
                VStack(spacing: 0) {
                    GitHeaderView(git: git)
                    if let error = git.lastError {
                        GitErrorBanner(message: error) { git.lastError = nil }
                    }
                    Divider()
                    switch git.panelMode {
                    case .changes: GitChangesList(project: project)
                    case .history: GitHistoryList(git: git)
                    }
                }
            } else if git.hasChecked {
                ContentUnavailableView {
                    Label("Git deposu değil", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("“\(project.name)” klasöründe bir git deposu yok.")
                } actions: {
                    Button("Depo Oluştur (git init)") {
                        Task { await git.initRepository() }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await git.refresh() }
            if git.panelMode == .history { Task { await git.loadLog() } }
        }
        .onChange(of: git.panelMode) {
            if git.panelMode == .history {
                Task { await git.loadLog() }
            }
        }
    }
}

// MARK: Header

private struct GitHeaderView: View {
    @Bindable var git: GitRepository
    @AppStorage("gitChangesAsTree") private var changesAsTree = true
    @State private var isCreatingBranch = false
    @State private var newBranchName = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    Picker("Branch'ler", selection: currentBranch) {
                        ForEach(git.localBranches, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    if !git.remoteBranches.isEmpty {
                        Menu("Uzak Branch'ler") {
                            ForEach(git.remoteBranches, id: \.self) { remote in
                                Button(remote) { Task { await git.checkoutRemoteBranch(remote) } }
                            }
                        }
                    }
                    Divider()
                    Button("Yeni Branch…") {
                        newBranchName = ""
                        isCreatingBranch = true
                    }
                } label: {
                    Label(git.status.branch ?? "(detached HEAD)", systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(git.isBusy)

                Spacer(minLength: 4)

                if git.isBusy {
                    ProgressView().controlSize(.small)
                        .help(git.busyLabel.map { "\($0)…" } ?? "")
                }
                Group {
                    Button { Task { await git.fetch() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Fetch: uzak depodaki değişiklikleri getir")
                    .accessibilityLabel("Fetch: uzak depodaki değişiklikleri getir")

                    Button { Task { await git.pull() } } label: {
                        syncLabel("arrow.down", count: git.status.behind)
                    }
                    .help(git.status.behind > 0 ? "Pull (\(git.status.behind) yeni commit)" : "Pull")

                    Button { Task { await git.push() } } label: {
                        syncLabel("arrow.up", count: git.status.ahead)
                    }
                    .help(git.status.upstream.map { "Push → \($0)" } ?? "Push (upstream ayarlanacak)")
                }
                .buttonStyle(.borderless)
                .disabled(git.isBusy)
            }

            HStack(spacing: 6) {
                Picker("Görünüm", selection: $git.panelMode) {
                    Text("Değişiklikler").tag(GitRepository.PanelMode.changes)
                    Text("Geçmiş").tag(GitRepository.PanelMode.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if git.panelMode == .changes {
                    Button { changesAsTree.toggle() } label: {
                        Image(systemName: changesAsTree ? "list.bullet" : "list.bullet.indent")
                    }
                    .buttonStyle(.borderless)
                    .help(changesAsTree ? "Liste olarak göster" : "Ağaç olarak göster")
                    .accessibilityLabel(changesAsTree ? "Liste olarak göster" : "Ağaç olarak göster")
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .alert("Yeni Branch", isPresented: $isCreatingBranch) {
            TextField("branch-adi", text: $newBranchName)
            Button("Oluştur") {
                let name = newBranchName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await git.createBranch(name) }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Şu anki commit'ten yeni bir branch oluşturulup ona geçilecek.")
        }
    }

    private func syncLabel(_ symbol: String, count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            if count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
    }

    private var currentBranch: Binding<String> {
        Binding(
            get: { git.status.branch ?? "" },
            set: { name in Task { await git.switchBranch(name) } }
        )
    }
}

private struct GitErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            ScrollView {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Uyarıyı kapat")
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
    }
}

// MARK: Changes

private struct GitChangesList: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project
    private var git: GitRepository { project.git }
    @AppStorage("gitChangesAsTree") private var asTree = true
    /// Folders the user folded; everything starts open, like VS Code.
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            CommitBox(git: git)
            Divider()
            if git.status.isClean {
                EmptyState(symbol: "checkmark", tint: .green, title: "Her şey commit'li",
                           message: git.commits.first.map { "Son commit: \($0.subject)" } ?? "Commit'lenecek değişiklik yok.")
            } else {
                List(selection: selection) {
                    if !git.status.conflicted.isEmpty {
                        Section {
                            rows(git.status.conflicted, area: .conflicted)
                        } header: {
                            SectionHeader(title: "Çakışmalar", count: git.status.conflicted.count)
                        }
                    }
                    if !git.status.staged.isEmpty {
                        Section {
                            rows(git.status.staged, area: .staged)
                        } header: {
                            SectionHeader(title: "Hazır", count: git.status.staged.count, actionIcon: "minus", actionHelp: "Tümünü unstage et") {
                                Task { await git.unstageAll() }
                            }
                        }
                    }
                    if !git.status.unstaged.isEmpty {
                        Section {
                            rows(git.status.unstaged, area: .unstaged)
                        } header: {
                            SectionHeader(title: "Değişiklikler", count: git.status.unstaged.count, actionIcon: "plus", actionHelp: "Tümünü stage'le") {
                                Task { await git.stageAll() }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: String.self) { ids in
                    contextMenu(for: changes(ids))
                } primaryAction: { ids in
                    // Double-click / Return keeps the diff tab open (pins it).
                    if let change = changes(ids).first, ids.count == 1 {
                        store.openDiff(.change(path: change.path, area: change.area), pin: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ changes: [GitChange], area: GitChange.Area) -> some View {
        if asTree {
            ForEach(ChangeTree(changes, area: area).rows(collapsed: collapsed)) { row in
                if let change = row.node.change {
                    ChangeRow(change: change, git: git, depth: row.depth, showsFolder: false)
                        .tag(change.id)
                } else {
                    FolderRow(node: row.node, depth: row.depth, isCollapsed: collapsed.contains(row.node.id), git: git) {
                        toggle(row.node.id)
                    }
                    .tag(row.node.id)
                }
            }
        } else {
            ForEach(changes) { change in
                ChangeRow(change: change, git: git)
                    .tag(change.id)
            }
        }
    }

    private func toggle(_ folder: String) {
        if collapsed.contains(folder) { collapsed.remove(folder) } else { collapsed.insert(folder) }
    }

    private var selection: Binding<Set<String>> {
        Binding(
            get: { git.selectedChangeIDs },
            set: { ids in
                // Clicking a folder folds or unfolds it; only files are selected.
                let folders = ids.filter { $0.hasPrefix("dir:") }
                if folders.count == 1, ids.count == 1, let folder = folders.first {
                    toggle(folder)
                    return
                }
                let ids = ids.subtracting(folders)
                git.selectChanges(ids)
                if ids.count == 1, let change = changes(ids).first {
                    store.openDiff(.change(path: change.path, area: change.area))
                }
            }
        )
    }

    private func changes(_ ids: Set<String>) -> [GitChange] {
        git.status.allChanges.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func contextMenu(for changes: [GitChange]) -> some View {
        let staged = changes.filter { $0.area == .staged }
        let unstaged = changes.filter { $0.area != .staged }
        if changes.count == 1, let change = changes.first {
            Button("Diff'i Aç") { store.openDiff(.change(path: change.path, area: change.area), pin: true) }
        }
        Button("Dosyayı Aç") { open(changes) }
        Divider()
        if !unstaged.isEmpty {
            Button("Stage'le") { Task { await git.stage(unstaged) } }
        }
        if !staged.isEmpty {
            Button("Unstage Et") { Task { await git.unstage(staged) } }
        }
        let discardable = changes.filter { $0.area == .unstaged }
        if !discardable.isEmpty {
            Divider()
            Button("Değişiklikleri Geri Al…", role: .destructive) { discardWithConfirmation(discardable, git: git) }
        }
        Divider()
        Button("Finder'da Göster") {
            NSWorkspace.shared.activateFileViewerSelecting(changes.compactMap(git.fileURL(for:)))
        }
    }

    private func open(_ changes: [GitChange]) {
        for change in changes {
            guard let url = git.fileURL(for: change), FileManager.default.fileExists(atPath: url.path) else { continue }
            store.openFile(url)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    var actionIcon: String?
    var actionHelp = ""
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            if let actionIcon, let action {
                Button(action: action) {
                    Image(systemName: actionIcon)
                }
                .buttonStyle(.borderless)
                .help(actionHelp)
                .accessibilityLabel(actionHelp)
            }
        }
    }
}

private struct ChangeRow: View {
    let change: GitChange
    let git: GitRepository
    var depth = 0
    var showsFolder = true
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 || !showsFolder {
                // Room for the folders' disclosure chevrons, so names line up under them.
                IndentGuides(depth: depth)
                Color.clear.frame(width: 12)
            }
            FileTypeIcon(URL(fileURLWithPath: change.path))
            Text(change.fileName)
                .lineLimit(1)
                .strikethrough(change.code == "D")
                .foregroundStyle(change.code == "D" ? .secondary : .primary)
            if showsFolder {
                Text(change.directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if isHovering {
                actions
            }
            Text(change.letter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(change.color)
                .frame(width: 14)
        }
        .onHover { isHovering = $0 }
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch change.area {
            case .staged:
                iconButton("minus", help: "Unstage et") { Task { await git.unstage([change]) } }
            case .unstaged:
                iconButton("arrow.uturn.backward", help: "Değişiklikleri geri al") { discardWithConfirmation([change], git: git) }
                iconButton("plus", help: "Stage'le") { Task { await git.stage([change]) } }
            case .conflicted:
                iconButton("plus", help: "Çözüldü olarak işaretle (stage'le)") { Task { await git.stage([change]) } }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A folder in the tree view: fold it, or stage / unstage / discard everything inside at once.
private struct FolderRow: View {
    let node: ChangeTree.Node
    let depth: Int
    let isCollapsed: Bool
    let git: GitRepository
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        let changes = node.changes
        HStack(spacing: 6) {
            IndentGuides(depth: depth)
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Klasörü aç" : "Klasörü kapat")
            FolderIcon(name: (node.path as NSString).lastPathComponent, isOpen: !isCollapsed)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if isHovering {
                HStack(spacing: 2) {
                    switch node.area {
                    case .staged:
                        folderButton("minus", help: "Klasördekileri unstage et") { Task { await git.unstage(changes) } }
                    case .unstaged:
                        folderButton("arrow.uturn.backward", help: "Klasördeki değişiklikleri geri al") { discardWithConfirmation(changes, git: git) }
                        folderButton("plus", help: "Klasördekileri stage'le") { Task { await git.stage(changes) } }
                    case .conflicted:
                        folderButton("plus", help: "Çözüldü olarak işaretle (stage'le)") { Task { await git.stage(changes) } }
                    }
                }
            } else {
                Text("\(changes.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 14)
            }
        }
        .onHover { isHovering = $0 }
        .help(node.path)
        .contextMenu {
            switch node.area {
            case .staged:
                Button("Klasördekileri Unstage Et") { Task { await git.unstage(changes) } }
            case .unstaged, .conflicted:
                Button("Klasördekileri Stage'le") { Task { await git.stage(changes) } }
            }
            if node.area == .unstaged {
                Divider()
                Button("Klasördeki Değişiklikleri Geri Al…", role: .destructive) { discardWithConfirmation(changes, git: git) }
            }
            Divider()
            Button("Finder'da Göster") {
                if let url = changes.first.flatMap(git.fileURL(for:))?.deletingLastPathComponent() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func folderButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Faint vertical lines, one per level, that make nesting easy to follow.
private struct IndentGuides: View {
    let depth: Int

    var body: some View {
        if depth > 0 {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 1)
                        .padding(.leading, 6)
                        .frame(width: 14, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.vertical, -4) // lines run through the row's padding, joining rows up
        }
    }
}

@MainActor
func discardWithConfirmation(_ changes: [GitChange], git: GitRepository) {
    Task {
        let confirmed = await ConfirmSheet.ask(
            title: changes.count == 1
                ? "“\(changes[0].fileName)” dosyasındaki değişiklikler geri alınsın mı?"
                : "\(changes.count) dosyadaki değişiklikler geri alınsın mı?",
            message: "Bu işlem geri alınamaz. Yeni (untracked) dosyalar Çöp Sepeti'ne taşınır.",
            confirm: "Geri Al"
        )
        if confirmed { await git.discard(changes) }
    }
}

private struct CommitBox: View {
    @Bindable var git: GitRepository

    var body: some View {
        VStack(spacing: 8) {
            // ⌘↩ commits only while writing the message: elsewhere it answers Claude's dialogs.
            PlainTextEditor(text: $git.commitMessage, onCommandReturn: {
                if canCommit { Task { await git.commit() } }
            })
                .frame(height: 64)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if git.commitMessage.isEmpty {
                        Text("Commit mesajı")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                Task { await git.commit() }
            } label: {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCommit)
            .help("Commit (⌘↩)")
        }
        .padding(10)
    }

    private var title: String {
        if !git.status.staged.isEmpty { return "Commit (\(git.status.staged.count))" }
        if !git.status.unstaged.isEmpty { return "Tümünü Stage'le ve Commit'le" }
        return "Commit"
    }

    private var canCommit: Bool {
        !git.isBusy
            && git.status.conflicted.isEmpty
            && !git.status.isClean
            && !git.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: History

private struct GitHistoryList: View {
    @Environment(WorkspaceStore.self) private var store
    let git: GitRepository
    @FocusState private var isFocused: Bool

    var body: some View {
        if git.commits.isEmpty {
            EmptyState(symbol: "clock", title: "Henüz commit yok", message: "İlk commit'i Değişiklikler sekmesinden atabilirsin.")
        } else {
            let graph = git.graph
            // Text starts after the widest part of the graph, so subjects line up.
            let graphWidth = CGFloat(min(graph.maxWidth, 8)) * CommitGraphCell.laneWidth + 4
            // Rows sit edge to edge (not a List, which spaces them) so the graph's lines join up.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(git.commits.enumerated()), id: \.element.id) { index, commit in
                            CommitRow(
                                commit: commit,
                                graphRow: index < graph.rows.count ? graph.rows[index] : nil,
                                graphWidth: graphWidth,
                                isHead: commit.hash == git.status.headOID,
                                isUnpushed: git.unpushed.contains(commit.hash),
                                isIncoming: git.incoming.contains(commit.hash),
                                isSelected: commit.hash == git.selectedCommitID
                            )
                            .id(commit.hash)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // One handler that reads the click count: a separate double-tap
                                // gesture would hold every single click back while it waits.
                                isFocused = true
                                select(commit)
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                    store.openDiff(.commit(commit), pin: true)
                                }
                            }
                            .contextMenu {
                                Button("Diff'i Aç") { store.openDiff(.commit(commit), pin: true) }
                                Button("Hash'i Kopyala") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(commit.hash, forType: .string)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(.upArrow) { step(-1, proxy: proxy) }
                .onKeyPress(.downArrow) { step(1, proxy: proxy) }
                .onKeyPress(.return) {
                    guard let commit = selectedCommit else { return .ignored }
                    store.openDiff(.commit(commit), pin: true)
                    return .handled
                }
            }
        }
    }

    private var selectedCommit: GitCommit? {
        git.commits.first { $0.hash == git.selectedCommitID }
    }

    private func select(_ commit: GitCommit) {
        git.selectCommit(commit.hash)
        store.openDiff(.commit(commit))
    }

    private func step(_ delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let current = git.commits.firstIndex { $0.hash == git.selectedCommitID } ?? (delta > 0 ? -1 : git.commits.count)
        let next = current + delta
        guard git.commits.indices.contains(next) else { return .handled }
        select(git.commits[next])
        proxy.scrollTo(git.commits[next].hash)
        return .handled
    }
}

/// One commit in the graph: lanes on the left, then the subject, branch and tag badges, and the time.
private struct CommitRow: View {
    static let height: CGFloat = 26

    let commit: GitCommit
    let graphRow: CommitGraph.Row?
    let graphWidth: CGFloat
    let isHead: Bool
    let isUnpushed: Bool
    let isIncoming: Bool
    var isSelected = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let graphRow {
                CommitGraphCell(row: graphRow, isHead: isHead, isMerge: commit.isMerge, isIncoming: isIncoming)
                    .frame(width: graphWidth, alignment: .leading)
                    .clipped()
            }
            if isUnpushed {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.blue)
                    .help("Henüz push edilmedi")
            } else if isIncoming {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.purple)
                    .help("Uzak depoda, henüz pull edilmedi")
            }
            Text(commit.subject)
                .fontWeight(isHead ? .semibold : .regular)
                .foregroundStyle(isIncoming ? .secondary : .primary)
                .lineLimit(1)
                .layoutPriority(1)
            ForEach(RefBadge.parse(commit.refs)) { badge in
                badge.view(color: CommitGraphCell.color(graphRow?.color ?? 0))
            }
            Spacer(minLength: 4)
            Text(Self.age(of: commit.date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: Self.height)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .onHover { isHovering = $0 }
        .help("\(commit.shortHash) · \(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.subject)")
    }
}

extension CommitRow {
    /// "şimdi", "5 dk", "3 sa", "2 g", "4 hf", "3 ay", "1 yıl": short enough for a narrow panel.
    static func age(of date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
        switch seconds {
        case ..<60: return "şimdi"
        case ..<3600: return "\(minutes) dk"
        case ..<86_400: return "\(hours) sa"
        case ..<(86_400 * 7): return "\(days) g"
        case ..<(86_400 * 30): return "\(days / 7) hf"
        case ..<(86_400 * 365): return "\(days / 30) ay"
        default: return "\(days / 365) yıl"
        }
    }
}

/// A branch, remote branch or tag pointing at a commit.
private struct RefBadge: Identifiable {
    enum Kind { case head, branch, remote, tag }
    let name: String
    let kind: Kind
    var id: String { name }

    /// `git log %D`: "HEAD -> main", "origin/main", "tag: v1.0".
    static func parse(_ refs: [String]) -> [RefBadge] {
        refs.compactMap { ref in
            if ref.hasPrefix("HEAD -> ") { return RefBadge(name: String(ref.dropFirst(8)), kind: .head) }
            if ref == "HEAD" { return RefBadge(name: "HEAD", kind: .head) }
            if ref.hasPrefix("tag: ") { return RefBadge(name: String(ref.dropFirst(5)), kind: .tag) }
            if ref.hasSuffix("/HEAD") { return nil } // origin/HEAD only repeats the default branch
            return RefBadge(name: ref, kind: ref.contains("/") ? .remote : .branch)
        }
    }

    func view(color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
            Text(name)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: kind == .head ? .semibold : .medium))
        .foregroundStyle(kind == .remote ? Color.secondary : color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background {
            Capsule().fill(kind == .remote ? Color.primary.opacity(0.06) : color.opacity(0.16))
        }
        .overlay {
            if kind == .head { Capsule().strokeBorder(color.opacity(0.55)) }
        }
        .fixedSize()
        .help(help)
    }

    private var symbol: String {
        switch kind {
        case .head: "checkmark"
        case .branch: "arrow.triangle.branch"
        case .remote: "cloud"
        case .tag: "tag"
        }
    }

    private var help: String {
        switch kind {
        case .head: "Şu anki branch: \(name)"
        case .branch: "Branch: \(name)"
        case .remote: "Uzak branch: \(name)"
        case .tag: "Etiket: \(name)"
        }
    }
}

/// The graph part of a row: lane lines through it and the commit's dot.
private struct CommitGraphCell: View {
    static let laneWidth: CGFloat = 14

    let row: CommitGraph.Row
    let isHead: Bool
    let isMerge: Bool
    let isIncoming: Bool

    /// Distinct in both light and dark mode, in the spirit of VS Code's graph.
    static let palette: [Color] = [
        Color(red: 0.30, green: 0.60, blue: 1.00), Color(red: 0.95, green: 0.60, blue: 0.29),
        Color(red: 0.70, green: 0.50, blue: 0.92), Color(red: 0.25, green: 0.72, blue: 0.31),
        Color(red: 0.97, green: 0.47, blue: 0.73), Color(red: 0.22, green: 0.77, blue: 0.81),
        Color(red: 0.89, green: 0.70, blue: 0.25), Color(red: 1.00, green: 0.48, blue: 0.45),
    ]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2 }

            for line in row.lines {
                let (top, bottom) = line.half == .top ? (CGFloat(0), middle) : (middle, size.height)
                var path = Path()
                path.move(to: CGPoint(x: x(line.from), y: top))
                if line.from == line.to {
                    path.addLine(to: CGPoint(x: x(line.to), y: bottom))
                } else {
                    // A smooth bend from one lane to another.
                    let bend = (bottom - top) * 0.75
                    path.addCurve(
                        to: CGPoint(x: x(line.to), y: bottom),
                        control1: CGPoint(x: x(line.from), y: top + bend),
                        control2: CGPoint(x: x(line.to), y: bottom - bend)
                    )
                }
                context.stroke(path, with: .color(Self.color(line.color)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            let center = CGPoint(x: x(row.column), y: middle)
            let color = Self.color(row.color)
            if isHead {
                let ring = Path(ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13))
                context.stroke(ring, with: .color(color), lineWidth: 1.5)
            }
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            if isMerge || isIncoming {
                // Merges and commits still on the remote are drawn hollow.
                context.fill(dot, with: .color(Color(nsColor: .controlBackgroundColor)))
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
        }
        .frame(height: CommitRow.height)
    }
}
