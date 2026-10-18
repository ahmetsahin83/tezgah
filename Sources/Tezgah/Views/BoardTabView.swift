import SwiftUI
import UniformTypeIdentifiers

/// A project's to-do board: Yapılacak / Yapılıyor / Bitti, with drag and drop between columns.
struct BoardTabView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let board: ProjectBoard
    let project: Project
    @State private var isEditingTeam = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 14) {
                ForEach(BoardCard.Column.allCases, id: \.self) { column in
                    BoardColumnView(board: board, column: column, project: project)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: EditorThemes.theme(for: colorScheme).background))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Pano")
                .font(.system(size: 17, weight: .semibold))
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if !board.cards(in: .done).isEmpty {
                Button("Bitenleri Temizle") {
                    board.clearDone()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .help("Bitti sütunundaki kartları sil")
            }
            queueButton
            Button {
                isEditingTeam = true
            } label: {
                Label("Ekip", systemImage: "person.3")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .help("Orkestra ekibi: geliştirici, gözden geçirenler, karar verici")
            .sheet(isPresented: $isEditingTeam) {
                OrchestraTeamView(project: project) { isEditingTeam = false }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// "Sırayla yürüt": the to-do cards go to the orchestra one by one, top first.
    @ViewBuilder
    private var queueButton: some View {
        if project.orchestraQueue != nil {
            Button {
                store.stopQueue(in: project)
            } label: {
                Label("Sırayı Durdur", systemImage: "stop.fill")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .help("Yeni kart alınmaz; çalışan kart kendi başına sürer")
        } else {
            Button {
                store.startQueue(in: project)
            } label: {
                Label("Sırayla Yürüt", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .disabled(!project.git.isRepository || OrchestraQueue.nextCard(on: board) == nil)
            .help("Yapılacak'taki kartlar üstten başlayarak teker teker orkestraya gider; biri birleşince sıradaki başlar. Takılan kart dalıyla kalır, üst üste \(OrchestraQueue.maxStopsInARow) kart takılırsa sıra durur.")
        }
    }

    private var summary: String {
        let open = board.openCount
        let done = board.cards(in: .done).count
        if open == 0 && done == 0 { return project.name }
        var summary = "\(project.name) · \(open) açık" + (done > 0 ? ", \(done) bitti" : "")
        if project.orchestraQueue != nil {
            summary += " · sırada \(board.cards(in: .todo).filter { $0.worktree == nil }.count) kart"
        }
        return summary
    }
}

private struct BoardColumnView: View {
    let board: ProjectBoard
    let column: BoardCard.Column
    let project: Project

    @State private var isAdding = false
    @State private var newTitle = ""
    @State private var isTargeted = false
    @FocusState private var isAddFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cards = board.cards(in: column)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(column.tint)
                    .frame(width: 8, height: 8)
                Text(column.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text("\(cards.count)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer()
                Button {
                    isAdding = true
                    isAddFocused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(column.title) sütununa kart ekle")
                .accessibilityLabel("\(column.title) sütununa kart ekle")
            }
            .padding(.horizontal, 4)

            if isAdding || column == .todo {
                addField
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        BoardCardView(board: board, card: card, project: project)
                    }
                    if cards.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, 8)
                .animation(.spring(duration: 0.25, bounce: 0.1), value: cards.map(\.id))
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? column.tint.opacity(0.7) : Color.clear, lineWidth: 1.5)
        }
        // Dropped on the column itself (not on a card): goes to the end.
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            board.move(id, to: column)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(column.tint.opacity(0.85))
                .font(.system(size: 13))
            TextField(column == .todo ? "Yapılacak bir şey ekle…" : "Kart ekle…", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isAddFocused)
                .onSubmit {
                    board.add(newTitle, to: column)
                    newTitle = ""
                    isAddFocused = true
                }
                .onExitCommand {
                    newTitle = ""
                    isAdding = false
                    isAddFocused = false
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.17) : .white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isAddFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
        }
        .onChange(of: isAddFocused) {
            if !isAddFocused, newTitle.isEmpty, column != .todo { isAdding = false }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: column.emptySymbol)
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
            Text(column.emptyText)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

private struct BoardCardView: View {
    @Environment(WorkspaceStore.self) private var store
    let board: ProjectBoard
    let card: BoardCard
    let project: Project

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var isTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDone = card.column == .done
        HStack(alignment: .top, spacing: 9) {
            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) { board.toggleDone(card.id) }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isDone ? Color.green : Color.secondary.opacity(isHovering ? 0.9 : 0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(isDone ? "Yapılacaklara geri al" : "Bitti olarak işaretle")
            .accessibilityLabel(isDone ? "Yapılacaklara geri al" : "Bitti olarak işaretle")

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .strikethrough(isDone, color: .secondary.opacity(0.6))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !card.notes.isEmpty {
                    Text(card.notes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let worktree = card.worktree {
                    worktreeChip(worktree)
                }
                if let run = store.orchestraRuns[card.id] {
                    orchestraLine(run)
                } else if let record = card.run {
                    finishedRunLine(record)
                }
                Text(dateText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: isHovering ? 0.2 : 0.175) : .white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : (isHovering ? 0.1 : 0.05)), radius: isHovering ? 6 : 2, y: isHovering ? 2 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.07))
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                cardMenu
                    .padding(5)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // Where a dragged card will land.
            if isTargeted {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .offset(y: -6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onTapGesture(count: 2) { isEditing = true }
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            BoardCardEditor(board: board, card: card, remove: remove) { isEditing = false }
        }
        .contextMenu { menuItems }
        .draggable(card.id.uuidString) {
            Text(card.title)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) { board.move(id, to: card.column, before: card.id) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// Where the orchestra is with the card.
    /// The run's state; opens its page.
    private func orchestraLine(_ run: OrchestraRun) -> some View {
        let stopped = if case .needsUser = run.phase { true } else { false }
        return Button {
            store.showRunPage(of: card.id, in: project)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: stopped ? "exclamationmark.circle.fill" : "person.3.fill")
                    .font(.system(size: 9.5))
                Text(run.summary)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(stopped ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help("Koşuyu aç: ajanlar, aşama ve akış")
    }

    /// A run that merged or was given up on still has its page.
    private func finishedRunLine(_ record: BoardCard.RunRecord) -> some View {
        Button {
            store.showRunPage(of: card.id, in: project)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.3")
                    .font(.system(size: 9.5))
                Text(record.isMerged ? "Orkestra · birleştirildi" : record.isWaitingForAnswers ? "Orkestra · bilgi bekliyor" : "Orkestra · durdu")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Koşunun akışını aç")
    }

    /// The card's branch, with the state of the agent working on it; opens its tab.
    private func worktreeChip(_ worktree: BoardCard.Worktree) -> some View {
        let agent = store.worktreeTabs(of: card, in: project).lazy.compactMap(\.agent).first
        return Button {
            store.showWorktree(of: card, in: project)
        } label: {
            HStack(spacing: 5) {
                if let agent {
                    AgentStatusIcon(agent)
                        .font(.system(size: 10))
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(worktree.branch)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(agent.map { "\($0.provider.displayName) bu dalda çalışıyor · sekmeye git" } ?? "Worktree'de terminal aç")
    }

    private var dateText: String {
        // The app speaks Turkish whatever the system language is.
        let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "tr_TR"))
        if let completed = card.completedAt { return "Bitti · " + completed.formatted(style) }
        return card.createdAt.formatted(style)
    }

    private var cardMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Kart işlemleri")
        .accessibilityLabel("Kart işlemleri")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Düzenle…") { isEditing = true }
        if store.orchestraRuns[card.id] != nil || card.run != nil {
            Button {
                store.showRunPage(of: card.id, in: project)
            } label: {
                Label("Koşuyu Aç", systemImage: "person.3")
            }
        }
        if let title = store.continueTitle(for: card.id) {
            Button {
                Task { await store.continueOrchestra(of: card.id, in: project) }
            } label: {
                Label(title, systemImage: "forward")
            }
            .help("Aynı dalda kaldığı yerden, tur sınırı olmadan sürdür")
        }
        if card.run?.stopReason != nil, store.orchestraRuns[card.id]?.isActive != true {
            Button {
                Task { await store.restartOrchestra(of: card.id, in: project) }
            } label: {
                Label("Baştan Başlat", systemImage: "arrow.counterclockwise")
            }
            .help("Dalı ve worktree'yi silip kartı orkestrayla yeniden başlat; akış kalır")
        }
        if store.orchestraRuns[card.id] != nil {
            Button("Orkestrayı Durdur") { store.stopOrchestra(of: card, in: project) }
                .help("Worktree ve geliştiricinin sekmesi kalır")
        } else if card.worktree == nil {
            Button {
                store.startOrchestra(card, in: project)
            } label: {
                Label("Orkestrayla Başlat", systemImage: "person.3")
            }
            .disabled(!project.git.isRepository)
            .help("Ekip işi kendi dalında yapsın, gözden geçirsin ve birleştirsin")
        }
        if card.worktree == nil {
            Button {
                store.giveToClaude(card, in: project)
            } label: {
                Label("Claude'a Ver", systemImage: "sparkle")
            }
            Menu {
                ForEach([AgentProvider.claude, .codex], id: \.self) { provider in
                    Button(provider.displayName) { store.startInWorktree(card, with: provider, in: project) }
                }
            } label: {
                Label("Worktree'de Başlat", systemImage: "arrow.triangle.branch")
            }
            .disabled(!project.git.isRepository)
            .help("Kendi dalında ve worktree'sinde bir ajana ver")
        } else {
            Button("Worktree'ye Git") { store.showWorktree(of: card, in: project) }
            Button("Dalı Birleştir…") { store.mergeWorktree(of: card, in: project) }
            Button("Worktree'yi Sil…", role: .destructive) { store.discardWorktree(of: card, in: project) }
        }
        Divider()
        ForEach(BoardCard.Column.allCases.filter { $0 != card.column }, id: \.self) { column in
            Button("\(column.title) Sütununa Taşı") {
                withAnimation(.spring(duration: 0.25, bounce: 0.1)) { board.move(card.id, to: column) }
            }
        }
        Divider()
        Button("Sil", role: .destructive, action: remove)
    }

    /// A card with a worktree takes it and its branch along, after asking.
    private func remove() {
        if card.worktree != nil {
            store.discardWorktree(of: card, in: project, removingCard: true)
        } else {
            withAnimation { board.remove(card.id) }
        }
    }
}

private struct BoardCardEditor: View {
    let board: ProjectBoard
    @State var card: BoardCard
    let remove: () -> Void
    let close: () -> Void

    init(board: ProjectBoard, card: BoardCard, remove: @escaping () -> Void, close: @escaping () -> Void) {
        self.board = board
        _card = State(initialValue: card)
        self.remove = remove
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Başlık", text: $card.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1...4)
            Divider()
            ZStack(alignment: .topLeading) {
                if card.notes.isEmpty {
                    Text("Notlar, ayrıntılar, bağlantılar…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $card.notes)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
            }
            HStack {
                Picker("Sütun", selection: $card.column) {
                    ForEach(BoardCard.Column.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Sil", role: .destructive) {
                    close()
                    remove()
                }
                Button("Tamam") {
                    save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .onDisappear(perform: save)
    }

    private func save() {
        guard let current = board.cards.first(where: { $0.id == card.id }) else { return }
        if current.column != card.column {
            board.move(card.id, to: card.column)
        }
        var updated = card
        let latest = board.cards.first(where: { $0.id == card.id })
        updated.completedAt = latest?.completedAt
        updated.worktree = latest?.worktree // Tezgah's, not edited here
        board.update(updated)
    }
}

private extension BoardCard.Column {
    var tint: Color {
        switch self {
        case .todo: Color.secondary
        case .doing: Color.claudeAccent
        case .done: Color.green
        }
    }

    var emptySymbol: String {
        switch self {
        case .todo: "tray"
        case .doing: "hammer"
        case .done: "checkmark.seal"
        }
    }

    var emptyText: String {
        switch self {
        case .todo: "Yapılacakları yukarıdan ekle"
        case .doing: "Üzerinde çalıştıklarını\nburaya sürükle"
        case .done: "Biten işler burada birikir"
        }
    }
}
