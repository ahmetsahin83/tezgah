import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct ClaudeTouchedFilesTests {
    private func toolEvent(_ tool: String, _ input: [String: Any], cwd: String = "/repo") -> [String: Any] {
        ["hook_event_name": "PostToolUse", "tool_name": tool, "tool_input": input, "cwd": cwd]
    }

    @Test func recordsOnlyFileWritingTools() {
        let activity = ClaudeActivity()
        activity.handle(toolEvent("Read", ["file_path": "/repo/a.swift"]))
        activity.handle(toolEvent("Bash", ["command": "ls"]))
        activity.handle(toolEvent("Edit", ["file_path": "/repo/a.swift", "old_string": "x", "new_string": "y"]))
        activity.handle(toolEvent("Write", ["file_path": "/repo/new.swift", "content": "x"]))
        activity.handle(toolEvent("NotebookEdit", ["notebook_path": "/repo/n.ipynb"]))
        activity.handle(toolEvent("MultiEdit", ["file_path": "sub/../b.swift"])) // relative to cwd
        activity.handle(toolEvent("Edit", ["file_path": "/repo/a.swift"]))

        #expect(activity.touchedFiles.map(\.path) == ["/repo/a.swift", "/repo/b.swift", "/repo/n.ipynb", "/repo/new.swift"])
        #expect(activity.touchedFiles.first?.edits == 2)
        #expect(activity.state == .working)
    }
}

@MainActor
@Suite struct ClaudeUsageParsingTests {
    /// Shape captured from Claude Code 2.1.296, plus documented fields that appear after a reply.
    private let status: [String: Any] = [
        "session_id": "s1",
        "model": ["id": "claude-opus-5-5", "display_name": "Opus"],
        "cost": [
            "total_cost_usd": 0.4217, "total_duration_ms": 81900, "total_api_duration_ms": 41000,
            "total_lines_added": 120, "total_lines_removed": 30,
        ],
        "context_window": [
            "total_input_tokens": 45_200, "total_output_tokens": 1_250, "context_window_size": 1_000_000,
            "used_percentage": 4.52, "remaining_percentage": 95.48,
        ],
        "rate_limits": [
            "five_hour": ["used_percentage": 42, "resets_at": 1_791_700_000],
            "seven_day": ["used_percentage": 18.5, "resets_at": "2026-10-14T09:00:00Z"],
        ],
    ]

    @Test func readsStatusLineData() throws {
        let activity = ClaudeActivity()
        activity.updateUsage(from: status)
        let usage = try #require(activity.usage)
        #expect(usage.model == "Opus")
        #expect(usage.costUSD == 0.4217)
        #expect(usage.lastRequestInputTokens == 45_200)
        #expect(usage.lastRequestOutputTokens == 1_250)
        #expect(usage.contextUsedPercent == 4.52)
        #expect(usage.contextWindowSize == 1_000_000)
        #expect(usage.linesAdded == 120 && usage.linesRemoved == 30)
        #expect(usage.fiveHourLimit?.usedPercent == 42)
        #expect(usage.fiveHourLimit?.resetsAt == Date(timeIntervalSince1970: 1_791_700_000))
        #expect(usage.weeklyLimit?.usedPercent == 18.5)
        #expect(usage.weeklyLimit?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-14T09:00:00Z"))
    }

    @Test func toleratesTheStateBeforeTheFirstReply() throws {
        let activity = ClaudeActivity()
        activity.updateUsage(from: [
            "model": ["display_name": "Opus"],
            "cost": ["total_cost_usd": 0, "total_lines_added": 0, "total_lines_removed": 0],
            "context_window": ["total_input_tokens": 0, "total_output_tokens": 0, "context_window_size": 1_000_000,
                               "used_percentage": NSNull(), "current_usage": NSNull()],
        ])
        let usage = try #require(activity.usage)
        #expect(usage.contextUsedPercent == nil)
        #expect(usage.fiveHourLimit == nil)
        #expect(usage.costUSD == 0)
    }

    @Test func compactTokenCounts() {
        #expect(ClaudeUsageView.compact(950) == "950")
        #expect(ClaudeUsageView.compact(45_200).hasSuffix("k"))
        #expect(ClaudeUsageView.compact(45_200).hasPrefix("45"))
        #expect(ClaudeUsageView.compact(1_000_000) == "1M")
    }
}

@MainActor
@Suite struct ClaudeStatusLineTests {
    private func makeMonitor() throws -> (ClaudeMonitor, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-status-\(UUID().uuidString)")
        let monitor = ClaudeMonitor(directory: directory, hookURL: directory.appendingPathComponent("hook.sh"))
        try monitor.start()
        return (monitor, directory)
    }

    private func settings(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func statusLineOnlyInTheFullSettingsFile() throws {
        let (monitor, directory) = try makeMonitor()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }
        #expect(try settings(monitor.settingsURL)["statusLine"] != nil)
        #expect(try settings(monitor.hooksOnlySettingsURL)["statusLine"] == nil)
        #expect(try settings(monitor.hooksOnlySettingsURL)["hooks"] != nil)

        let command = monitor.command(for: .new, claudePath: "/c", shell: "/bin/zsh", withStatusLine: false)
        #expect(command.contains("settings-hooks-only.json"))
    }

    @Test func remoteControlIsAskedForByName() throws {
        let (monitor, directory) = try makeMonitor()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }
        let command = monitor.command(for: .new, claudePath: "/c", shell: "/bin/zsh", remoteControlName: "work · Tezgah")
        #expect(command.contains("--remote-control 'work · Tezgah'"))
        #expect(!monitor.command(for: .new, claudePath: "/c", shell: "/bin/zsh").contains("--remote-control"))
    }

    @Test func detectsAStatusLineTheUserAlreadyHas() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-own-status-\(UUID().uuidString)")
        let config = base.appendingPathComponent("config")
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Data(#"{"theme":"dark"}"#.utf8).write(to: config.appendingPathComponent("settings.json"))
        #expect(!ClaudeMonitor.hasOwnStatusLine(projectURL: project, configDirectory: config))

        try Data(#"{"statusLine":{"type":"command","command":"x"}}"#.utf8).write(to: project.appendingPathComponent(".claude/settings.local.json"))
        #expect(ClaudeMonitor.hasOwnStatusLine(projectURL: project, configDirectory: config))
    }

    @Test func statusLineScriptFeedsTheTab() async throws {
        let (monitor, directory) = try makeMonitor()
        defer { monitor.stop(); try? FileManager.default.removeItem(at: directory) }
        let tab = UUID()
        let activity = ClaudeActivity()
        monitor.activityForTab = { $0 == tab ? activity : nil }

        let process = Process()
        process.executableURL = monitor.statusLineURL
        process.environment = AgentMonitor(directory: directory).environment(forTab: tab).merging(monitor.environment) { $1 }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":12}}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty) // Claude's own status line stays blank

        let deadline = Date().addingTimeInterval(4)
        while activity.usage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(activity.usage?.model == "Opus")
        #expect(activity.usage?.contextUsedPercent == 12)
    }

    @Test func configDirectoryHonoursClaudeConfigDir() {
        #expect(ClaudeMonitor.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"]).path == "/tmp/cc")
        #expect(ClaudeMonitor.configDirectory(environment: [:]).lastPathComponent == ".claude")
    }
}
