import Foundation
import Testing
@testable import Tezgah

/// Screens as Claude Code 2.1.296 printed them.
@MainActor
@Suite struct ClaudeRemoteControlTests {
    private let link = URL(string: "https://claude.ai/code/session_01PSkgHXpraWAqFUcK65GvLy")!

    @Test func readsConnectingThenActiveWithTheLink() {
        let connecting = ["▝▝   ▝▝ /…/ptytest/work · /rc connecting…", "◐ medium · /effort", "❯ "]
        #expect(TerminalSession.remoteControlState(in: connecting) == .connecting)

        let active = connecting + [
            "/rc active",
            "/remote-control is active · Continue here, on your phone, or at",
            "https://claude.ai/code/session_01PSkgHXpraWAqFUcK65GvLy",
        ]
        #expect(TerminalSession.remoteControlState(in: active) == .active(link))
    }

    @Test func theLatestMessageWins() {
        let lines = [
            "/remote-control is active · Continue here, on your phone, or at",
            "https://claude.ai/code/session_01PSkgHXpraWAqFUcK65GvLy",
            "❯ /remote-control",
            "  ⎿  Remote Control disconnected.",
        ]
        #expect(TerminalSession.remoteControlState(in: lines) == .off)
        #expect(TerminalSession.remoteControlState(in: lines + ["/rc connecting…"]) == .connecting)
    }

    @Test func saysNothingWithoutRemoteControl() {
        #expect(TerminalSession.remoteControlState(in: ["❯ ", "⏵⏵ auto mode on (shift+tab to cycle)"]) == nil)
    }
}
