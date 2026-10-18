import SwiftUI

/// Toolbar button with the number of agent sessions waiting for the user, opening the overview.
struct AgentSessionsButton: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let waiting = store.agentSessions.filter { $0.session.agent?.state == .needsPermission }.count
        let working = store.agentSessions.filter { $0.session.agent?.state == .working }.count
        let total = store.agentSessions.filter { $0.session.agent?.state != .ended }.count
        let tint: Color = waiting > 0 ? .orange : .claudeAccent
        Button {
            store.isAgentOverviewVisible.toggle()
        } label: {
            HStack(spacing: 6) {
                if waiting > 0 || working > 0 {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(total > 0 ? "Ajanlar · \(total)" : "Ajanlar")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(total > 0 ? tint : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(total > 0 ? tint.opacity(0.14) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(waiting > 0 ? "Ajan oturumları, \(waiting) bekliyor" : "Ajan oturumları")
        .help(waiting > 0 ? "\(waiting) ajan oturumu seni bekliyor" : "Tüm ajan oturumları")
        .popover(isPresented: $store.isAgentOverviewVisible, arrowEdge: .bottom) {
            AgentSessionsOverview()
        }
    }
}

/// Every agent session across projects: what each is doing, and Claude's waiting ones answerable in place.
struct AgentSessionsOverview: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        let sessions = store.agentSessions
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ajan Oturumları")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Button("Claude") {
                        store.isAgentOverviewVisible = false
                        store.newClaudeSession()
                    }
                    Button("Codex") {
                        store.isAgentOverviewVisible = false
                        store.newCodexSession()
                    }
                } label: {
                    Label("Yeni", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .disabled(store.activeProject == nil)
                .help("Aktif projede yeni ajan oturumu")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.claudeAccent)
                    Text("Henüz ajan oturumu yok")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("⇧⌘C ile Claude, ⇧⌘X ile Codex başlat.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sessions, id: \.session.id) { item in
                            SessionRow(session: item.session, project: item.project) {
                                store.isAgentOverviewVisible = false
                                store.focusTab(item.session.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 440)
    }
}

private struct SessionRow: View {
    @Environment(WorkspaceStore.self) private var store
    let session: TerminalSession
    let project: Project
    let open: () -> Void
    @State private var isHovering = false

    /// The agent that started this one, if one did.
    private var leadName: String? {
        guard let lead = store.agentWorkers[session.id]?.lead else { return nil }
        return store.claudeTab(lead)?.session.title ?? "kapanan lider"
    }

    var body: some View {
        if let activity = session.agent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    AgentStatusIcon(activity)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.claude?.transcript?.title ?? (session.agent as? CodexActivity)?.transcript?.title ?? session.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(leadName.map { "↳ \($0) · \(project.name)" } ?? project.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        detail(activity)
                    }
                }
                if activity.provider == .codex, activity.state == .needsPermission {
                    HStack {
                        Spacer()
                        CodexApprovalBar(session: session, isCompact: true)
                    }
                }
                if session.claude != nil, activity.state == .needsPermission, let request = activity.pendingRequest,
                   !["AskUserQuestion", "ExitPlanMode"].contains(request.tool) {
                    HStack(spacing: 6) {
                        Spacer()
                        Button("Reddet") { answer(.escape) }
                        if let always = ClaudeRequestCard.alwaysLabel(request.suggestions) {
                            Button(always) { answer(.option(2)) }
                        }
                        Button("İzin Ver") { answer(.option(1)) }
                            .buttonStyle(.borderedProminent)
                            .tint(.claudeAccent)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : (activity.state == .needsPermission ? 0.035 : 0)))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover { isHovering = $0 }
            .help("Sekmeye git")
        }
    }

    @ViewBuilder
    private func detail(_ activity: AgentActivity) -> some View {
        switch activity.state {
        case .working:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Text(activity.currentStep ?? "Çalışıyor")
                        .lineLimit(1)
                    if let since = activity.turnStartedAt {
                        Text(ClaudeConversationRenderer.duration(context.date.timeIntervalSince(since)))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        case .needsPermission:
            Text(activity.message ?? "Onay bekliyor")
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .finished:
            Text(activity.message ?? "Bitti")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .idle:
            Text("Hazır").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .starting:
            Text("Başlıyor…").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .ended:
            Text("Kapandı").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }

    private func answer(_ key: TerminalSession.ClaudeKey) {
        session.sendClaudeKey(key)
        session.claude?.userAnswered()
    }
}
