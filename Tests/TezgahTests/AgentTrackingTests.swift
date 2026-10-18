import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct AgentActivityTests {
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        extra.merging(["hook_event_name": name, "session_id": "s1"]) { $1 }
    }

    /// The states come from the shared hook events alone, with no agent's extras involved.
    @Test func followsATurnWithoutAnySubclass() {
        let activity = AgentActivity(provider: .claude)
        activity.handle(event("SessionStart"))
        activity.handle(event("UserPromptSubmit", ["prompt": "fix it"]))
        activity.handle(event("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "a.swift"], "cwd": "/repo"]))
        #expect(activity.state == .working)
        #expect(activity.touchedFiles.map(\.path) == ["/repo/a.swift"])

        activity.handle(event("Stop", ["last_assistant_message": "Done."]))
        #expect(activity.state == .finished)
        #expect(activity.message == "Done.")
        #expect(activity.needsAttention)
    }

    /// Listeners of a state change see Claude's own fields already updated, e.g. that a
    /// finished turn wants prompt suggestions.
    @Test func claudeExtrasAreReadyWhenTheStateChanges() {
        let activity = ClaudeActivity()
        var wantedSuggestionsOnFinish: Bool?
        activity.onChange = { changed in
            if changed.state == .finished { wantedSuggestionsOnFinish = (changed as? ClaudeActivity)?.wantsSuggestions }
        }
        activity.suggestions = ["Run the tests"]
        activity.handle(event("UserPromptSubmit"))
        #expect(activity.suggestions.isEmpty)
        activity.handle(event("Stop"))
        #expect(wantedSuggestionsOnFinish == true)
    }
}

@MainActor
@Suite struct AgentMonitorTests {
    private func makeMonitor() throws -> (AgentMonitor, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-agents-\(UUID().uuidString)")
        let monitor = AgentMonitor(directory: directory)
        try monitor.start()
        return (monitor, directory)
    }

    /// Runs the hook script the way an agent would: event JSON on stdin.
    private func runHook(_ monitor: AgentMonitor, json: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = monitor.hookURL
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(json.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func writesAnExecutableHook() throws {
        let (monitor, directory) = try makeMonitor()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }
        let attributes = try FileManager.default.attributesOfItem(atPath: monitor.hookURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)
    }

    @Test func hookIsSilentAndInertOutsideTezgah() throws {
        let (monitor, directory) = try makeMonitor()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }

        let output = try runHook(monitor, json: #"{"hook_event_name":"Stop"}"#, environment: [:])
        #expect(output.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: monitor.eventsDirectory.path).isEmpty)
    }

    @Test func routesHookEventsToTheirTab() async throws {
        let (monitor, directory) = try makeMonitor()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }

        let tab = UUID()
        let activity = AgentActivity(provider: .claude)
        monitor.activityForTab = { $0 == tab ? activity : nil }

        let environment = monitor.environment(forTab: tab)
        let output = try runHook(monitor, json: #"{"hook_event_name":"UserPromptSubmit","session_id":"abc"}"#, environment: environment)
        #expect(output.isEmpty) // UserPromptSubmit output would be shown to the model
        _ = try runHook(monitor, json: #"{"hook_event_name":"Stop","session_id":"abc","last_assistant_message":"Bitti"}"#, environment: environment)

        let deadline = Date().addingTimeInterval(4)
        while activity.state != .finished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(activity.state == .finished)
        #expect(activity.message == "Bitti")
        #expect(activity.sessionID == "abc")
        #expect(try FileManager.default.contentsOfDirectory(atPath: monitor.eventsDirectory.path).isEmpty) // consumed
    }
}

@MainActor
@Suite struct CodexTrackingTests {
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        extra.merging(["hook_event_name": name, "session_id": "c1", "cwd": "/repo"]) { $1 }
    }

    @Test func patchesCountAsTouchedFiles() {
        let activity = AgentActivity(provider: .codex)
        let patch = """
        *** Begin Patch
        *** Add File: notes/hello.txt
        +hello
        *** Update File: Sources/App.swift
        *** Move to: Sources/Main.swift
        @@
        -old
        +new
        *** Delete File: /repo/old.txt
        *** End Patch
        """
        activity.handle(event("UserPromptSubmit"))
        activity.handle(event("PreToolUse", ["tool_name": "apply_patch", "tool_input": ["command": patch]]))
        #expect(activity.currentStep == "apply_patch: hello.txt")
        activity.handle(event("PostToolUse", ["tool_name": "apply_patch", "tool_input": ["command": patch]]))
        #expect(Set(activity.touchedFiles.map(\.path))
            == ["/repo/notes/hello.txt", "/repo/Sources/App.swift", "/repo/Sources/Main.swift", "/repo/old.txt"])

        activity.handle(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "swift build\n--verbose"]]))
        #expect(activity.currentStep == "Bash: swift build")
    }

    @Test func interruptSettlesTheTurnQuietly() {
        let activity = AgentActivity(provider: .codex)
        activity.handle(event("UserPromptSubmit"))
        activity.handle(event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]))
        #expect(activity.state == .needsPermission)
        activity.handle(event("Interrupt"))
        #expect(activity.state == .idle)
        #expect(activity.pendingRequest == nil)
        #expect(!activity.needsAttention)
    }

    /// Codex's SessionStart waits for the first prompt, so its UI showing up is what makes it ready.
    @Test func codexIsReadyOnceItsUIAppears() {
        let codex = AgentActivity(provider: .codex)
        var readyCalls = 0
        codex.onReady = { readyCalls += 1 }
        #expect(codex.isWaitingForUI)
        codex.uiAppeared()
        #expect(codex.state == .idle)
        #expect(readyCalls == 1)
        codex.uiAppeared() // its title keeps changing while it works
        #expect(readyCalls == 1)

        // Claude Code says so with its own SessionStart; its title may come while a dialog is open.
        let claude = ClaudeActivity()
        #expect(!claude.isWaitingForUI)
        claude.uiAppeared()
        #expect(claude.state == .starting)
    }
}

@MainActor
@Suite struct CodexMonitorTests {
    private let monitor = CodexMonitor(hookURL: URL(fileURLWithPath: "/tmp/a b/hook.sh"))

    /// Values Codex itself reported for these hooks (`hooks/list` in its app server).
    @Test func trustHashMatchesCodex() {
        #expect(CodexMonitor.trustHash(event: "SessionStart", command: "'/Applications/Tez gah.app/hook.sh' SessionStart")
            == "sha256:d00edc112edbf27ffeea991c9a8501f382fd811b12deeb1d84fd017e5ece77bc")
        // SessionEnd and Interrupt have a shorter default timeout, which is part of the hash.
        #expect(CodexMonitor.trustHash(event: "SessionEnd", command: "/tmp/h.sh")
            == "sha256:f3f1c5be6b820e0f1631cd35c93221bb3a68e50e62157345b6cd95e71b89dad9")
    }

    @Test func eventNamesInSnakeCase() {
        #expect(CodexMonitor.snakeCase("PreToolUse") == "pre_tool_use")
        #expect(CodexMonitor.snakeCase("Stop") == "stop")
    }

    @Test func passesItsHooksAndTrustsOnlyThem() throws {
        let overrides = monitor.overrides(mcpURL: nil)
        let hookCommand = #"'/tmp/a b/hook.sh'"#
        for event in CodexMonitor.hookedEvents {
            #expect(overrides.contains(#"hooks.\#(event)=[{hooks=[{type="command",command="\#(hookCommand)"}]}]"#))
        }
        let trust = try #require(overrides.first { $0.hasPrefix("hooks.state=") })
        for event in CodexMonitor.hookedEvents {
            let key = "/<session-flags>/config.toml:\(CodexMonitor.snakeCase(event)):0:0"
            let hash = CodexMonitor.trustHash(event: event, command: hookCommand)
            #expect(trust.contains(#""\#(key)"={trusted_hash="\#(hash)"}"#))
        }
        #expect(!overrides.contains { $0.contains("mcp_servers") })
    }

    @Test func toolsComeWithTheTokenFromTheEnvironment() {
        let overrides = monitor.overrides(mcpURL: "http://127.0.0.1:4242/mcp/TAB")
        #expect(overrides.contains(#"mcp_servers.tezgah.url="http://127.0.0.1:4242/mcp/TAB""#))
        #expect(overrides.contains(#"mcp_servers.tezgah.bearer_token_env_var="TEZGAH_MCP_TOKEN""#))
        #expect(overrides.contains(#"mcp_servers.tezgah.default_tools_approval_mode="approve""#))
    }

    @Test func launchCommands() {
        let new = monitor.command(for: .new, codexPath: "/opt/homebrew/bin/codex", shell: "/bin/zsh")
        #expect(new.hasPrefix("'/opt/homebrew/bin/codex' --no-daemon -c "))
        #expect(new.hasSuffix("; exec '/bin/zsh' -l"))
        #expect(!new.contains("bypass"))
        // Quoted for the shell: the hook command's own quotes survive.
        #expect(new.contains(#"-c 'hooks.Stop=[{hooks=[{type="command",command="'\''/tmp/a b/hook.sh'\''"}]}]'"#))

        #expect(monitor.command(for: .continueLast, codexPath: "/c", shell: "/bin/zsh").hasPrefix("'/c' resume --last --no-daemon "))
        #expect(monitor.command(for: .pick, codexPath: "/c", shell: "/bin/zsh").hasPrefix("'/c' resume --no-daemon "))
        let resume = monitor.command(for: .resume(sessionID: "019a-uuid"), codexPath: "/c", shell: "/bin/zsh", thenShell: false)
        #expect(resume.hasPrefix("'/c' resume --no-daemon "))
        #expect(resume.hasSuffix(" '019a-uuid'"))
    }

    @Test func tomlStringsAreEscaped() {
        #expect(CodexMonitor.tomlString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }
}

@MainActor
@Suite struct CodexTabTests {
    @Test func aCodexTabIsSavedForResumingOnlyOnceItHasASession() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        let activity = AgentActivity(provider: .codex)
        let session = TerminalSession(directory: project.url, title: "Codex", command: "cat", agent: activity)
        defer { session.terminate() }
        project.tabs.append(.terminal(session))

        activity.uiAppeared()
        #expect(WorkspaceStore.state(of: project).tabs.isEmpty) // no prompt yet, nothing to resume

        activity.handle(["hook_event_name": "SessionStart", "session_id": "019a-uuid", "source": "startup"])
        #expect(WorkspaceStore.state(of: project).tabs == [.codex(sessionID: "019a-uuid", directory: project.url.path)])
    }
}
