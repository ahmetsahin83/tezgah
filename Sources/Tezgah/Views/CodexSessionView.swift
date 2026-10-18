import SwiftUI

/// A Codex tab: the conversation read from Codex's rollout file with a composer, or Codex's own
/// terminal UI. Approvals are answered from the bar over the composer either way.
struct CodexSessionView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.showsTabBar) private var showsTabBar
    let session: TerminalSession
    let activity: CodexActivity
    let project: Project
    @State private var conversationController = ClaudeConversationController()
    /// Still starting after a moment: Codex is probably asking something in its terminal.
    @State private var startupTimedOut = false

    var body: some View {
        VStack(spacing: 0) {
            if showsTerminal {
                if activity.state == .needsPermission {
                    CodexApprovalBar(session: session)
                } else if activity.viewMode == .conversation {
                    banner("Codex terminalde bir yanıt bekliyor. Açıldığında sohbet görünümü geri gelir.")
                }
                TerminalRepresentable(view: session.view)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: session.view.nativeBackgroundColor))
            } else {
                conversation
            }
            if showsTabBar {
                AgentSessionBar(activity: activity, project: project, repository: project.repository(for: session.directory))
            }
        }
        .task(id: activity.state == .starting) {
            guard activity.state == .starting else {
                startupTimedOut = false
                return
            }
            try? await Task.sleep(for: .seconds(4))
            if activity.state == .starting { startupTimedOut = true }
        }
        .onChange(of: activity.transcript?.version) {
            guard let transcript = activity.transcript else { return }
            activity.composer.seedHistory(transcript.entries.compactMap { entry in
                if case .prompt(let text, _) = entry.kind, !text.isEmpty { text } else { nil }
            })
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ClaudeConversationView(
                entries: activity.transcript?.entries ?? [],
                version: activity.transcript?.version ?? 0,
                context: .init(
                    isWorking: activity.state == .working || activity.state == .needsPermission,
                    pendingTool: nil,
                    canShowSessionDiff: activity.baselineTree != nil
                ),
                status: .init(activity),
                root: session.directory,
                projectName: project.name,
                provider: .codex,
                controller: conversationController,
                actions: .init(
                    openFile: { url, line in store.openFile(url, line: line) },
                    openSessionDiff: openSessionDiff,
                    runInTerminal: { command in store.runInTerminal(command, directory: session.directory) },
                    editPrompt: { text in
                        activity.composer.text = text
                        activity.composer.pendingCursor = (text as NSString).length
                        activity.composer.focus()
                    },
                    resendPrompt: { text in
                        activity.composer.text = text
                        session.sendCodexDraft()
                    },
                    typeAhead: { characters in
                        guard activity.state != .ended else { return }
                        if characters.isEmpty { activity.composer.focus() } else { activity.composer.typeAhead(characters) }
                    }
                )
            )
            .overlay(alignment: .topTrailing) {
                if conversationController.isFinding {
                    ClaudeFindBar(controller: conversationController) {
                        conversationController.endFind()
                        activity.composer.focus()
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                }
            }
            .background {
                // ⌘F opens the find bar, ⌘G steps through matches.
                Group {
                    Button("") {
                        conversationController.isFinding = true
                        conversationController.focusRequest += 1
                    }
                    .keyboardShortcut("f")
                    Button("") { conversationController.step(1) }
                        .keyboardShortcut("g")
                }
                .opacity(0)
                .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                if activity.state == .needsPermission {
                    CodexApprovalBar(session: session)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if activity.state == .ended {
                    endedBar
                } else {
                    ClaudeComposerView(
                        state: activity.composer,
                        project: project,
                        commands: [],
                        isWorking: activity.state == .working,
                        isWaiting: activity.state == .needsPermission,
                        isEnded: activity.state == .ended,
                        provider: .codex,
                        actions: .init(
                            send: { session.sendCodexDraft() },
                            interrupt: { session.view.send([0x1B]) }, // Esc stops Codex's turn
                            reject: { session.answerCodex(nil) }
                        )
                    )
                }
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: EditorThemes.theme(for: colorScheme).background))
        .onAppear { activity.composer.focus() }
    }

    private var showsTerminal: Bool {
        activity.viewMode == .terminal || (activity.state == .starting && startupTimedOut)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var endedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex oturumu kapandı")
                    .font(.system(size: 13, weight: .semibold))
                Text("Konuşmaya kaldığın yerden devam edebilirsin.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Terminal") { activity.viewMode = .terminal }
                .help("Codex kapandı; sekme artık normal bir kabuk")
            if activity.sessionID != nil {
                Button {
                    store.resumeCodex(in: session)
                } label: {
                    Text("Devam Et").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(AgentProvider.codex.accent)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }

    private func openSessionDiff(_ path: String) {
        let repository = project.repository(for: session.directory)
        guard let tree = activity.baselineTree, let repositoryPath = repository.repositoryPath(ofAbsolutePath: path) else {
            store.openFile(URL(fileURLWithPath: path))
            return
        }
        store.openDiff(.snapshot(tree: tree, paths: [repositoryPath], title: "Codex oturumu"), in: repository)
    }
}
