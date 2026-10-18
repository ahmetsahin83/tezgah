import SwiftUI

/// A tab running an agent that Tezgah shows in its own terminal UI (Codex), with the session
/// bar under it.
struct AgentTerminalView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.showsTabBar) private var showsTabBar
    let session: TerminalSession
    let activity: AgentActivity
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            if activity.state == .ended {
                endedBanner
            } else if activity.state == .needsPermission, activity.provider == .codex {
                CodexApprovalBar(session: session)
            }
            TerminalRepresentable(view: session.view)
                .padding(.leading, 6)
                .padding(.vertical, 4)
                .background(Color(nsColor: session.view.nativeBackgroundColor))
            if showsTabBar {
                AgentSessionBar(activity: activity, project: project, repository: project.repository(for: session.directory))
            }
        }
    }

    private var endedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
            Text("\(activity.provider.displayName) oturumu kapandı; sekme artık normal bir kabuk.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if activity.provider == .codex, activity.sessionID != nil {
                Button("Devam Et") { store.resumeCodex(in: session) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(activity.provider.accent)
                    .help("Konuşmaya kaldığın yerden devam et")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
