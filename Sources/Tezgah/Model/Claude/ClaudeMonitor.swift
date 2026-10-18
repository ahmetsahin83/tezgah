import Foundation

/// Launches Claude Code sessions so they report to Tezgah.
///
/// Each session is launched with `--settings <our file>`, which adds hooks (on top of the user's
/// own; Claude Code merges them) running `AgentMonitor`'s hook script, and a status line that
/// keeps the session's figures for Tezgah.
@MainActor
final class ClaudeMonitor {
    static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
        "Notification", "Stop", "SessionEnd",
    ]

    let directory: URL
    /// `AgentMonitor`'s script, which the hooks run.
    let hookURL: URL
    /// Latest status line data per tab (tokens, cost, context), one file each.
    var statusDirectory: URL { directory.appendingPathComponent("status", isDirectory: true) }
    /// Hooks plus our status line.
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    /// Hooks only, for users who have a status line of their own.
    var hooksOnlySettingsURL: URL { directory.appendingPathComponent("settings-hooks-only.json") }
    var statusLineURL: URL { directory.appendingPathComponent("statusline.sh") }

    /// Finds the activity for a tab id.
    var activityForTab: (UUID) -> ClaudeActivity? = { _ in nil }

    private var statusWatcher: FileWatcher?

    init(directory: URL, hookURL: URL) {
        self.directory = directory
        self.hookURL = hookURL
    }

    /// Claude Code's own settings folder (~/.claude unless CLAUDE_CONFIG_DIR says otherwise).
    nonisolated static func configDirectory(environment: [String: String]) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    /// Writes the status line script and settings files and starts watching for status updates.
    func start() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        // Files from a previous run belong to tabs that no longer exist.
        for leftover in (try? fileManager.contentsOfDirectory(at: statusDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: leftover)
        }

        try Data(Self.statusLineScript.utf8).write(to: statusLineURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusLineURL.path)
        try settingsJSON(includingStatusLine: true).write(to: settingsURL)
        try settingsJSON(includingStatusLine: false).write(to: hooksOnlySettingsURL)

        statusWatcher = FileWatcher(url: statusDirectory) { [weak self] _ in
            self?.readStatus()
        }
        statusWatcher?.start(latency: 0.2)
    }

    func stop() {
        statusWatcher?.stop()
        statusWatcher = nil
    }

    /// The shell command a Claude tab runs. When Claude Code exits the tab becomes a normal shell.
    /// `withStatusLine: false` leaves a status line the user configured alone. `readOnly` takes
    /// away the tools that edit files, for a reviewer. `skipPermissions` never asks before a tool;
    /// a read-only session still has no tools that edit files. `asksQuestions: false` takes away
    /// AskUserQuestion, for an agent nobody is there to answer. `effort` sets how hard it thinks.
    func command(
        for launch: AgentLaunch, claudePath: String, shell: String, withStatusLine: Bool = true, thenShell: Bool = true,
        mcpConfig: String? = nil, remoteControlName: String? = nil, model: String? = nil, effort: String? = nil,
        readOnly: Bool = false, skipPermissions: Bool = false, asksQuestions: Bool = true
    ) -> String {
        let settings = withStatusLine ? settingsURL : hooksOnlySettingsURL
        var parts = [AgentMonitor.quote(claudePath)]
        var disallowed = readOnly ? AgentActivity.fileWritingTools : []
        if !asksQuestions { disallowed.insert("AskUserQuestion") }
        if !disallowed.isEmpty {
            // A list; the next flag ends it.
            parts += ["--disallowedTools"] + disallowed.sorted()
        }
        parts += ["--settings", AgentMonitor.quote(settings.path)]
        if skipPermissions {
            parts.append("--dangerously-skip-permissions")
        }
        if let model {
            parts += ["--model", AgentMonitor.quote(model)]
        }
        if let effort {
            parts += ["--effort", AgentMonitor.quote(effort)]
        }
        if let remoteControlName {
            parts += ["--remote-control", AgentMonitor.quote(remoteControlName)]
        }
        if let mcpConfig {
            // Tezgah's own tools (browser preview, simulator, board). The next flag ends the list.
            parts += ["--mcp-config", AgentMonitor.quote(mcpConfig)]
        }
        switch launch {
        case .new: break
        case .continueLast: parts.append("--continue")
        case .pick: parts.append("--resume")
        case .resume(let id): parts += ["--resume", AgentMonitor.quote(id)]
        }
        let command = parts.joined(separator: " ")
        return thenShell ? command + "; exec \(AgentMonitor.quote(shell)) -l" : command
    }

    /// Added to `AgentMonitor`'s variables, which give the status line the tab's id. The tool
    /// timeout lets agent_wait wait for other agents for up to half an hour.
    var environment: [String: String] {
        ["TEZGAH_STATUS_DIR": statusDirectory.path, "MCP_TOOL_TIMEOUT": String(WorkspaceStore.maxAgentWait * 1000)]
    }

    /// Whether the user or the project already configures a status line, which ours would replace.
    static func hasOwnStatusLine(projectURL: URL, configDirectory: URL) -> Bool {
        let candidates = [
            configDirectory.appendingPathComponent("settings.json"),
            projectURL.appendingPathComponent(".claude/settings.json"),
            projectURL.appendingPathComponent(".claude/settings.local.json"),
        ]
        return candidates.contains { url in
            guard let data = try? Data(contentsOf: url),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return settings["statusLine"] != nil
        }
    }

    /// Reads the latest status line data of every tab.
    func readStatus() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: statusDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in files where url.pathExtension == "json" {
            guard let tabID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let activity = activityForTab(tabID) else {
                try? FileManager.default.removeItem(at: url) // tab is gone
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            activity.updateUsage(from: status)
        }
    }

    private func settingsJSON(includingStatusLine: Bool) throws -> Data {
        let hook: [String: Any] = ["type": "command", "command": AgentMonitor.quote(hookURL.path), "timeout": 10]
        var hooks: [String: Any] = [:]
        for event in Self.hookedEvents {
            hooks[event] = [["matcher": "*", "hooks": [hook]]]
        }
        // Tezgah's tools only show things inside Tezgah; asking before each would get in the way.
        var settings: [String: Any] = ["hooks": hooks, "permissions": ["allow": ["mcp__tezgah"]]]
        if includingStatusLine {
            settings["statusLine"] = ["type": "command", "command": AgentMonitor.quote(statusLineURL.path), "padding": 0]
        }
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    /// Claude Code runs the status line command with session data (tokens, cost, context) on stdin
    /// and shows what it prints. This one keeps the latest data for the app and prints nothing;
    /// Tezgah shows it in its own bar under the tab.
    static let statusLineScript = """
    #!/bin/sh
    # Written by Tezgah on every launch. Saves Claude Code status line data for the app.
    if [ -z "$TEZGAH_TAB_ID" ] || [ ! -d "$TEZGAH_STATUS_DIR" ]; then
        cat > /dev/null
        exit 0
    fi
    tmp=$(mktemp "$TEZGAH_STATUS_DIR/.incoming.XXXXXX") || exit 0
    cat > "$tmp"
    mv -f "$tmp" "$TEZGAH_STATUS_DIR/$TEZGAH_TAB_ID.json"
    exit 0

    """
}
