import Foundation
import Testing
@testable import Tezgah

/// The /model menu as Claude Code 2.1.327 printed it.
private let modelMenu = """
  Select model
  Your pick is the default for new sessions. For other models, use --model.

  ❯ 1.  Default (recommended) ✔  Opus 5.5 · Best for everyday, complex tasks
    2.  Opus 5.5                 For complex work and everyday tasks
    3.  Fable 5.2                For your toughest challenges
    4.  Sonnet 5.5               Most efficient for simpler tasks
    5.  Haiku 5.5                Fastest for quick answers
    ▸   More models

  ◐ Medium effort (default)
  ←/→ to adjust · s to use this session only · Enter to save · Esc to cancel
"""

/// The same menu with "More models" opened.
private let expandedMenu = """
  Select model
  Your pick is the default for new sessions. For other models, use --model.

    1.  Default (recommended) ✔  Opus 5.5 · Best for everyday, complex tasks
    2.  Opus 5.5                 For complex work and everyday tasks
    3.  Fable 5.2                For your toughest challenges
    4.  Sonnet 5.5               Most efficient for simpler tasks
    5.  Haiku 5.5                Fastest for quick answers
  ❯ ▾   More models
    6.  Fable 5.1                Most capable for your hardest and longest-running tasks
    7.  Haiku 4.5                Fastest for quick answers
    8.  Sonnet 5                 Efficient for routine tasks
    9.  Opus 5                   Best for everyday, complex tasks
    10. Fable 5                  Most capable for your hardest and longest-running tasks

  Enter to collapse · Esc to cancel
"""

private func lines(_ screen: String) -> [String] {
    screen.components(separatedBy: "\n")
}

@MainActor
@Suite struct ClaudeModelMenuTests {
    @Test func readsTheOptionsWithTheirMarks() {
        let options = TerminalSession.modelMenuOptions(in: lines(modelMenu))
        #expect(options.map(\.number) == [1, 2, 3, 4, 5])
        #expect(options.map(\.name) == ["Default (recommended)", "Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"])
        #expect(options.filter(\.isCurrent).map(\.number) == [1])
        #expect(options.filter(\.isHighlighted).map(\.number) == [1])
    }

    @Test func offersTheNamedModelsOnly() {
        let names = TerminalSession.modelNames(from: TerminalSession.modelMenuOptions(in: lines(modelMenu)))
        #expect(names == ["Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"])
    }

    @Test func readsTheMoreModelsList() {
        let options = TerminalSession.modelMenuOptions(in: lines(expandedMenu))
        #expect(options.map(\.number) == Array(1...10))
        #expect(options[9].name == "Fable 5") // two-digit numbers, one space less before the name
        #expect(options.allSatisfy { !$0.isHighlighted }) // ❯ is on "More models", which has no number
    }

    /// An exact name wins over one it is the start of; a family name picks its first model.
    @Test func picksTheOptionByName() {
        let options = TerminalSession.modelMenuOptions(in: lines(expandedMenu))
        #expect(TerminalSession.modelOption(named: "Fable 5", in: options)?.number == 10)
        #expect(TerminalSession.modelOption(named: "fable 5.2", in: options)?.number == 3)
        #expect(TerminalSession.modelOption(named: "Sonnet", in: options)?.number == 4)
        #expect(TerminalSession.modelOption(named: "Mythos", in: options) == nil)
    }

    /// Only the last menu on screen counts, not one still in the scrollback.
    @Test func readsTheLatestMenu() {
        let older = ["  ❯ 1.  Default (recommended) ✔  Fable 5.1 · Old", "    2.  Fable 5.1   Old", "  Esc to cancel", "❯ hi", "⏺ Hello!"]
        let names = TerminalSession.modelNames(from: TerminalSession.modelMenuOptions(in: older + lines(modelMenu)))
        #expect(names == ["Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"])
    }

    @Test func findsNothingWithoutAMenu() {
        let screen = ["⏺ Here are the steps:", "", "  1. Install it", "❯ ", "⏵⏵ auto mode on (shift+tab to cycle)"]
        #expect(!TerminalSession.isModelMenu(screen))
        #expect(TerminalSession.isModelMenu(lines(modelMenu)))
    }

    /// Against a stand-in for Claude Code: /model opens the menu, Esc closes it, and the models
    /// it offered are kept on the session.
    @Test func readsTheModelsFromTheRunningSession() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let menu = base.appendingPathComponent("menu.txt")
        try Data(modelMenu.utf8).write(to: menu)
        let script = base.appendingPathComponent("claude.sh")
        try Data("""
        stty -echo
        echo ready
        IFS= read -r line
        [ "$line" = /model ] && cat '\(menu.path)'
        stty -icanon min 1
        dd bs=1 count=1 2>/dev/null >/dev/null
        printf '\\033[2J\\033[Hclosed\\n'
        cat >/dev/null
        """.utf8).write(to: script)

        let session = TerminalSession(directory: base, title: "Claude", command: "sh \(AgentMonitor.quote(script.path))",
                                      environment: [:], agent: ClaudeActivity())
        defer { session.terminate() }
        for _ in 0..<100 where !session.view.bufferLines().contains("ready") {
            try await Task.sleep(for: .milliseconds(50))
        }

        let names = await session.readClaudeModels()
        #expect(names == ["Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"])
        #expect(session.claude?.availableModels == names)
        for _ in 0..<100 where !session.view.bufferLines().contains("closed") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.view.bufferLines().contains("closed")) // Esc reached it
        #expect(!TerminalSession.isModelMenu(session.view.bufferLines()))
    }
}
