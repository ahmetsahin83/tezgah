import Foundation

/// Typing into a Claude Code session from Tezgah's own controls.
///
/// Claude Code reads the terminal like any other program, so prompts arrive as a bracketed paste
/// followed by Return, exactly as if the user had pasted them: multi-line text stays one message,
/// and characters with a special meaning at an empty prompt (`?`, `!`, `#`) are taken literally.
extension TerminalSession {
    /// Keys that answer Claude Code's dialogs.
    enum ClaudeKey {
        /// Picks option `n` of a numbered list (permissions, questions).
        case option(Int)
        /// Cancels a dialog, or interrupts Claude while it works.
        case escape
        case enter
    }

    /// Sends a prompt: attached files first (Claude Code turns pasted image paths into
    /// attachments), then the text, then Return. Codex reads its prompts the same way.
    func submitPrompt(_ text: String, attachments: [URL] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !text.isEmpty || !attachments.isEmpty else { return }

        var pastes = attachments.map { Self.shellQuotedPath($0.path) }
        // Slash commands are typed so Claude Code's command matching sees them as usual.
        let typesCommand = attachments.isEmpty && text.hasPrefix("/") && !text.contains("\n")
        if !text.isEmpty, !typesCommand {
            pastes.append(text)
        }

        Task { @MainActor [weak self] in
            for (index, paste) in pastes.enumerated() {
                // A space between pieces, like a user pasting several things in a row.
                self?.paste(index == 0 ? paste : " " + paste)
                try? await Task.sleep(for: .milliseconds(attachments.isEmpty ? 30 : 120))
            }
            if typesCommand {
                self?.view.send(txt: Self.sanitized(text))
                try? await Task.sleep(for: .milliseconds(60))
            }
            // Return right after a paste can be swallowed while Claude Code is still handling it.
            try? await Task.sleep(for: .milliseconds(60))
            self?.view.send(txt: "\r")
        }
    }

    /// Sends what is in the Claude tab's composer.
    func sendComposerDraft() {
        guard let activity = claude, activity.state != .ended, activity.state != .needsPermission,
              activity.composer.canSend else { return }
        if activity.state == .starting {
            // Typed into the terminal now, it would land in a dialog or get lost.
            activity.composer.isWaitingForAgent = true
            return
        }
        activity.composer.isWaitingForAgent = false
        let draft = activity.composer.takeDraft()
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        submitPrompt(text, attachments: draft.attachments)
        // Commands that open a menu in Claude Code need the terminal.
        if text.hasPrefix("/"), draft.attachments.isEmpty {
            let name = text.dropFirst().split(separator: " ").first.map(String.init) ?? ""
            if ClaudeSlashCommand.builtIn.first(where: { $0.name == name })?.isInteractive == true {
                activity.viewMode = .terminal
                activity.terminalHint = "/\(name) terminalde açıldı. İşin bitince sohbete dön (⌘J)."
            }
        }
    }

    /// Sends a draft that waited for Claude Code to start.
    func sendDraftWaitingForClaude() {
        guard claude?.composer.isWaitingForAgent == true else { return }
        Task { @MainActor [weak self] in
            // The prompt box appears a moment after the SessionStart hook.
            try? await Task.sleep(for: .milliseconds(400))
            self?.sendComposerDraft()
        }
    }

    /// One question's answer in an AskUserQuestion dialog.
    struct QuestionAnswer: Equatable {
        /// 1-based options picked (one for a single-choice question).
        var options: [Int] = []
        /// A typed answer instead of the options ("Type something"), single-choice questions only.
        var customText: String?
        var isMultiSelect = false
        /// How many options the question offers; "Type something" comes right after them.
        var optionCount = 0
    }

    /// Answers Claude Code's question dialog the way the keyboard would, measured against
    /// Claude Code 2.1: a single-choice question takes the option's number and moves on; a
    /// multi-choice one takes a number per option to tick, then → to move on; typed answers go
    /// through "Type something". With several questions, or any multi-choice one, a review
    /// screen follows, confirmed with 1.
    func answerQuestions(_ answers: [QuestionAnswer]) {
        guard isRunning, !answers.isEmpty else { return }
        let steps = Self.keys(answering: answers)
        Task { @MainActor [weak self] in
            for step in steps {
                // Each key redraws the dialog; give it a moment so keys land on the right screen.
                self?.view.send(txt: step)
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    static func keys(answering answers: [QuestionAnswer]) -> [String] {
        var steps: [String] = []
        for answer in answers {
            if let text = answer.customText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !answer.isMultiSelect {
                steps.append(String(answer.optionCount + 1))
                steps.append(sanitized(text).replacingOccurrences(of: "\n", with: " "))
                steps.append("\r")
            } else if answer.isMultiSelect {
                steps += answer.options.sorted().map(String.init)
                steps.append("\u{1B}[C")
            } else if let option = answer.options.first {
                steps.append(String(option))
            }
        }
        if answers.count > 1 || answers.contains(where: \.isMultiSelect) {
            steps.append("1")
        }
        return steps
    }

    func sendClaudeKey(_ key: ClaudeKey) {
        guard isRunning else { return }
        switch key {
        case .option(let number): view.send(txt: String(number))
        case .escape: view.send([0x1B])
        case .enter: view.send(txt: "\r")
        }
    }

    private func paste(_ text: String) {
        view.send(txt: "\u{1B}[200~" + Self.sanitized(text) + "\u{1B}[201~")
    }

    /// Escape characters would end the paste early; Claude Code uses \n for new lines.
    private static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Paths with spaces are pasted the way Finder drops them into Terminal.
    private static func shellQuotedPath(_ path: String) -> String {
        var quoted = ""
        for character in path {
            if " '\"()&;".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted
    }
}
