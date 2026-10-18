import Foundation
import Observation

/// The coding agent a tab runs.
enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// SF Symbol for the agent's tabs and sessions.
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// "Claude'a", "Codex'e": the name with the dative suffix Turkish vowel harmony picks.
    var toName: String {
        switch self {
        case .claude: "Claude'a"
        case .codex: "Codex'e"
        }
    }

    /// "Claude'u", "Codex'i": with the accusative suffix.
    var objectName: String {
        switch self {
        case .claude: "Claude'u"
        case .codex: "Codex'i"
        }
    }

    /// Codex runs its SessionStart hook with the first prompt, not when it opens.
    var startsWithFirstPrompt: Bool { self == .codex }
}

/// How an agent tab starts its session.
enum AgentLaunch: Equatable {
    case new
    /// The most recent conversation in the folder (`claude --continue`, `codex resume --last`).
    case continueLast
    /// The agent's own picker of past conversations.
    case pick
    /// A specific conversation, e.g. one open when Tezgah quit.
    case resume(sessionID: String)
}

/// What a coding agent in a terminal tab is doing, derived from its hook events.
///
/// Claude Code and Codex pass their hooks the same events with the same fields for what is
/// tracked here (`session_id`, `hook_event_name`, `tool_name`, `tool_input`, …), so the states
/// work the same for both; the few events and tools only one of them has are handled here too.
/// Each agent's own extras live in a subclass, e.g. `ClaudeActivity`.
@MainActor
@Observable
class AgentActivity {
    enum State: Equatable {
        /// Launched, waiting for the agent to start.
        case starting
        /// Ready for a prompt.
        case idle
        case working
        /// A permission dialog is open.
        case needsPermission
        /// Finished its turn; the user's move.
        case finished
        /// The agent exited; the tab is a plain shell now.
        case ended
    }

    /// How an agent tab shows the session.
    enum ViewMode: String {
        case conversation
        case terminal
    }

    /// A file the agent created or changed in this session.
    struct TouchedFile: Identifiable, Equatable {
        let path: String
        var edits: Int
        var lastTouched: Date

        var id: String { path }
    }

    /// A dialog the agent shows in the terminal and waits on: a permission or a question.
    struct PendingRequest: Equatable {
        let tool: String
        let input: JSONValue
        /// Claude Code's "and don't ask again" offers, e.g. `setMode acceptEdits` or `addRules`.
        let suggestions: [JSONValue]
    }

    /// Claude Code's tools that write files. Only Write and Edit's `file_path` is documented, so a
    /// few likely keys are tried.
    static let fileWritingTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    static let filePathKeys = ["file_path", "notebook_path", "path"]
    /// Codex's file edits: a patch in `tool_input.command`.
    static let patchTool = "apply_patch"

    let provider: AgentProvider
    private(set) var state = State.starting
    /// Details for the current state, e.g. which command needs permission.
    private(set) var message: String?
    /// The agent's last reply in full, from its most recent finished turn.
    private(set) var lastReply: String?
    private(set) var sessionID: String?
    /// A "needs permission" or "finished" the user has not looked at yet.
    private(set) var isUnseen = false
    /// Most recently touched first.
    private(set) var touchedFiles: [TouchedFile] = []
    /// The dialog behind `.needsPermission`, when known.
    private(set) var pendingRequest: PendingRequest?
    /// Counts permission requests, so an answer given from a notification can be checked
    /// against the dialog it was shown for.
    private(set) var requestSerial = 0
    /// What the agent is doing right now, e.g. "Bash: swift build", while working.
    private(set) var currentStep: String?
    /// When the current turn started, for the "working for 12 s" line.
    private(set) var turnStartedAt: Date?
    /// When the last turn ended (finished or interrupted).
    private(set) var turnEndedAt: Date?
    /// The agent's permission mode from its hooks, e.g. Claude Code's "default", "acceptEdits", "plan", "auto".
    var permissionMode: String?
    /// The working tree as a git tree object, taken when the tab opened, for "what did this session change".
    var baselineTree: String?

    /// Called after every state change.
    @ObservationIgnored var onChange: ((AgentActivity) -> Void)?
    /// Called when the agent has started and takes input.
    @ObservationIgnored var onReady: (() -> Void)?

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var needsAttention: Bool {
        isUnseen && (state == .needsPermission || state == .finished)
    }

    /// Applies one hook event (the JSON the agent passes to its hooks on stdin).
    func handle(_ event: [String: Any]) {
        if let id = event["session_id"] as? String { sessionID = id }
        if let mode = event["permission_mode"] as? String, mode != permissionMode { permissionMode = mode }
        let name = event["hook_event_name"] as? String
        if name != "PermissionRequest", name != "Notification" { pendingRequest = nil }

        switch name {
        case "SessionStart":
            currentStep = nil
            transition(to: .idle)
            onReady?()
        case "UserPromptSubmit":
            currentStep = nil
            turnStartedAt = .now
            transition(to: .working)
        case "PreToolUse":
            currentStep = Self.describeTool(event)
            transition(to: .working)
        case "PostToolUse":
            recordTouchedFile(event)
            transition(to: .working)
        case "PostToolUseFailure":
            transition(to: .working)
        case "Interrupt":
            // Codex: the user stopped the turn.
            currentStep = nil
            turnEndedAt = .now
            transition(to: .idle)
        case "PermissionRequest":
            requestSerial += 1
            pendingRequest = PendingRequest(
                tool: event["tool_name"] as? String ?? "",
                input: JSONValue(event["tool_input"]),
                suggestions: (event["permission_suggestions"] as? [Any])?.map { JSONValue($0) } ?? []
            )
            transition(to: .needsPermission, message: Self.describeTool(event))
        case "Notification":
            // Claude Code only.
            switch event["notification_type"] as? String {
            case "permission_prompt":
                // Usually follows PermissionRequest, which has the better description.
                if state != .needsPermission {
                    transition(to: .needsPermission, message: event["message"] as? String)
                }
            case "idle_prompt" where state == .working || state == .needsPermission:
                // A turn that ended without Stop (e.g. interrupted with Esc): quietly settle.
                pendingRequest = nil
                currentStep = nil
                turnEndedAt = .now
                transition(to: .idle)
            default:
                break
            }
        case "Stop":
            currentStep = nil
            lastReply = event["last_assistant_message"] as? String
            turnEndedAt = .now
            transition(to: .finished, message: lastReply.map(Self.firstLine))
        case "SessionEnd":
            currentStep = nil
            transition(to: .ended)
        default:
            break
        }
    }

    /// The user typed an answer while a permission dialog was open. No hook fires until the
    /// approved tool finishes, which can take minutes, so assume the agent is working again.
    func userAnswered() {
        if state == .needsPermission {
            pendingRequest = nil
            transition(to: .working)
        }
    }

    /// Launched, and its hooks won't say when it is up: they wait for the first prompt (Codex).
    var isWaitingForUI: Bool {
        provider.startsWithFirstPrompt && state == .starting
    }

    /// A session being resumed is known before its hooks say so (Codex says so only with the next
    /// prompt), and it must be saved again even if no prompt comes.
    func resumes(session id: String) {
        if sessionID == nil { sessionID = id }
    }

    /// The agent's terminal UI is up and takes input; see `isWaitingForUI`.
    func uiAppeared() {
        guard isWaitingForUI else { return }
        transition(to: .idle)
        onReady?()
    }

    func markSeen() {
        guard isUnseen else { return }
        isUnseen = false
        onChange?(self)
    }

    /// The agent is being started again in the tab's shell.
    func restarting() {
        transition(to: .starting)
    }

    func processExited() {
        pendingRequest = nil
        currentStep = nil
        transition(to: .ended)
    }

    private func transition(to newState: State, message: String? = nil) {
        guard newState != state || message != self.message else { return }
        state = newState
        self.message = message
        isUnseen = newState == .needsPermission || newState == .finished
        onChange?(self)
    }

    private func recordTouchedFile(_ event: [String: Any]) {
        guard let tool = event["tool_name"] as? String, let input = event["tool_input"] as? [String: Any] else { return }
        let paths: [String]
        if tool == Self.patchTool {
            paths = Self.patchedPaths(input["command"] as? String ?? "")
        } else if Self.fileWritingTools.contains(tool),
                  let path = Self.filePathKeys.lazy.compactMap({ input[$0] as? String }).first(where: { !$0.isEmpty }) {
            paths = [path]
        } else {
            return
        }

        for var path in paths {
            if !path.hasPrefix("/"), let cwd = event["cwd"] as? String {
                path = (cwd as NSString).appendingPathComponent(path)
            }
            path = (path as NSString).standardizingPath

            var file = touchedFiles.first { $0.path == path } ?? TouchedFile(path: path, edits: 0, lastTouched: .now)
            file.edits += 1
            file.lastTouched = .now
            touchedFiles.removeAll { $0.path == path }
            touchedFiles.insert(file, at: 0)
        }
    }

    /// Files a Codex patch adds, changes, deletes or moves to, in order.
    static func patchedPaths(_ patch: String) -> [String] {
        let markers = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
        var paths: [String] = []
        for line in patch.split(separator: "\n") {
            guard let marker = markers.first(where: { line.hasPrefix($0) }) else { continue }
            let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    static func describeTool(_ event: [String: Any]) -> String? {
        guard let tool = event["tool_name"] as? String else { return nil }
        let input = event["tool_input"] as? [String: Any]
        if tool == patchTool, let file = patchedPaths(input?["command"] as? String ?? "").first {
            return "\(tool): \((file as NSString).lastPathComponent)"
        }
        if let command = input?["command"] as? String {
            return "\(tool): \(firstLine(command))"
        }
        if let path = input?["file_path"] as? String {
            return "\(tool): \((path as NSString).lastPathComponent)"
        }
        return tool
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }
}
