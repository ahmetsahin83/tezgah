import SwiftUI

struct TabBarView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: Project

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(project.tabs) { tab in
                        TabButton(
                            tab: tab,
                            projectURL: project.url,
                            isSelected: tab.id == project.selectedTabID,
                            isInSplit: tab.id == project.splitTabID,
                            select: { project.selectedTabID = tab.id },
                            close: { store.closeTab(tab.id, in: project) }
                        )
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .contextMenu {
                            if tab.id == project.splitTabID {
                                Button("Yan Görünümü Kapat") { project.splitTabID = nil }
                            } else {
                                Button("Yan Tarafta Aç") { store.openInSplit(tab.id, in: project) }
                                    .disabled(project.tabs.count < 2)
                            }
                            Divider()
                            Button("Kapat") { store.closeTab(tab.id, in: project) }
                            Button("Diğerlerini Kapat") {
                                for other in project.tabs where other.id != tab.id {
                                    store.closeTab(other.id, in: project)
                                }
                            }
                            .disabled(project.tabs.count < 2)
                        }
                    }
                }
                .padding(.vertical, 6)
                .animation(Theme.animation(reduceMotion), value: project.tabs.map(\.id))
            }
            if project.showsRunBar, !project.runBarCommands.isEmpty {
                RunMenu(project: project)
            }
            NewTabMenu()
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Theme.chrome(scheme).opacity(scheme == .dark ? 0.6 : 0.8))
    }
}

/// The project's Make targets as one compact menu: ▶ runs the last one, the menu has them all.
private struct RunMenu: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let project: Project

    var body: some View {
        let commands = project.runBarCommands
        let current = project.lastCommand.flatMap { last in commands.first { $0.command == last.command } } ?? commands[0]
        // Whether a target is still running is read from its terminal; check once a second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let running = store.runningTerminal(for: current, in: project) != nil
            HStack(spacing: 0) {
                Button {
                    store.runOrShow(current)
                } label: {
                    HStack(spacing: 6) {
                        if running {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0x3FB950))
                        }
                        Text(Self.target(current))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(running ? "\(current.command) çalışıyor; tıkla: terminale git" : "Çalıştır: \(current.command) (⌘R)")
                .accessibilityLabel(running ? "\(Self.target(current)) çalışıyor" : "Çalıştır: \(Self.target(current))")

                Menu {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        Button {
                            store.runOrShow(command)
                        } label: {
                            Text(Self.target(command) + (index < 9 ? "   ⌃\(index + 1)" : ""))
                        }
                    }
                    Divider()
                    if store.runningTerminal(for: current, in: project) != nil {
                        Button("Yeniden Başlat: \(Self.target(current))") { store.restart(current) }
                        Button("Durdur: \(Self.target(current))") { store.stop(current) }
                        Divider()
                    }
                    Button("Menüyü Gizle") { store.setRunBarVisible(false, in: project) }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 6)
                .accessibilityLabel("Make hedefleri")
            }
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.line(scheme)))
        }
    }

    static func target(_ command: ProjectCommand) -> String {
        command.command.hasPrefix("make ") ? String(command.command.dropFirst(5)) : command.name
    }
}

/// "+" at the end of the tab bar: everything a new tab can be.
private struct NewTabMenu: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        Menu {
            Button("Terminal") { store.newTerminal() }
            Button("Claude Oturumu") { store.newClaudeSession() }
            Button("Codex Oturumu") { store.newCodexSession() }
            Divider()
            Button("Pano") { store.showBoard() }
            Button("Tarayıcı Önizleme") { store.showBrowser() }
            Button("iOS Simülatörü") { store.showSimulator() }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
        } primaryAction: {
            store.newTerminal()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Yeni terminal (⌘T); basılı tut: diğerleri")
        .accessibilityLabel("Yeni sekme")
    }
}

private struct TabButton: View {
    @Environment(WorkspaceStore.self) private var store
    let tab: WorkspaceTab
    let projectURL: URL
    let isSelected: Bool
    let isInSplit: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            if case .terminal(let session) = tab, let agent = session.agent {
                AgentStatusIcon(agent)
                    .font(.system(size: 11))
                    .overlay(alignment: .bottomTrailing) {
                        if session.claude?.remoteControl.isOn == true {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.green)
                                .offset(x: 5, y: 4)
                                .accessibilityLabel("Uzaktan erişilebilir")
                        }
                    }
            } else if hasDiskConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                TabIcon(tab: tab)
            }
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .italic(isPreview)
                .lineLimit(1)
                .strikethrough(isDeleted)
            ZStack {
                if isDirty && !isHovering {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Theme.hover(scheme)).opacity(isHovering ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sekmeyi kapat")
                    .opacity(isHovering || isSelected ? 1 : 0)
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: 30)
        .frame(maxWidth: 240)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isSelected ? Theme.raised(scheme) : isHovering ? Theme.hover(scheme) : .clear)
                .shadow(color: .black.opacity(isSelected ? (scheme == .dark ? 0.35 : 0.08) : 0), radius: 1.5, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(isSelected ? Theme.line(scheme) : isInSplit ? Color.accentColor.opacity(0.45) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .onTapGesture(perform: select)
        // Double-click pins a preview diff so the next click in the git panel opens a new tab.
        // Simultaneous, so single clicks are not delayed waiting for a possible second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if case .diff(let document) = tab { document.isPreview = false }
        })
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// An agent another agent started reads as its offspring.
    private var title: String {
        if case .terminal(let session) = tab, store.agentWorkers[session.id] != nil { return "↳ " + tab.title }
        return tab.title
    }

    private var icon: String { tab.symbol }

    private var isPreview: Bool {
        if case .diff(let document) = tab { return document.isPreview }
        return false
    }

    private var hasDiskConflict: Bool {
        if case .editor(let document) = tab { return document.diskState != .inSync }
        return false
    }

    private var isDeleted: Bool {
        if case .editor(let document) = tab { return document.diskState == .deletedOnDisk }
        return false
    }

    private var isDirty: Bool {
        if case .editor(let document) = tab { return document.isDirty }
        return false
    }

    private var tooltip: String {
        switch tab {
        case .terminal(let session): session.title
        case .editor(let document):
            (document.url.path as NSString).abbreviatingWithTildeInPath
        case .diff(let document): document.tooltip
        case .search(let model): model.options.query.isEmpty ? "Projede ara" : "Ara: \(model.options.query)"
        case .database(let session): "\(session.config.kind.title) · \(session.config.summary)"
        case .board(let board): "Proje panosu · \(board.openCount) açık iş"
        case .browser(let session): session.url?.absoluteString ?? "Önizleme"
        case .simulator(let session): session.device.map { "\($0.name) · \($0.runtime)" } ?? "iOS Simülatörü"
        case .run(let page): "Orkestra koşusu · \(page.card?.title ?? "kart silinmiş")"
        }
    }
}

@MainActor
extension WorkspaceTab {
    var title: String {
        switch self {
        case .terminal(let session): session.title
        case .editor(let document): document.title
        case .diff(let document): document.title
        case .search(let model): model.options.query.isEmpty ? "Ara" : "Ara: \(model.options.query)"
        case .database(let session): session.title
        case .board: "Pano"
        case .browser(let session): session.title.isEmpty ? (session.url?.host() ?? "Önizleme") : session.title
        case .simulator(let session): session.device?.name ?? "Cihaz"
        case .run(let page): page.card?.title ?? "Koşu"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .editor(let document): FileIcon.symbol(for: document.url)
        case .diff: "plusminus"
        case .search: "magnifyingglass"
        case .database: "cylinder.split.1x2"
        case .board: "rectangle.split.3x1"
        case .browser: "globe"
        case .simulator: "iphone"
        case .run: "person.3"
        }
    }
}

/// A tab's icon: the file's colored type icon for editors, a plain symbol for the rest.
struct TabIcon: View {
    let tab: WorkspaceTab

    var body: some View {
        switch tab {
        case .editor(let document):
            FileTypeIcon(document.url, size: 14)
        case .board, .run:
            Image(systemName: tab.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xA855F7))
        case .database:
            Image(systemName: tab.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x00A8A8))
        case .simulator:
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x3FB950))
        case .browser(let session):
            if session.isLoading {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x4C8DF6))
            }
        default:
            Image(systemName: tab.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
