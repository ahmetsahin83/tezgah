import Foundation
import Observation

/// A Claude Code session in a terminal tab: the shared agent states plus what only Claude Code
/// offers (its transcript, status line figures, Remote Control, Tezgah's composer).
@MainActor
@Observable
final class ClaudeActivity: AgentActivity {
    /// Figures from Claude Code's status line data.
    struct Usage: Equatable {
        struct Limit: Equatable {
            /// 0–100
            var usedPercent: Double
            var resetsAt: Date?
        }

        var model: String?
        /// Estimated API cost of the session at list price; subscription plans are not billed per token.
        var costUSD: Double?
        /// Tokens of the most recent request only (input includes cache reads and writes).
        var lastRequestInputTokens: Int?
        var lastRequestOutputTokens: Int?
        /// How full the context window is, 0–100. Unknown until the first reply.
        var contextUsedPercent: Double?
        var contextWindowSize: Int?
        /// Lines Claude added and removed during the session.
        var linesAdded: Int?
        var linesRemoved: Int?
        /// Pro/Max plan usage windows, after the first reply.
        var fiveHourLimit: Limit?
        var weeklyLimit: Limit?
    }

    private(set) var usage: Usage?

    /// Remote Control: the session can be followed and answered from the Claude app or claude.ai/code.
    enum RemoteControl: Equatable {
        case off
        case connecting
        case active(URL?)

        var isOn: Bool { self != .off }
    }

    var remoteControl = RemoteControl.off {
        didSet { if remoteControl != oldValue { onRemoteControlChange?(self) } }
    }
    /// Set by the store, which keeps the Mac awake while a session is reachable remotely.
    @ObservationIgnored var onRemoteControlChange: ((ClaudeActivity) -> Void)?
    /// The conversation so far, read from Claude Code's transcript file.
    private(set) var transcript: ClaudeTranscript?
    var viewMode = ViewMode.conversation {
        didSet { if viewMode == .conversation { terminalHint = nil } }
    }
    /// Why the tab switched to the terminal by itself, shown above it.
    var terminalHint: String?
    /// Opened on Claude Code's conversation picker: show the conversation once one is loaded.
    var returnsToConversationWhenLoaded = false
    /// Effort level ("low" … "max"), from its hooks.
    var effortLevel: String?
    /// The model picked in Tezgah for this session, until the status line reports it.
    var pendingModel: String?
    /// Started with `--dangerously-skip-permissions`, so "bypass permissions" is one of its modes.
    var canSkipPermissions = false

    /// Likely next prompts, after a turn; shown over the composer.
    var suggestions: [String] = []
    /// A turn just ended and nobody has asked for suggestions for it yet.
    @ObservationIgnored var wantsSuggestions = false
    /// The prompt being written in the tab's composer.
    let composer = ClaudeComposerState()

    init() {
        super.init(provider: .claude)
    }

    /// Claude Code's own parts of a hook event, taken before the shared handling reports the
    /// new state, so whoever listens sees them already updated.
    override func handle(_ event: [String: Any]) {
        if let path = event["transcript_path"] as? String, !path.isEmpty, transcript?.url.path != path {
            // A new session (or /clear, which starts one) writes a new file.
            transcript?.stop()
            let transcript = ClaudeTranscript(url: URL(fileURLWithPath: path))
            self.transcript = transcript
            transcript.start()
        }
        if let level = (event["effort"] as? [String: Any])?["level"] as? String, level != effortLevel { effortLevel = level }

        switch event["hook_event_name"] as? String {
        case "UserPromptSubmit":
            suggestions = []
        case "PostToolUse", "PostToolUseFailure":
            transcript?.refresh()
        case "Notification" where event["notification_type"] as? String == "idle_prompt"
            && (state == .working || state == .needsPermission):
            transcript?.refresh()
        case "Stop":
            wantsSuggestions = true
            transcript?.refresh()
        default:
            break
        }
        super.handle(event)
    }

    override func processExited() {
        remoteControl = .off
        super.processExited()
    }

    /// Applies the JSON Claude Code passes to the status line command.
    func updateUsage(from status: [String: Any]) {
        func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
        let cost = status["cost"] as? [String: Any]
        let context = status["context_window"] as? [String: Any]
        let model = status["model"] as? [String: Any]
        let limits = status["rate_limits"] as? [String: Any]

        func limit(_ key: String) -> Usage.Limit? {
            guard let window = limits?[key] as? [String: Any],
                  let used = number(window["used_percentage"])?.doubleValue else { return nil }
            return Usage.Limit(usedPercent: used, resetsAt: Self.date(window["resets_at"]))
        }

        let updated = Usage(
            model: model?["display_name"] as? String,
            costUSD: number(cost?["total_cost_usd"])?.doubleValue,
            lastRequestInputTokens: number(context?["total_input_tokens"])?.intValue,
            lastRequestOutputTokens: number(context?["total_output_tokens"])?.intValue,
            contextUsedPercent: number(context?["used_percentage"])?.doubleValue,
            contextWindowSize: number(context?["context_window_size"])?.intValue,
            linesAdded: number(cost?["total_lines_added"])?.intValue,
            linesRemoved: number(cost?["total_lines_removed"])?.intValue,
            fiveHourLimit: limit("five_hour"),
            weeklyLimit: limit("seven_day")
        )
        if updated != usage { usage = updated }
    }

    /// `resets_at` as epoch seconds (or milliseconds) or an ISO 8601 string; the format is not documented.
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 100_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
