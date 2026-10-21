import CryptoKit
import Foundation

/// Launches Codex sessions so they report to Tezgah.
///
/// Codex runs a hook only once the user has trusted it. Tezgah passes its hooks on the command
/// line (`-c`) together with the trust for exactly those hooks, so no file of the user's is
/// touched and every other hook (the user's own, a project's `.codex`) still goes through
/// Codex's review. Sessions run with `--no-daemon`: inside Codex's shared background server,
/// hooks would see that server's environment instead of the tab's `TEZGAH_TAB_ID`.
@MainActor
final class CodexMonitor {
    static let hookedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd", "Interrupt",
    ]

    /// Where Codex keys the trust of hooks given with `-c`.
    static let sessionFlagsSource = "/<session-flags>/config.toml"

    /// `AgentMonitor`'s script, which the hooks run.
    let hookURL: URL

    init(hookURL: URL) {
        self.hookURL = hookURL
    }

    /// The shell command a Codex tab runs. When Codex exits the tab becomes a normal shell.
    /// `mcpURL` adds Tezgah's tools; the token comes from `TEZGAH_MCP_TOKEN` in the tab's environment.
    /// `prompt` is sent as the first message of a new session. `readOnly` runs its commands in
    /// Codex's read-only sandbox, for a reviewer. `skipPermissions` never asks for approval and runs
    /// without a sandbox, reviewers included, so they can build and test. `trustedFolders` are
    /// trusted for this session (see `AgentTrust`).
    func command(
        for launch: AgentLaunch, codexPath: String, shell: String, thenShell: Bool = true, mcpURL: String? = nil,
        prompt: String? = nil, model: String? = nil, effort: String? = nil, readOnly: Bool = false, skipPermissions: Bool = false,
        trustedFolders: [String] = []
    ) -> String {
        var parts = [AgentMonitor.quote(codexPath)]
        switch launch {
        case .new: break
        case .continueLast: parts += ["resume", "--last"]
        case .pick, .resume: parts.append("resume")
        }
        parts.append("--no-daemon")
        if let model {
            parts += ["--model", AgentMonitor.quote(model)]
        }
        if let effort {
            parts += ["-c", AgentMonitor.quote("model_reasoning_effort=\(Self.tomlString(effort))")]
        }
        if skipPermissions {
            // A reviewer too: its read-only sandbox can't even write a build cache, so it could
            // never run the build or the tests. It is told not to change files, and the orchestra
            // undoes whatever a review leaves in the worktree.
            parts.append("--dangerously-bypass-approvals-and-sandbox")
        } else if readOnly {
            parts += ["--sandbox", "read-only"]
        }
        var overrides = overrides(mcpURL: mcpURL)
        if let trust = AgentTrust.codexOverride(for: trustedFolders) { overrides.append(trust) }
        for override in overrides {
            parts += ["-c", AgentMonitor.quote(override)]
        }
        if case .resume(let id) = launch {
            parts.append(AgentMonitor.quote(id))
        } else if case .new = launch, let prompt, !prompt.isEmpty {
            parts.append(AgentMonitor.quote(prompt))
        }
        let command = parts.joined(separator: " ")
        return thenShell ? command + "; exec \(AgentMonitor.quote(shell)) -l" : command
    }

    /// `key=value` settings for `-c`, values in TOML.
    func overrides(mcpURL: String?) -> [String] {
        let hookCommand = AgentMonitor.quote(hookURL.path)
        var overrides = Self.hookedEvents.map { event in
            "hooks.\(event)=[{hooks=[{type=\"command\",command=\(Self.tomlString(hookCommand))}]}]"
        }
        // A dotted key can't be spelled out in `-c`, so the trust goes in as one inline table.
        let trust = Self.hookedEvents.map { event in
            let key = "\(Self.sessionFlagsSource):\(Self.snakeCase(event)):0:0"
            return "\(Self.tomlString(key))={trusted_hash=\(Self.tomlString(Self.trustHash(event: event, command: hookCommand)))}"
        }
        overrides.append("hooks.state={\(trust.joined(separator: ","))}")
        // Codex guesses that fast typing is a paste and turns Return into a new line; Tezgah's
        // prompts arrive as bracketed pastes, which need no guessing.
        overrides.append("tui.disable_paste_burst=true")
        // Its "Update available" screen waits for an answer before the session starts.
        overrides.append("check_for_update_on_startup=false")
        if let mcpURL {
            overrides += [
                "mcp_servers.tezgah.url=\(Self.tomlString(mcpURL))",
                "mcp_servers.tezgah.bearer_token_env_var=\"TEZGAH_MCP_TOKEN\"",
                // Tezgah's tools only show things inside Tezgah; asking before each would get in the way.
                "mcp_servers.tezgah.default_tools_approval_mode=\"approve\"",
                // agent_wait waits for other agents for up to half an hour.
                "mcp_servers.tezgah.tool_timeout_sec=\(WorkspaceStore.maxAgentWait).0",
            ]
        }
        return overrides
    }

    /// The hash Codex keeps for a trusted hook: SHA-256 of the handler's identity as compact JSON
    /// with sorted keys. Our handlers set only `type` and `command`, so the rest is Codex's defaults.
    static func trustHash(event: String, command: String) -> String {
        let defaultTimeout = ["SessionEnd", "Interrupt"].contains(event) ? 1 : 600
        let identity: [String: Any] = [
            "event_name": snakeCase(event),
            "hooks": [["type": "command", "command": command, "timeout": defaultTimeout, "async": false]],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "sha256:" + SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
    }

    /// "PreToolUse" → "pre_tool_use"
    static func snakeCase(_ event: String) -> String {
        event.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result += "_" }
            result += character.lowercased()
        }
    }

    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
