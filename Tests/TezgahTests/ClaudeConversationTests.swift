import AppKit
import Foundation
import Testing
import WebKit
@testable import Tezgah

@Suite struct ClaudeTranscriptParserTests {
    private func parse(_ records: [[String: Any]]) -> ClaudeTranscriptParser {
        var parser = ClaudeTranscriptParser()
        for record in records {
            parser.consume(line: try! JSONSerialization.data(withJSONObject: record))
        }
        return parser
    }

    private func user(_ content: Any, uuid: String = UUID().uuidString, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "user", "uuid": uuid, "timestamp": "2026-10-10T18:43:42.044Z", "message": ["role": "user", "content": content]]
            .merging(extra) { $1 }
    }

    private func assistant(_ blocks: [[String: Any]], uuid: String = UUID().uuidString) -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "message": ["role": "assistant", "content": blocks]]
    }

    @Test func promptReplyAndToolWithResult() {
        let parser = parse([
            user("fix the build"),
            assistant([["type": "thinking", "thinking": ""]]),
            assistant([["type": "text", "text": "Let me look."]], uuid: "a1"),
            assistant([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift build"]]]),
            user([["type": "tool_result", "tool_use_id": "t1", "content": "Build complete!"]],
                 extra: ["toolUseResult": ["stdout": "Build complete!", "stderr": "", "interrupted": false]]),
            ["type": "ai-title", "aiTitle": "Fixing the build"],
        ])
        #expect(parser.title == "Fixing the build")
        #expect(parser.entries.count == 3)
        #expect(parser.entries[0].kind == .prompt(text: "fix the build", images: 0))
        #expect(parser.entries[1].kind == .reply("Let me look."))
        guard case .tool(let call) = parser.entries[2].kind else {
            Issue.record("expected a tool")
            return
        }
        #expect(call.name == "Bash")
        #expect(call.input["command"]?.string == "swift build")
        #expect(call.result?.text == "Build complete!")
        #expect(call.result?.details?["stdout"]?.string == "Build complete!")
    }

    @Test func skipsWhatTheUserDidNotType() {
        let parser = parse([
            user("<system-reminder>\nsecret context\n</system-reminder>"),
            user("[Image: original 100x100]", extra: ["isMeta": true]),
            user([["type": "text", "text": "<system-reminder>x</system-reminder>"]]),
            user("summary of earlier", extra: ["isCompactSummary": true]),
            user("hello", extra: ["isSidechain": true]),
        ])
        #expect(parser.entries.isEmpty)
    }

    @Test func commandsShellAndInterruptions() {
        let parser = parse([
            user("<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args>keep the plan</command-args>"),
            user("<local-command-stdout>\u{1B}[2mCompacted\u{1B}[22m</local-command-stdout>"),
            user("<bash-input>git status</bash-input>"),
            user("<bash-stdout>On branch main</bash-stdout><bash-stderr></bash-stderr>"),
            user([["type": "text", "text": "[Request interrupted by user for tool use]"]]),
        ])
        #expect(parser.entries.map(\.kind) == [
            .command(name: "/compact", arguments: "keep the plan", output: "Compacted"),
            .shell(command: "git status", output: "On branch main"),
            .notice("Durduruldu"),
        ])
    }

    @Test func imagesAreCounted() {
        let parser = parse([
            user([["type": "text", "text": "[Image #1] what is this"], ["type": "image", "source": [:]]]),
        ])
        #expect(parser.entries.first?.kind == .prompt(text: "what is this", images: 1))
    }

    @Test func customTitleWins() {
        let parser = parse([
            ["type": "ai-title", "aiTitle": "Generated"],
            ["type": "custom-title", "customTitle": "Mine"],
            ["type": "ai-title", "aiTitle": "Generated again"],
        ])
        #expect(parser.title == "Mine")
    }
}

@MainActor
@Suite struct ClaudeConversationRendererTests {
    private func tool(_ id: String, _ name: String, _ input: [String: Any], result: String? = "ok") -> ClaudeTranscriptEntry {
        var call = ClaudeToolCall(id: id, name: name, input: JSONValue(input))
        if let result { call.result = .init(text: result, isError: false, details: nil) }
        return ClaudeTranscriptEntry(id: id, kind: .tool(call), date: nil)
    }

    private let context = ClaudeConversationRenderer.Context(isWorking: false, pendingTool: nil, canShowSessionDiff: false)

    @Test func foldsRunsOfLookingAround() {
        let renderer = ClaudeConversationRenderer(root: URL(fileURLWithPath: "/tmp"))
        let entries = [
            tool("1", "Read", ["file_path": "/tmp/a.swift"]),
            tool("2", "Grep", ["pattern": "foo"]),
            tool("3", "Read", ["file_path": "/tmp/b.swift"]),
            tool("4", "Edit", ["file_path": "/tmp/a.swift", "old_string": "a", "new_string": "b"]),
            tool("5", "Read", ["file_path": "/tmp/c.swift"]),
        ]
        let blocks = renderer.blocks(for: entries, context: context)
        #expect(blocks.map(\.id) == ["1", "4", "5"])
        #expect(blocks[0].html.contains("2 dosya okundu · 1 arama"))
        #expect(blocks[1].html.contains("Düzenledi"))
        #expect(blocks[1].html.contains(#"class="added">+1"#))
    }

    @Test func runningAndWaitingCalls() {
        let renderer = ClaudeConversationRenderer(root: URL(fileURLWithPath: "/tmp"))
        let entries = [tool("1", "Bash", ["command": "make"], result: nil)]
        let running = renderer.blocks(for: entries, context: .init(isWorking: true, pendingTool: nil, canShowSessionDiff: false))
        #expect(running[0].html.contains("spinner"))
        let waiting = renderer.blocks(for: entries, context: .init(isWorking: true, pendingTool: "Bash", canShowSessionDiff: false))
        #expect(waiting[0].html.contains("Onay bekliyor"))
        let stopped = renderer.blocks(for: entries, context: context)
        #expect(stopped[0].html.contains("Yanıtsız"))
    }

    @Test func markdownGetsHighlightedCodeAndFileLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Sources/App.swift"))
        defer { try? FileManager.default.removeItem(at: folder) }

        let renderer = ClaudeConversationRenderer(root: folder)
        let markdown = "See `Sources/App.swift:12` and `missing.swift`.\n\n```swift\nlet x = \"a < b\"\n```"
        let html = renderer.blocks(for: [.init(id: "r", kind: .reply(markdown), date: nil)], context: context)[0].html
        #expect(html.contains("tezgah-open://file?path="))
        #expect(html.contains("&line=12"))
        #expect(!html.contains("missing.swift</code></a>"))
        #expect(html.contains(#"<span class="k">let</span>"#))
        #expect(html.contains("&quot;a &lt; b&quot;") || html.contains("a &lt; b"))
        #expect(html.contains("Kopyala"))
    }

    @Test func shellCommandsCanBeRunAgain() {
        let renderer = ClaudeConversationRenderer(root: URL(fileURLWithPath: "/tmp"))
        let bash = renderer.blocks(for: [tool("1", "Bash", ["command": "swift build && echo 'ok'"])], context: context)[0].html
        let link = try! #require(bash.firstMatch(of: #/href="(tezgah-run://[^"]+)"/#)?.1)
        let url = try! #require(URL(string: String(link)))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift build && echo 'ok'")

        let reply = renderer.blocks(for: [.init(id: "r", kind: .reply("```bash\nmake test\n```\n```swift\nlet a = 1\n```"), date: nil)], context: context)[0].html
        #expect(reply.components(separatedBy: #"data-action="run""#).count == 2) // only the shell block
    }

    @Test func promptTextIsEscaped() {
        let renderer = ClaudeConversationRenderer(root: URL(fileURLWithPath: "/tmp"))
        let html = renderer.blocks(for: [.init(id: "p", kind: .prompt(text: "<script>alert(1)</script>", images: 0), date: nil)], context: context)[0].html
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }
}

/// Renders a real transcript to PNGs for looking at the design:
/// `TEZGAH_SNAPSHOT_TRANSCRIPT=<file.jsonl> TEZGAH_SNAPSHOT_DIR=<folder> swift test --filter ConversationSnapshot`
@MainActor
@Suite struct ConversationSnapshot {
    @Test func renderTranscript() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let transcriptPath = environment["TEZGAH_SNAPSHOT_TRANSCRIPT"], let outputPath = environment["TEZGAH_SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: environment["TEZGAH_SNAPSHOT_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let width = Double(environment["TEZGAH_SNAPSHOT_WIDTH"] ?? "") ?? 920
        let limit = Int(environment["TEZGAH_SNAPSHOT_ENTRIES"] ?? "") ?? 60

        var parser = ClaudeTranscriptParser()
        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        for line in data.split(separator: 0x0A) { parser.consume(line: Data(line)) }
        let skip = Int(environment["TEZGAH_SNAPSHOT_SKIP"] ?? "") ?? 0
        var all = parser.entries
        if let only = environment["TEZGAH_SNAPSHOT_ONLY"] {
            all = all.filter { if case .tool(let call) = $0.kind { only.split(separator: ",").contains(Substring(call.name)) } else { false } }
        }
        let entries = Array(all.dropFirst(skip).prefix(limit))

        let renderer = ClaudeConversationRenderer(root: root)
        let blocks = renderer.blocks(for: entries, context: .init(isWorking: true, pendingTool: nil, canShowSessionDiff: true))
        let payload: [String: Any] = ["blocks": blocks.map { ["id": $0.id, "html": $0.html] }, "order": blocks.map(\.id), "initial": true]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let status = #"{"mode":"working","text":"Bash: swift build","since":\#(Date().timeIntervalSince1970 * 1000 - 14000)}"#

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            let webView = WKWebView(frame: window.contentView!.bounds)
            webView.appearance = NSAppearance(named: appearance)
            window.contentView!.addSubview(webView)
            window.backgroundColor = appearance == .darkAqua ? NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x24 / 255, alpha: 1) : .white
            webView.loadHTMLString(ClaudeConversationView.Coordinator.page(projectName: "tezgah", agentName: "Claude"), baseURL: nil)
            while webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(200))
            _ = try? await webView.evaluateJavaScript("apply(\(json)); setStatus(\(status)); document.body.style.background = '\(appearance == .darkAqua ? "#1F1F24" : "#FFFFFF")'; document.querySelectorAll('details').forEach(d => { if (d.classList.contains('explored')) d.open = true; }); 0")
            try await Task.sleep(for: .milliseconds(400))
            let height = (try? await webView.evaluateJavaScript("document.documentElement.scrollHeight")) as? Double ?? 900
            window.setContentSize(NSSize(width: width, height: min(height, 16000)))
            webView.frame = window.contentView!.bounds
            try await Task.sleep(for: .milliseconds(400))
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            let image = try await webView.takeSnapshot(configuration: configuration)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath).appendingPathComponent("conversation-\(name).png"))
        }
    }
}

@MainActor
@Suite struct ClaudeTranscriptFollowingTests {
    @Test func picksUpAppendedRecords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("s.jsonl")
        func line(_ text: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": "user", "uuid": UUID().uuidString, "message": ["role": "user", "content": text]]) + Data([0x0A])
        }
        try line("first").write(to: file)

        let transcript = ClaudeTranscript(url: file)
        transcript.start()
        for _ in 0..<100 where transcript.entries.count < 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transcript.entries.count == 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("second"))
        try handle.close()
        for _ in 0..<150 where transcript.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transcript.entries.count == 2)
    }
}

@MainActor
@Suite struct ClaudeSubagentFollowingTests {
    @Test func stepsOfASubagentAttachToItsCall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agents = folder.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func lines(_ records: [[String: Any]]) -> Data {
            records.map { try! JSONSerialization.data(withJSONObject: $0) + Data([0x0A]) }.reduce(Data(), +)
        }
        try lines([
            ["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "call-1", "name": "Agent", "input": ["description": "Look around", "prompt": "List files"]],
            ]]],
        ]).write(to: folder.appendingPathComponent("s1.jsonl"))
        try JSONSerialization.data(withJSONObject: ["toolUseId": "call-1"]).write(to: agents.appendingPathComponent("agent-x.meta.json"))
        try lines([
            ["type": "user", "uuid": "u1", "isSidechain": true, "message": ["role": "user", "content": "List files"]],
            ["type": "assistant", "uuid": "a2", "isSidechain": true, "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "sub-1", "name": "Bash", "input": ["command": "ls"]],
            ]]],
        ]).write(to: agents.appendingPathComponent("agent-x.jsonl"))

        let transcript = ClaudeTranscript(url: folder.appendingPathComponent("s1.jsonl"))
        transcript.start()
        for _ in 0..<100 where transcript.subagents["call-1"] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transcript.subagents["call-1"]?.count == 2)

        let renderer = ClaudeConversationRenderer(root: folder)
        let html = renderer.blocks(
            for: transcript.entries, subagents: transcript.subagents,
            context: .init(isWorking: true, pendingTool: nil, canShowSessionDiff: false)
        )[0].html
        #expect(html.contains("sub-steps"))
        #expect(html.contains("Bash: ls")) // the live step in the row
    }
}

@Suite struct ClaudeTodoListTests {
    private func call(_ id: String, _ name: String, _ input: [String: Any], result: String? = nil) -> ClaudeTranscriptEntry {
        var call = ClaudeToolCall(id: id, name: name, input: JSONValue(input))
        if let result { call.result = .init(text: result, isError: false, details: nil) }
        return .init(id: id, kind: .tool(call), date: nil)
    }

    @Test func followsTodoWrite() {
        let list = ClaudeTodoList.from([
            call("1", "TodoWrite", ["todos": [
                ["content": "Write tests", "activeForm": "Writing tests", "status": "completed"],
                ["content": "Fix bug", "activeForm": "Fixing the bug", "status": "in_progress"],
                ["content": "Ship", "status": "pending"],
            ]]),
        ])
        #expect(list.items.count == 3)
        #expect(list.completedCount == 1)
        #expect(list.current?.activeTitle == "Fixing the bug")
        #expect(list.isPinned)
    }

    @Test func followsTaskCreateAndUpdate() {
        var entries = [
            call("1", "TaskCreate", ["subject": "Read code", "activeForm": "Reading code"], result: "Task #1 created successfully"),
            call("2", "TaskCreate", ["subject": "Change it"], result: "Task #2 created successfully"),
            call("3", "TaskUpdate", ["taskId": "1", "status": "in_progress"]),
        ]
        var list = ClaudeTodoList.from(entries)
        #expect(list.current?.title == "Read code")

        entries += [
            call("4", "TaskUpdate", ["taskId": "1", "status": "completed"]),
            call("5", "TaskUpdate", ["taskId": "2", "status": "completed"]),
        ]
        list = ClaudeTodoList.from(entries)
        #expect(list.isFinished)
        #expect(list.isPinned) // finished in this turn: still shown

        entries.append(.init(id: "p", kind: .prompt(text: "next", images: 0), date: nil))
        #expect(!ClaudeTodoList.from(entries).isPinned) // the next turn moves on
    }
}

@MainActor
/// Keys measured against Claude Code 2.1's question dialog in a real terminal.
@Suite struct ClaudeQuestionKeysTests {
    typealias Answer = TerminalSession.QuestionAnswer

    @Test func singleChoiceAnswersAtOnce() {
        #expect(TerminalSession.keys(answering: [Answer(options: [2], optionCount: 2)]) == ["2"])
    }

    @Test func typedAnswerGoesThroughTypeSomething() {
        #expect(TerminalSession.keys(answering: [Answer(customText: "Green", optionCount: 2)]) == ["3", "Green", "\r"])
    }

    @Test func multiChoiceTicksThenMovesOnAndSubmits() {
        #expect(TerminalSession.keys(answering: [Answer(options: [3, 1], isMultiSelect: true, optionCount: 3)]) == ["1", "3", "\u{1B}[C", "1"])
    }

    @Test func severalQuestionsEndWithSubmit() {
        let keys = TerminalSession.keys(answering: [
            Answer(options: [2], optionCount: 2),
            Answer(options: [1, 2], isMultiSelect: true, optionCount: 3),
            Answer(customText: "XL", optionCount: 2),
        ])
        #expect(keys == ["2", "1", "2", "\u{1B}[C", "3", "XL", "\r", "1"])
    }
}

@Suite struct PromptSuggesterTests {
    @Test func readsTheArrayWhateverSurroundsIt() {
        #expect(PromptSuggester.parse(#"["Testleri çalıştır", "Commit at"]"#) == ["Testleri çalıştır", "Commit at"])
        #expect(PromptSuggester.parse("Here you go:\n```json\n[\"a\", \"b\", \"c\", \"d\"]\n```") == ["a", "b", "c"])
        #expect(PromptSuggester.parse("[]").isEmpty)
        #expect(PromptSuggester.parse("no idea").isEmpty)
    }
}
