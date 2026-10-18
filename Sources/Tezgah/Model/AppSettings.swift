import AppKit
import Observation

/// Tezgah's preferences, kept in UserDefaults and applied live.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Sistem"
            case .light: "Açık"
            case .dark: "Koyu"
            }
        }
    }

    var appearance: Appearance {
        didSet { save(appearance.rawValue, "appearance"); applyAppearance() }
    }
    var editorFontSize: Double {
        didSet { save(editorFontSize, "editorFontSize"); onFontChange?() }
    }
    var terminalFontSize: Double {
        didSet { save(terminalFontSize, "terminalFontSize"); onFontChange?() }
    }
    /// How new Claude tabs open.
    var claudeOpensAsConversation: Bool {
        didSet { save(claudeOpensAsConversation, "claudeOpensAsConversation") }
    }
    var promptSuggestions: Bool {
        didSet { save(promptSuggestions, PromptSuggester.enabledKey) }
    }
    /// Tezgah's own tools (browser, simulator, board, database, terminal) for new Claude sessions.
    var tezgahTools: Bool {
        didSet { save(tezgahTools, "tezgahTools") }
    }

    /// New Claude sessions start with Remote Control on, reachable from the Claude app and claude.ai/code.
    var claudeRemoteControl: Bool {
        didSet { save(claudeRemoteControl, "claudeRemoteControl") }
    }

    /// New Claude and Codex sessions never stop to ask for permission: Claude Code runs with
    /// `--dangerously-skip-permissions`, Codex with `--dangerously-bypass-approvals-and-sandbox`.
    /// Read-only agents (reviewers) keep their limits.
    var agentsSkipPermissions: Bool {
        didSet { save(agentsSkipPermissions, "agentsSkipPermissions") }
    }

    /// While the Telegram bot is paired the Mac stays awake: asleep, it hears nothing.
    var telegramKeepsAwake: Bool {
        didSet { save(telegramKeepsAwake, "telegramKeepsAwake"); onTelegramAwakeChange?() }
    }
    @ObservationIgnored var onTelegramAwakeChange: (() -> Void)?

    /// Set by the store: re-applies fonts to open editors and terminals.
    @ObservationIgnored var onFontChange: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        editorFontSize = defaults.object(forKey: "editorFontSize") as? Double ?? 13
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        claudeOpensAsConversation = defaults.object(forKey: "claudeOpensAsConversation") as? Bool ?? true
        promptSuggestions = defaults.object(forKey: PromptSuggester.enabledKey) as? Bool ?? true
        tezgahTools = defaults.object(forKey: "tezgahTools") as? Bool ?? true
        claudeRemoteControl = defaults.object(forKey: "claudeRemoteControl") as? Bool ?? false
        agentsSkipPermissions = defaults.object(forKey: "agentsSkipPermissions") as? Bool ?? false
        telegramKeepsAwake = defaults.object(forKey: "telegramKeepsAwake") as? Bool ?? true
    }

    var editorFont: NSFont { .monospacedSystemFont(ofSize: editorFontSize, weight: .regular) }
    var terminalFont: NSFont { .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular) }

    func applyAppearance() {
        NSApp?.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
