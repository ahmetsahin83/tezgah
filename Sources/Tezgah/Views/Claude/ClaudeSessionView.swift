import SwiftUI

/// A Claude tab: the conversation with a native composer, or Claude Code's own terminal UI.
struct ClaudeSessionView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.showsTabBar) private var showsTabBar
    let session: TerminalSession
    let activity: ClaudeActivity
    let project: Project

    /// Still starting after a moment: Claude Code is probably asking something in the terminal
    /// (trusting the folder, picking a conversation).
    @State private var startupTimedOut = false
    @State private var commands: [ClaudeSlashCommand] = []
    @State private var conversationController = ClaudeConversationController()

    var body: some View {
        VStack(spacing: 0) {
            if showsTerminal {
                VStack(spacing: 0) {
                    if let banner = terminalBanner {
                        TerminalBanner(text: banner) {
                            activity.returnsToConversationWhenLoaded = false
                            activity.viewMode = .conversation
                            startupTimedOut = false
                            activity.composer.focus()
                        }
                    }
                    TerminalPane(session: session)
                }
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
            try? await Task.sleep(for: .seconds(1.6))
            if activity.state == .starting { startupTimedOut = true }
        }
        .task {
            let root = project.url
            let configDirectory = ClaudeMonitor.configDirectory(environment: await ShellEnvironment.shared.environment())
            commands = await Task.detached { ClaudeSlashCommand.discover(projectURL: root, configDirectory: configDirectory) }.value
        }
        .onChange(of: activity.transcript?.version) {
            guard let transcript = activity.transcript else { return }
            let prompts = transcript.entries.compactMap { entry -> String? in
                if case .prompt(let text, _) = entry.kind, !text.isEmpty { text } else { nil }
            }
            activity.composer.seedHistory(prompts)
            if activity.returnsToConversationWhenLoaded, !transcript.entries.isEmpty {
                activity.returnsToConversationWhenLoaded = false
                activity.viewMode = .conversation
            }
        }
    }

    private var showsTerminal: Bool {
        activity.viewMode == .terminal || (activity.state == .starting && startupTimedOut && activity.transcript == nil)
    }

    private var terminalBanner: String? {
        if activity.viewMode == .conversation {
            return "Claude Code terminalde bir yanıt bekliyor. Bittiğinde sohbet görünümü kendiliğinden açılır."
        }
        if activity.returnsToConversationWhenLoaded {
            return "Bir konuşma seç; sohbet görünümü sonra açılır."
        }
        return activity.terminalHint
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            if let todos = activity.transcript?.todos, todos.isPinned {
                ClaudeTodoBar(list: todos)
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ClaudeConversationView(
                entries: activity.transcript?.entries ?? [],
                subagents: activity.transcript?.subagents ?? [:],
                runningAgents: activity.transcript?.runningAgents ?? [],
                version: activity.transcript?.version ?? 0,
                context: .init(
                    isWorking: activity.state == .working || activity.state == .needsPermission,
                    pendingTool: activity.state == .needsPermission ? activity.pendingRequest?.tool : nil,
                    canShowSessionDiff: activity.baselineTree != nil
                ),
                status: status,
                root: session.directory,
                projectName: project.name,
                controller: conversationController,
                actions: .init(
                    openFile: { url, line in store.openFile(url, line: line) },
                    openSessionDiff: { path in openSessionDiff(path) },
                    runInTerminal: { command in store.runInTerminal(command, directory: session.directory) },
                    editPrompt: { text in
                        activity.composer.text = text
                        activity.composer.pendingCursor = (text as NSString).length
                        activity.composer.focus()
                    },
                    resendPrompt: { text in
                        switch activity.state {
                        case .idle, .working, .finished:
                            session.submitPrompt(text)
                        default:
                            // Not taking input right now: leave it ready in the composer.
                            activity.composer.text = text
                            activity.composer.focus()
                        }
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
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background {
                // ⌘F opens the find bar, ⌘G / ⇧⌘G step through matches.
                Group {
                    Button("") {
                        withAnimation(.easeOut(duration: 0.15)) { conversationController.isFinding = true }
                        conversationController.focusRequest += 1
                    }
                    .keyboardShortcut("f")
                    Button("") { conversationController.step(1) }
                        .keyboardShortcut("g")
                }
                .opacity(0)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                // Content fades out under the composer instead of being cut off.
                LinearGradient(colors: [background.opacity(0), background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                if activity.state == .needsPermission {
                    ClaudeRequestCard(activity: activity, project: project, answer: answer, answerQuestions: { answers in
                        session.answerQuestions(answers)
                        activity.userAnswered()
                        activity.composer.focus()
                    }) {
                        activity.viewMode = .terminal
                        activity.terminalHint = "Yanıtı terminalde ver, sonra sohbete dönebilirsin (⌘J)."
                    }
                    .id(activity.requestSerial) // a new dialog starts with a fresh form
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showsSuggestions {
                    SuggestionChips(suggestions: activity.suggestions) { suggestion in
                        activity.composer.text = suggestion
                        activity.composer.pendingCursor = (suggestion as NSString).length
                        activity.composer.focus()
                    } dismiss: {
                        activity.suggestions = []
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if activity.state == .ended {
                    endedBar
                } else {
                    ClaudeComposerView(
                        state: activity.composer,
                        project: project,
                        commands: commands,
                        isWorking: activity.state == .working,
                        isWaiting: activity.state == .needsPermission,
                        isEnded: activity.state == .ended,
                        suggestion: showsSuggestions ? activity.suggestions.first : nil,
                        sessionControls: AnyView(ClaudeSessionControlsView(session: session, activity: activity)),
                        actions: .init(send: send, interrupt: interrupt, reject: { answer(.escape) })
                    )
                }
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .animation(.spring(duration: 0.28, bounce: 0.12), value: activity.state == .needsPermission)
        }
        .background(background)
        .onAppear { activity.composer.focus() }
    }

    private var showsSuggestions: Bool {
        !activity.suggestions.isEmpty && activity.composer.text.isEmpty
            && (activity.state == .finished || activity.state == .idle)
    }

    private var background: Color {
        Color(nsColor: EditorThemes.theme(for: colorScheme).background)
    }

    private var status: ClaudeConversationView.Status { .init(activity) }

    private var endedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude oturumu kapandı")
                    .font(.system(size: 13, weight: .semibold))
                Text("Konuşmaya kaldığın yerden devam edebilirsin.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Terminal") { activity.viewMode = .terminal }
                .help("Claude kapandı; sekme artık normal bir kabuk")
            if activity.sessionID != nil {
                Button {
                    store.resumeClaude(in: session)
                } label: {
                    Text("Devam Et").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(.claudeAccent)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }

    // MARK: Actions

    private func send() {
        session.sendComposerDraft()
    }

    private func interrupt() {
        session.sendClaudeKey(.escape)
    }

    private func answer(_ key: TerminalSession.ClaudeKey) {
        session.sendClaudeKey(key)
        activity.userAnswered()
        activity.composer.focus()
    }

    private func openSessionDiff(_ path: String) {
        let repository = project.repository(for: session.directory)
        guard let tree = activity.baselineTree, let repositoryPath = repository.repositoryPath(ofAbsolutePath: path) else {
            store.openFile(URL(fileURLWithPath: path))
            return
        }
        store.openDiff(.snapshot(tree: tree, paths: [repositoryPath], title: "Claude oturumu"), in: repository)
    }
}

/// The terminal of a Claude tab, the same view the tab always had.
private struct TerminalPane: View {
    let session: TerminalSession

    var body: some View {
        TerminalRepresentable(view: session.view)
            .padding(.leading, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: session.view.nativeBackgroundColor))
    }
}

private struct TerminalBanner: View {
    let text: String
    let returnToConversation: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Sohbete Dön", action: returnToConversation)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// What Claude guesses you may ask next, as chips over the composer.
private struct SuggestionChips: View {
    let suggestions: [String]
    let pick: (String) -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.claudeAccent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        Chip(text: suggestion, hint: index == 0 ? "⇥" : nil) { pick(suggestion) }
                    }
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Önerileri gizle")
            .accessibilityLabel("Önerileri gizle")
        }
        .padding(.horizontal, 4)
    }

    private struct Chip: View {
        let text: String
        let hint: String?
        let action: () -> Void
        @State private var isHovering = false
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(text)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if let hint {
                        Text(hint)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.1 : 0.055)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(hint == nil ? "Composer'a koy" : "Composer'a koy (Tab)")
        }
    }
}
