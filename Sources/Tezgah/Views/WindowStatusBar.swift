import SwiftUI

extension EnvironmentValues {
    /// False for the tab in the main pane, whose session details sit in the window's status bar instead.
    @Entry var showsTabBar = true
}

/// One line at the bottom of the window: the branch, Claude, open connections and running commands,
/// then the front tab's own details. The same place in every tab.
struct WindowStatusBar: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let project: Project

    var body: some View {
        // Running commands are read from their terminals; check once a second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 4) {
                branch
                agents
                databases
                running
                Spacer(minLength: 12)
                tabDetails
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.chrome(scheme))
        .overlay(alignment: .top) { ThemeDivider() }
    }

    @ViewBuilder private var branch: some View {
        let git = project.git
        if git.isRepository {
            let count = git.status.allChanges.count
            StatusItem(help: store.isGitPanelVisible ? "Git panelini gizle (⇧⌘G)" : "Git panelini göster (⇧⌘G)") {
                store.toggleGitPanel()
            } label: {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                Text(git.status.branch ?? "detached")
                if git.status.ahead > 0 { Text("↑\(git.status.ahead)") }
                if git.status.behind > 0 { Text("↓\(git.status.behind)") }
                if count > 0 {
                    Text("· \(count) değişiklik").foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The project's agent sessions, unless the front tab is one: its own state is on the right then.
    @ViewBuilder private var agents: some View {
        let sessions = project.terminals.filter { $0.agent != nil && $0.agent?.state != .ended }
        if !sessions.isEmpty, project.selectedTab.flatMap(Self.agentActivity) == nil {
            let waiting = sessions.first { $0.agent?.state == .needsPermission }
            let working = sessions.first { $0.agent?.state == .working }
            let target = waiting ?? working ?? sessions[0]
            let provider = target.agent?.provider ?? .claude
            StatusItem(help: "\(provider.displayName) sekmesine git") {
                project.selectedTabID = target.id
            } label: {
                Circle()
                    .fill(waiting != nil ? Color.orange : working != nil ? provider.accent : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("\(provider.displayName) " + (waiting != nil ? "onay bekliyor" : working != nil ? "çalışıyor" : "hazır"))
                if sessions.count > 1 { Text("· \(sessions.count)").foregroundStyle(.tertiary) }
            }
        }
    }

    @ViewBuilder private var databases: some View {
        ForEach(project.databaseSessions.filter { $0.state == .connected }) { session in
            StatusItem(help: "\(session.config.name) bağlı · sekmeye git") {
                project.selectedTabID = session.id
            } label: {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(session.config.name)
            }
        }
    }

    @ViewBuilder private var running: some View {
        let busy = project.terminals.filter { $0.agent == nil && $0.projectCommand != nil && $0.foregroundProcessName != nil }
        if let first = busy.first {
            StatusItem(help: busy.map(\.title).joined(separator: "\n")) {
                project.selectedTabID = first.id
            } label: {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
                Text(busy.count == 1 ? first.title : "\(busy.count) komut çalışıyor")
            }
        }
    }

    @ViewBuilder private var tabDetails: some View {
        if case .terminal(let session) = project.selectedTab, let activity = session.agent {
            AgentSessionBar(activity: activity, project: project, repository: project.repository(for: session.directory), isEmbedded: true)
                .frame(maxWidth: 640)
        } else if case .editor(let document) = project.selectedTab {
            Text(project.relativePath(of: document.url))
                .truncationMode(.head)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
        }
    }

    static func agentActivity(_ tab: WorkspaceTab) -> AgentActivity? {
        if case .terminal(let session) = tab { return session.agent }
        return nil
    }
}

/// A clickable item in the status bar, highlighted under the pointer.
private struct StatusItem<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    init(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.help = help
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label }
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isHovering ? Theme.hover(scheme) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
