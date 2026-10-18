import Foundation
import Observation

/// A Codex session in a terminal tab: the shared agent states plus the conversation read from
/// its rollout file, and Tezgah's composer for it.
@MainActor
@Observable
final class CodexActivity: AgentActivity {
    var viewMode = ViewMode.conversation
    /// The conversation so far, read from Codex's rollout file.
    private(set) var transcript: CodexTranscript?
    /// The prompt being written in the tab's composer.
    let composer = ClaudeComposerState()

    init() {
        super.init(provider: .codex)
    }

    override func handle(_ event: [String: Any]) {
        if let path = event["transcript_path"] as? String, !path.isEmpty, transcript?.url.path != path {
            follow(URL(fileURLWithPath: path))
        }
        switch event["hook_event_name"] as? String {
        case "UserPromptSubmit", "PostToolUse", "Stop", "Interrupt":
            transcript?.refresh()
        default:
            break
        }
        super.handle(event)
    }

    /// The conversation of a resumed session can be shown before Codex names its file, which it
    /// does only with the next prompt.
    override func resumes(session id: String) {
        super.resumes(session: id)
        guard transcript == nil else { return }
        let home = CodexTranscript.home(environment: ProcessInfo.processInfo.environment)
        Task { [weak self] in
            let file = await Task.detached { CodexTranscript.rolloutFile(forSession: id, in: home) }.value
            guard let self, let file, transcript == nil else { return }
            follow(file)
        }
    }

    private func follow(_ url: URL) {
        transcript?.stop()
        let transcript = CodexTranscript(url: url)
        self.transcript = transcript
        transcript.start()
    }
}

extension TerminalSession {
    /// Sends what is in a Codex tab's composer; while Codex is still starting, as soon as it is up.
    func sendCodexDraft() {
        guard let codex = agent as? CodexActivity, codex.state != .ended, codex.state != .needsPermission,
              codex.composer.canSend else { return }
        if codex.state == .starting {
            codex.composer.isWaitingForAgent = true
            return
        }
        codex.composer.isWaitingForAgent = false
        // Attachments go in as their paths, the way Claude's composer sends them.
        let draft = codex.composer.takeDraft()
        submitPrompt(draft.text, attachments: draft.attachments)
    }
}
