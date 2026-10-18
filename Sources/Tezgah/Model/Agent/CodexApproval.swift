import Foundation

/// Codex's approval dialog, read from its terminal: what it wants to do and the numbered choices.
///
/// Codex's hooks say that it asks (PermissionRequest), not what it offers, so the choices come
/// from the screen. A digit picks its choice at once; Esc cancels and lets the user tell Codex
/// what to do instead.
struct CodexApprovalDialog: Equatable {
    struct Option: Equatable {
        let number: Int
        /// Without the key hint, e.g. "Yes, proceed".
        let label: String

        /// Allows the request rather than turning it down.
        var allows: Bool { label.hasPrefix("Yes") || label.hasPrefix("Allow") || label.hasPrefix("Always allow") }
    }

    /// "Would you like to run the following command?"
    let title: String
    let reason: String?
    /// The command it wants to run, without the "$ ".
    let command: String?
    let options: [Option]

    /// The choice behind "Bir Daha Sorma": allows this and more like it (a command prefix, these
    /// files, this session), not just this once.
    var alwaysOption: Option? {
        options.dropFirst().first(where: \.allows)
    }

    private static let footer = "Press enter to confirm or esc to cancel"

    /// The dialog at the bottom of the screen, if one is open.
    static func parse(_ lines: [String]) -> CodexApprovalDialog? {
        let lines = Array(lines.suffix(80))
        // The footer makes it a dialog and not, say, a numbered list in Codex's reply.
        guard let footer = lines.lastIndex(where: { $0.contains(Self.footer) }) else { return nil }

        var options: [Option] = []
        var firstOptionLine: Int?
        var index = footer - 1
        var continuation: [String] = []
        while index >= 0 {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let (number, label) = Self.option(line) {
                let full = ([label] + continuation.reversed()).joined(separator: " ")
                options.insert(Option(number: number, label: Self.withoutKeyHint(full)), at: 0)
                firstOptionLine = index
                continuation = []
                if number == 1 { break }
            } else if line.isEmpty {
                if !options.isEmpty { break }
            } else {
                continuation.append(line) // a long choice wrapped onto the next line
            }
            index -= 1
        }
        guard let start = firstOptionLine, options.first?.number == 1 else { return nil }

        var title: String?
        var reason: [String] = []
        var command: [String] = []
        // Long lines wrap onto the next ones, up to a blank line.
        enum Block { case other, reason, command }
        var block = Block.other
        for line in lines[..<start].suffix(40).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Would you like to") || line.hasPrefix("Allow ") && line.hasSuffix("?") {
                (title, reason, command, block) = (line, [], [], .other)
            } else if title == nil {
                continue
            } else if line.hasPrefix("Reason:") {
                reason = [String(line.dropFirst("Reason:".count)).trimmingCharacters(in: .whitespaces)]
                block = .reason
            } else if line.hasPrefix("$ ") {
                command.append(String(line.dropFirst(2)))
                block = .command
            } else if line.isEmpty {
                block = .other
            } else if block == .reason {
                reason.append(line)
            } else if block == .command {
                command.append(line)
            }
        }
        guard let title else { return nil }
        return CodexApprovalDialog(
            title: title,
            reason: reason.isEmpty ? nil : reason.joined(separator: " "),
            command: command.isEmpty ? nil : command.joined(separator: " "),
            options: options
        )
    }

    /// "› 2. Yes, and … (p)" → (2, "Yes, and … (p)")
    private static func option(_ line: String) -> (Int, String)? {
        guard let match = line.firstMatch(of: #/^(?:[›>❯]\s*)?(\d{1,2})\.\s+(.+)$/#), let number = Int(match.1) else { return nil }
        return (number, String(match.2))
    }

    private static func withoutKeyHint(_ label: String) -> String {
        label.replacing(#/\s+\([a-z]{1,6}\)$/#, with: "")
    }
}

extension TerminalSession {
    /// Codex's approval dialog on screen now, if any.
    var codexApproval: CodexApprovalDialog? {
        guard agent?.provider == .codex, agent?.state == .needsPermission else { return nil }
        return CodexApprovalDialog.parse(view.bufferLines())
    }

    /// Picks a choice in Codex's approval dialog; nil turns the request down.
    func answerCodex(_ option: CodexApprovalDialog.Option?) {
        guard isRunning else { return }
        if let option {
            view.send(txt: String(option.number))
        } else {
            view.send([0x1B])
        }
        agent?.userAnswered()
    }
}
