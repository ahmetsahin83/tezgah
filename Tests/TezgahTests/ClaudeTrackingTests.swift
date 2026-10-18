import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct ClaudeActivityTests {
    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        extra.merging(["hook_event_name": name, "session_id": "s1"]) { $1 }
    }

    @Test func followsATypicalTurn() {
        let activity = ClaudeActivity()
        var changes: [ClaudeActivity.State] = []
        activity.onChange = { changes.append($0.state) }

        activity.handle(event("SessionStart", ["source": "startup"]))
        activity.handle(event("UserPromptSubmit", ["prompt": "fix it"]))
        activity.handle(event("PostToolUse", ["tool_name": "Read"]))
        activity.handle(event("PostToolUse", ["tool_name": "Edit"]))
        #expect(activity.state == .working)
        #expect(!activity.needsAttention)

        activity.handle(event("Stop", ["last_assistant_message": "Done.\nDetails follow"]))
        #expect(activity.state == .finished)
        #expect(activity.message == "Done.")
        #expect(activity.needsAttention)
        #expect(activity.sessionID == "s1")
        #expect(changes == [.idle, .working, .finished]) // repeated tool events don't re-notify

        activity.markSeen()
        #expect(!activity.needsAttention)
    }

    @Test func permissionPromptAndAnswer() {
        let activity = ClaudeActivity()
        activity.handle(event("UserPromptSubmit"))
        activity.handle(event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test\n--watch"]]))
        #expect(activity.state == .needsPermission)
        #expect(activity.message == "Bash: npm test")
        #expect(activity.needsAttention)

        // The Notification that follows keeps the more specific message.
        activity.handle(event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        #expect(activity.message == "Bash: npm test")

        activity.userAnswered()
        #expect(activity.state == .working)
        #expect(!activity.needsAttention)
    }

    @Test func permissionNotificationAloneIsEnough() {
        let activity = ClaudeActivity()
        activity.handle(event("UserPromptSubmit"))
        activity.handle(event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]))
        #expect(activity.state == .needsPermission)
        #expect(activity.message == "Claude needs your permission to use Bash")
    }

    @Test func idlePromptSettlesAnInterruptedTurnQuietly() {
        let activity = ClaudeActivity()
        activity.handle(event("UserPromptSubmit"))
        activity.handle(event("Notification", ["notification_type": "idle_prompt"]))
        #expect(activity.state == .idle)
        #expect(!activity.needsAttention)

        // After a normal finish, idle_prompt must not hide the "finished" mark.
        activity.handle(event("UserPromptSubmit"))
        activity.handle(event("Stop"))
        activity.handle(event("Notification", ["notification_type": "idle_prompt"]))
        #expect(activity.state == .finished)
        #expect(activity.needsAttention)
    }

    @Test func endsWithTheSession() {
        let activity = ClaudeActivity()
        activity.handle(event("SessionStart"))
        activity.handle(event("SessionEnd", ["reason": "prompt_input_exit"]))
        #expect(activity.state == .ended)
        activity.handle(event("UnknownFutureEvent"))
        #expect(activity.state == .ended)
    }
}

@MainActor
@Suite struct ClaudeMonitorTests {
    @Test func writesSettingsForEveryTrackedEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-claude-\(UUID().uuidString)")
        let hookURL = URL(fileURLWithPath: "/tmp/agents/hook.sh")
        let monitor = ClaudeMonitor(directory: directory, hookURL: hookURL)
        try monitor.start()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }

        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: monitor.settingsURL)) as? [String: Any]
        let hooks = try #require(settings?["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(ClaudeMonitor.hookedEvents))
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(stop.first?["command"] as? String == "'/tmp/agents/hook.sh'") // the agent monitor's script
    }

    @Test func launchCommandQuotesPaths() {
        let monitor = ClaudeMonitor(directory: URL(fileURLWithPath: "/tmp/it's here"), hookURL: URL(fileURLWithPath: "/tmp/hook.sh"))
        let command = monitor.command(for: .continueLast, claudePath: "/Users/a b/.local/bin/claude", shell: "/bin/zsh")
        #expect(command == #"'/Users/a b/.local/bin/claude' --settings '/tmp/it'\''s here/settings.json' --continue; exec '/bin/zsh' -l"#)
    }
}
