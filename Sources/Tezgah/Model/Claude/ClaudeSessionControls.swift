import Foundation

/// Changes a running Claude Code session's mode, model and effort the way the user would at the
/// keyboard, checking the terminal after each step. Model and effort change for this session only
/// ("s" in their menus), never the user's defaults.
///
/// Measured against Claude Code 2.1: Shift-Tab cycles auto → manual → accept edits → plan, and the
/// status line names the mode; /model and /effort open menus. A session started with
/// `--dangerously-skip-permissions` also has bypass permissions in the cycle.
extension TerminalSession {
    enum ClaudeMode: String, CaseIterable, Identifiable {
        case manual = "default", acceptEdits, plan, auto, bypassPermissions
        var id: String { rawValue }

        var title: String {
            switch self {
            case .manual: "Her şeyi sor"
            case .acceptEdits: "Düzenlemeleri kabul et"
            case .plan: "Plan"
            case .auto: "Otomatik"
            case .bypassPermissions: "Tam yetki"
            }
        }

        var detail: String {
            switch self {
            case .manual: "Her dosya düzenlemesi ve komut için izin ister"
            case .acceptEdits: "Dosya düzenlemelerini sormadan yapar, komutlar için sorar"
            case .plan: "Önce plan çıkarır, onaylayınca uygular; dosyalara dokunmaz"
            case .auto: "Güvenli gördüğü işleri sormadan yapar"
            case .bypassPermissions: "Hiçbir şey için izin istemez"
            }
        }

        var symbol: String {
            switch self {
            case .manual: "hand.raised"
            case .acceptEdits: "pencil.and.outline"
            case .plan: "list.bullet.clipboard"
            case .auto: "bolt"
            case .bypassPermissions: "exclamationmark.shield"
            }
        }

        /// What the status line says in this mode.
        var marker: String {
            switch self {
            case .manual: "manual mode on"
            case .acceptEdits: "accept edits on"
            case .plan: "plan mode on"
            case .auto: "auto mode on"
            case .bypassPermissions: "bypass permissions on"
            }
        }
    }

    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    static let models = ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]

    /// The mode the status line shows now.
    func claudeModeOnScreen() -> ClaudeMode? {
        let bottom = view.bufferLines().suffix(8).joined(separator: " ").lowercased()
        return ClaudeMode.allCases.first { bottom.contains($0.marker) }
    }

    /// Presses Shift-Tab until the status line shows `target`; false if it never did.
    func setClaudeMode(_ target: ClaudeMode) async -> Bool {
        for _ in 0..<(ClaudeMode.allCases.count + 2) {
            if claudeModeOnScreen() == target {
                claude?.permissionMode = target.rawValue
                return true
            }
            view.send(txt: "\u{1B}[Z")
            try? await Task.sleep(for: .milliseconds(350))
        }
        return claudeModeOnScreen() == target
    }

    /// Picks `model` in the /model menu for this session. Returns an error message on failure.
    func setClaudeModel(_ model: String) async -> String? {
        guard await openMenu("/model", until: { $0.contains { $0.contains("this session only") || $0.contains("Esc to cancel") } }) else {
            return "The model menu did not open."
        }
        // Options are numbered ("5. Haiku 5.5 ✔ …"); ❯ marks the highlighted one.
        let lines = view.bufferLines().suffix(40)
        var current: Int?
        var target: Int?
        for line in lines {
            guard let match = line.firstMatch(of: #/^\s*(❯\s*)?(\d+)\.\s+(.+)$/#), let number = Int(match.2) else { continue }
            if match.1 != nil { current = number }
            if match.3.lowercased().hasPrefix(model.lowercased()) { target = number }
        }
        guard let current, let target else {
            view.send([0x1B])
            return "\(model) was not in the model menu."
        }
        let key = target > current ? "\u{1B}[B" : "\u{1B}[A"
        for _ in 0..<abs(target - current) {
            view.send(txt: key)
            try? await Task.sleep(for: .milliseconds(60))
        }
        view.send(txt: "s")
        // With history, Claude Code warns that the new model re-reads the conversation; the user
        // already chose to switch, so go ahead.
        let set: ([String]) -> Bool = { $0.contains { $0.contains("Set model to \(model)") && $0.contains("this session") } }
        if await waitForScreen({ lines in set(lines) || lines.contains { $0.contains("Switch model?") } }),
           !set(Array(view.bufferLines().suffix(30))) {
            view.send(txt: "1")
        }
        let confirmed = await waitForScreen(set)
        if confirmed { claude?.pendingModel = model }
        return confirmed ? nil : "The model menu did not confirm the change."
    }

    /// Moves the /effort slider to `level` for this session.
    func setClaudeEffort(_ level: String) async -> String? {
        guard let targetIndex = Self.effortLevels.firstIndex(of: level) else { return "Unknown effort level." }
        let currentIndex = claude?.effortLevel.flatMap { Self.effortLevels.firstIndex(of: $0) } ?? 1
        guard await openMenu("/effort", until: { $0.contains { $0.contains("to adjust") } }) else {
            return "The effort menu did not open."
        }
        let key = targetIndex > currentIndex ? "\u{1B}[C" : "\u{1B}[D"
        for _ in 0..<abs(targetIndex - currentIndex) {
            view.send(txt: key)
            try? await Task.sleep(for: .milliseconds(80))
        }
        view.send(txt: "s")
        let confirmed = await waitForScreen { $0.contains { $0.contains("Set effort level to \(level)") } }
        if confirmed { claude?.effortLevel = level }
        return confirmed ? nil : "The effort menu did not confirm the change."
    }

    /// Types a slash command that opens a menu, as the user would, and waits for the menu.
    func openMenu(_ command: String, until isOpen: @escaping ([String]) -> Bool) async -> Bool {
        view.send(txt: command)
        try? await Task.sleep(for: .milliseconds(300))
        view.send(txt: "\r")
        return await waitForScreen(isOpen)
    }

    /// Polls the bottom of the terminal until `condition` holds, for up to three seconds.
    func waitForScreen(_ condition: ([String]) -> Bool) async -> Bool {
        for _ in 0..<30 {
            if condition(Array(view.bufferLines().suffix(30))) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
