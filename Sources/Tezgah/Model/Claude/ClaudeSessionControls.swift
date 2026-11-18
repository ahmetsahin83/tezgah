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
    /// Used until a session's own /model menu has been read (see `readClaudeModels`).
    static let fallbackModels = ["Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"]

    /// One numbered option of the /model menu.
    struct ModelMenuOption: Equatable {
        var number: Int
        var name: String
        /// Marked ✔: the model in use.
        var isCurrent = false
        /// Marked ❯: where the cursor is.
        var isHighlighted = false
    }

    /// The numbered options of the /model menu on screen, in order. Claude Code 2.1.327 prints
    ///
    ///     ❯ 1.  Default (recommended) ✔  Opus 5.5 · Best for everyday, complex tasks
    ///       2.  Opus 5.5                 For complex work and everyday tasks
    ///       ▸   More models
    ///
    /// The name ends at ✔ or at the wide gap before the description. Only the options of the last
    /// menu on screen count, so an earlier menu still in the scrollback is not read.
    static func modelMenuOptions(in lines: [String]) -> [ModelMenuOption] {
        var options: [ModelMenuOption] = []
        for line in lines.suffix(40) {
            guard let match = line.firstMatch(of: #/^\s*(❯\s*)?(\d+)\.\s+(.+)$/#), let number = Int(match.2) else { continue }
            if number == 1 { options.removeAll() }
            let rest = String(match.3)
            let name = rest.split(separator: "✔", maxSplits: 1).first
                .flatMap { $0.split(separator: #/\s{2,}/#, maxSplits: 1).first }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !name.isEmpty else { continue }
            options.append(ModelMenuOption(number: number, name: name, isCurrent: rest.contains("✔"), isHighlighted: match.1 != nil))
        }
        return options
    }

    /// The models to offer from the /model menu's options: named models only, since "Default"
    /// is one of them under another name.
    static func modelNames(from options: [ModelMenuOption]) -> [String] {
        var names: [String] = []
        for option in options where !option.name.lowercased().hasPrefix("default") && !names.contains(option.name) {
            names.append(option.name)
        }
        return names
    }

    /// The option `model` names: the one called exactly that, else the first that starts with it
    /// ("Fable" → "Fable 5.2"), so "Fable 5" does not pick "Fable 5.2".
    static func modelOption(named model: String, in options: [ModelMenuOption]) -> ModelMenuOption? {
        let wanted = model.lowercased()
        return options.first { $0.name.lowercased() == wanted }
            ?? options.first { $0.name.lowercased().hasPrefix(wanted) }
    }

    /// Opens the /model menu, reads the models it offers and closes it again without changing
    /// anything; stores them on the session. Nil if the menu did not open or listed nothing.
    @discardableResult
    func readClaudeModels() async -> [String]? {
        guard await openMenu("/model", until: Self.isModelMenu) else { return nil }
        let names = Self.modelNames(from: Self.modelMenuOptions(in: view.bufferLines()))
        view.send([0x1B])
        _ = await waitForScreen { !Self.isModelMenu($0) }
        guard !names.isEmpty else { return nil }
        claude?.availableModels = names
        return names
    }

    static func isModelMenu(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("this session only") || $0.contains("Esc to cancel") }
    }

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
        guard await openMenu("/model", until: Self.isModelMenu) else {
            return "The model menu did not open."
        }
        let options = Self.modelMenuOptions(in: view.bufferLines())
        // The menu is open anyway: keep what it offers.
        let names = Self.modelNames(from: options)
        if !names.isEmpty { claude?.availableModels = names }
        guard let current = options.first(where: \.isHighlighted)?.number,
              let target = Self.modelOption(named: model, in: options)?.number else {
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
