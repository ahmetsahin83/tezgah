import SwiftUI

/// A thin bar under an agent tab: what the session is doing, which files it changed, and for
/// Claude what it costs.
struct AgentSessionBar: View {
    let activity: AgentActivity
    let project: Project
    /// Where the agent works: the project's checkout, or its own worktree.
    let repository: GitRepository
    /// Inside the window's status bar, which draws the background.
    var isEmbedded = false
    @State private var isShowingFiles = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                AgentStatusIcon(activity)
                Text(stateText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            if let usage = claude?.usage {
                ClaudeUsageView(usage: usage)
            }

            Spacer(minLength: 8)

            Button {
                isShowingFiles.toggle()
            } label: {
                // In a narrow pane only the icon and the count remain.
                ViewThatFits(in: .horizontal) {
                    Label(activity.touchedFiles.isEmpty ? "Dosya yok" : "\(activity.touchedFiles.count) dosya", systemImage: "doc.on.doc")
                    Label(activity.touchedFiles.isEmpty ? "" : "\(activity.touchedFiles.count)", systemImage: "doc.on.doc")
                }
                .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .disabled(activity.touchedFiles.isEmpty)
            .help("Bu oturumda \(activity.provider.displayName) tarafından değiştirilen dosyalar")
            .popover(isPresented: $isShowingFiles, arrowEdge: .top) {
                TouchedFilesList(activity: activity, project: project, repository: repository) {
                    isShowingFiles = false
                }
            }

            if let codex = activity as? CodexActivity {
                ViewModeToggle(mode: Bindable(codex).viewMode, provider: .codex)
            }
            if let claude {
                RemoteControlButton(activity: claude, project: project)

                ViewModeToggle(mode: Bindable(claude).viewMode, provider: .claude)
            }
        }
        .font(isEmbedded ? .system(size: 11.5) : .caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, isEmbedded ? 6 : 10)
        .frame(height: isEmbedded ? 20 : 26)
        .background(isEmbedded ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
        .overlay(alignment: .top) { if !isEmbedded { Divider() } }
    }

    private var claude: ClaudeActivity? { activity as? ClaudeActivity }

    private var stateText: String {
        switch activity.state {
        case .starting: "Başlıyor…"
        case .idle: "Hazır"
        case .working: "Çalışıyor"
        case .needsPermission: activity.message.map { "Onay bekliyor · \($0)" } ?? "Onay bekliyor"
        case .finished: "Bitti"
        case .ended: "Oturum kapandı"
        }
    }
}

private struct TouchedFilesList: View {
    @Environment(WorkspaceStore.self) private var store
    let activity: AgentActivity
    let project: Project
    let repository: GitRepository
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bu oturumda değişen dosyalar")
                    .font(.headline)
                Spacer()
                if let tree = activity.baselineTree {
                    let paths = activity.touchedFiles.compactMap { repository.repositoryPath(ofAbsolutePath: $0.path) }
                    Button("Tümünün Diff'i") {
                        dismiss()
                        store.openDiff(.snapshot(tree: tree, paths: paths.sorted(), title: "\(activity.provider.displayName) oturumu"), in: repository, pin: true)
                    }
                    .controlSize(.small)
                    .disabled(paths.isEmpty)
                    .help("Oturum başladığından beri bu dosyalarda olan bütün değişiklikler")
                }
            }
            .padding(10)
            Divider()
            List(activity.touchedFiles) { file in
                row(for: file)
            }
            .listStyle(.plain)
            .frame(width: 420, height: min(CGFloat(activity.touchedFiles.count) * 30 + 12, 360))
        }
        .task {
            // The project's own repository follows its files; a worktree's is read when asked.
            if repository !== project.git { await repository.refresh() }
        }
    }

    private func row(for file: AgentActivity.TouchedFile) -> some View {
        let url = URL(fileURLWithPath: file.path)
        let change = repository.change(atAbsolutePath: file.path)
        let exists = FileManager.default.fileExists(atPath: file.path)

        return HStack(spacing: 8) {
            FileTypeIcon(url)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .strikethrough(!exists)
                Text(displayFolder(of: file.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if file.edits > 1 {
                Text("×\(file.edits)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let change {
                Text(change.letter)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(change.color)
            }
            if let tree = activity.baselineTree, let path = repository.repositoryPath(ofAbsolutePath: file.path) {
                Button("Diff") {
                    dismiss()
                    store.openDiff(.snapshot(tree: tree, paths: [path], title: "\(activity.provider.displayName) oturumu"), in: repository)
                }
                .controlSize(.small)
                .help("Oturum başladığından beri bu dosyada olanlar")
            } else if let change {
                Button("Diff") {
                    dismiss()
                    store.openDiff(.change(path: change.path, area: change.area), in: repository)
                }
                .controlSize(.small)
                .help("Dosyanın commit'lenmemiş değişiklikleri")
            }
            Button("Aç") {
                dismiss()
                store.openFile(url)
            }
            .controlSize(.small)
            .disabled(!exists)
        }
        .help(file.path)
    }

    private func displayFolder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        if FileWatcher.realPath(folder) == FileWatcher.realPath(project.url.path) { return project.name }
        let relative = project.relativePath(of: URL(fileURLWithPath: folder))
        return relative == folder ? (folder as NSString).abbreviatingWithTildeInPath : relative
    }
}

/// Model, context window fill, plan limits, lines and estimated cost of a session.
struct ClaudeUsageView: View {
    let usage: ClaudeActivity.Usage

    var body: some View {
        // Narrow bars drop the plan limits, then everything but the context meter, instead of truncating.
        ViewThatFits(in: .horizontal) {
            figures(showsLimits: true, showsDetails: true)
            figures(showsLimits: false, showsDetails: true)
            figures(showsLimits: false, showsDetails: false)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func figures(showsLimits: Bool, showsDetails: Bool) -> some View {
        HStack(spacing: 12) {
            if showsDetails, let model = usage.model {
                Text(model)
            }
            if let percent = usage.contextUsedPercent {
                HStack(spacing: 4) {
                    if showsDetails { Text("Bağlam") }
                    meter(percent)
                }
                .fixedSize()
                .help(contextHelp)
            }
            if showsLimits, let limit = usage.fiveHourLimit {
                limitView("5s", limit, name: "5 saatlik kullanım limiti")
            }
            if showsLimits, let limit = usage.weeklyLimit {
                limitView("7g", limit, name: "Haftalık kullanım limiti")
            }
            if showsDetails, let added = usage.linesAdded, let removed = usage.linesRemoved, added + removed > 0 {
                HStack(spacing: 3) {
                    Text("+\(added)").foregroundStyle(.green)
                    Text("−\(removed)").foregroundStyle(.red)
                }
                .monospacedDigit()
                .help("Bu oturumda Claude'un eklediği / sildiği satırlar")
            }
            if showsDetails, let cost = usage.costUSD, cost > 0 {
                Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    .monospacedDigit()
                    .help("Oturumun liste fiyatıyla tahmini API maliyeti. Pro/Max aboneliğiyle kullanıyorsan ayrıca ücret ödenmez.")
            }
        }
        .lineLimit(1)
    }

    private func meter(_ percent: Double) -> some View {
        HStack(spacing: 4) {
            // Drawn by hand: the system bar turns gray and blue in inactive windows.
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 36, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(percent < 60 ? Color.green : percent < 85 ? .orange : .red)
                        .frame(width: max(4, 36 * min(max(percent, 0), 100) / 100))
                }
            Text("%\(Int(percent.rounded()))")
                .monospacedDigit()
        }
    }

    private func limitView(_ label: String, _ limit: ClaudeActivity.Usage.Limit, name: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
            meter(limit.usedPercent)
        }
        .help(limit.resetsAt.map { "\(name), sıfırlanma: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? name)
    }

    private var contextHelp: String {
        var parts = ["Bağlam penceresinin doluluğu"]
        if let size = usage.contextWindowSize {
            parts[0] += " (\(Self.compact(size)) token)"
        }
        if let input = usage.lastRequestInputTokens, let output = usage.lastRequestOutputTokens, input + output > 0 {
            parts.append("Son istek: ↑\(Self.compact(input)) ↓\(Self.compact(output)) token")
        }
        return parts.joined(separator: "\n")
    }

    /// 950 → "950", 45_200 → "45,2k", 1_000_000 → "1M" (decimal separator follows the locale).
    static func compact(_ value: Int) -> String {
        let number = Double(value)
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        switch number {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return (number / 1_000).formatted(format) + "k"
        default: return (number / 1_000_000).formatted(format) + "M"
        }
    }
}

/// Conversation / terminal switch of a Claude tab.
private struct ViewModeToggle: View {
    @Binding var mode: AgentActivity.ViewMode
    let provider: AgentProvider

    var body: some View {
        Picker("Görünüm", selection: $mode) {
            Image(systemName: "text.bubble")
                .help("Sohbet (⌘J)")
                .tag(AgentActivity.ViewMode.conversation)
            Image(systemName: "terminal")
                .help("Terminal (⌘J)")
                .tag(AgentActivity.ViewMode.terminal)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .help("Sohbet ya da \(provider == .claude ? "Claude Code" : provider.displayName) terminal arayüzü (⌘J)")
    }
}
