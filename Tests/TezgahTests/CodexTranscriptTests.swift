import Foundation
import Testing
@testable import Tezgah

/// Lines shaped like Codex 0.162's rollout files.
private let rollout = [
    #"{"timestamp":"2026-10-14T14:00:00.000Z","type":"session_meta","payload":{"id":"019a","cwd":"/repo"}}"#,
    #"{"timestamp":"2026-10-14T14:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<skills_instructions>…"}]}}"#,
    #"{"timestamp":"2026-10-14T14:00:02.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
    #"{"timestamp":"2026-10-14T14:00:02.100Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Bölme betiği ekle\nsıfıra bölmede hata versin"}]}}}"#,
    #"{"timestamp":"2026-10-14T14:00:03.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"Text","text":"Önce betiklere bakacağım.\n"}],"phase":"commentary"}}}"#,
    #"{"timestamp":"2026-10-14T14:00:04.000Z","type":"event_msg","payload":{"type":"item_started","item":{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","bash test_div.sh"],"status":"in_progress"}}}"#,
]

private let rest = [
    #"{"timestamp":"2026-10-14T14:00:05.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"c1","command":["/bin/zsh","-lc","bash test_div.sh"],"status":"failed","aggregated_output":"1 test failed\n","exit_code":1}}}"#,
    ##"{"timestamp":"2026-10-14T14:00:06.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f1","status":"completed","changes":{"div.sh":{"type":"update","unified_diff":"@@ -1,2 +1,3 @@\n #!/bin/sh\n-echo old\n+echo new\n+exit 0\n","move_path":null},"test_div.sh":{"type":"add","content":"#!/bin/sh\necho ok\n"},"old.sh":{"type":"delete","content":"x"}}}}}"##,
    #"{"timestamp":"2026-10-14T14:00:07.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"x1","server":"tezgah","tool":"board_move","arguments":{"id":"ab12","column":"done"},"status":"completed","result":{"content":[{"type":"text","text":"Moved."}],"isError":false}}}}"#,
    #"{"timestamp":"2026-10-14T14:00:08.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r1","summary_text":[],"raw_content":[]}}}"#,
    "not json",
    #"{"timestamp":"2026-10-14T14:00:14.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Bitti"}}"#,
    #"{"timestamp":"2026-10-14T14:01:00.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2"}}"#,
]

@Suite struct CodexTranscriptParsingTests {
    private func parse(_ lines: [String]) -> CodexTranscriptParser {
        var parser = CodexTranscriptParser()
        for line in lines { _ = parser.consume(Data(line.utf8)) }
        return parser
    }

    @Test func readsTheConversation() throws {
        let parser = parse(rollout + rest)
        #expect(parser.title == "Bölme betiği ekle")
        let kinds = parser.entries.map(\.kind)
        #expect(kinds.count == 9)
        #expect(kinds[0] == .prompt(text: "Bölme betiği ekle\nsıfıra bölmede hata versin", images: 0))
        #expect(kinds[1] == .reply("Önce betiklere bakacağım."))

        guard case .tool(let command) = kinds[2] else { Issue.record("no command"); return }
        #expect(command.name == "Bash")
        #expect(command.input["command"]?.string == "bash test_div.sh")
        #expect(command.result == ClaudeToolCall.Result(text: "1 test failed\n", isError: true, details: nil))

        // Edits, by file name: the changed script, the deletion, the new test.
        #expect(kinds[4] == .notice("Sildi: old.sh"))
        guard case .tool(let edited) = kinds[3], case .tool(let added) = kinds[5] else { Issue.record("no edits"); return }
        #expect(added.name == "Write")
        #expect(added.input["file_path"]?.string == "/repo/test_div.sh")
        #expect(added.result?.details?["type"]?.string == "create")
        #expect(edited.name == "Edit")
        #expect(edited.input["file_path"]?.string == "/repo/div.sh")
        let hunk = try #require(edited.result?.details?["structuredPatch"]?.array?.first)
        #expect(hunk["oldStart"]?.number == 1)
        #expect(hunk["lines"]?.array?.compactMap(\.string) == [" #!/bin/sh", "-echo old", "+echo new", "+exit 0"])

        guard case .tool(let mcp) = kinds[6] else { Issue.record("no mcp"); return }
        #expect(mcp.name == "mcp__tezgah__board_move")
        #expect(mcp.input["column"]?.string == "done")
        #expect(mcp.result?.text == "Moved.")

        #expect(kinds[7] == .turnEnd(seconds: 12))
        #expect(kinds[8] == .notice("Durduruldu"))
    }

    @Test func aRunningCommandIsShownThenCompletedInPlace() {
        var parser = parse(rollout)
        guard case .tool(let running) = parser.entries.last?.kind else { Issue.record("no command"); return }
        #expect(running.result == nil) // still running
        let count = parser.entries.count
        _ = parser.consume(Data(rest[0].utf8))
        #expect(parser.entries.count == count)
        guard case .tool(let done) = parser.entries.last?.kind else { Issue.record("no command"); return }
        #expect(done.result?.isError == true)
    }

    @Test func commandsLoseTheShellAroundThem() {
        #expect(CodexTranscriptParser.command(["/bin/zsh", "-lc", "git status"]) == "git status")
        #expect(CodexTranscriptParser.command(["git", "log"]) == "git log")
        #expect(CodexTranscriptParser.command("ls") == "ls")
    }
}

@MainActor
@Suite struct CodexTranscriptFollowingTests {
    @Test func followsTheFileAsCodexWritesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-codex-\(UUID().uuidString)/sessions/2026/10/14")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let file = folder.appendingPathComponent("rollout-2026-10-14T14-00-00-019a.jsonl")
        try Data((rollout.joined(separator: "\n") + "\n").utf8).write(to: file)

        let home = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(CodexTranscript.rolloutFile(forSession: "019a", in: home)?.lastPathComponent == file.lastPathComponent)
        #expect(CodexTranscript.rolloutFile(forSession: "019b", in: home) == nil)

        let transcript = CodexTranscript(url: file)
        transcript.start()
        defer { transcript.stop() }
        for _ in 0..<100 where transcript.entries.count < 3 {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(transcript.entries.count == 3)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((rest.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        transcript.refresh()
        for _ in 0..<100 where transcript.entries.count < 9 {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(transcript.entries.count == 9)
    }

    @Test func aDraftSentWhileCodexStartsGoesOutOnceItIsUp() async throws {
        let codex = CodexActivity()
        let quiet = ["DISABLE_AUTO_UPDATE": "true", "DISABLE_UPDATE_PROMPT": "true"]
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory, title: "Codex", command: "cat; true",
                                      environment: quiet, agent: codex)
        defer { session.terminate() }
        codex.composer.text = "selam codex"
        session.sendCodexDraft()
        #expect(codex.composer.isWaitingForAgent)
        #expect(codex.composer.text == "selam codex") // kept until Codex takes input

        codex.uiAppeared()
        #expect(!codex.composer.isWaitingForAgent)
        #expect(codex.composer.text.isEmpty)
        for _ in 0..<100 where !session.view.bufferLines().joined().contains("selam codex") {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(session.view.bufferLines().joined().contains("selam codex"))

        // An attached file goes in by its path, before the text.
        codex.composer.text = "buna bak"
        codex.composer.addAttachment(URL(fileURLWithPath: "/tmp/ekran görüntüsü.png"))
        session.sendCodexDraft()
        #expect(codex.composer.attachments.isEmpty)
        for _ in 0..<100 where !session.view.bufferLines().joined().contains("buna bak") {
            try await Task.sleep(for: .milliseconds(30))
        }
        let screen = session.view.bufferLines().joined()
        #expect(screen.contains("ekran") && screen.contains("buna bak"))
    }
}
