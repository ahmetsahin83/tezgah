import Foundation
import Testing
@testable import Tezgah

/// Screens captured from Codex 0.162 asking to commit in a worktree.
private let commitScreen = """
• Running git add selam.txt && git commit -m 'Selamlama dosyası ekle'


  Would you like to run the following command?

  Environment: local

  Reason: Worktree’nin ortak .git dizinine sandbox yazmayı engelledi. İstediğiniz commit’i oluşturmak için bu git komutlarına
  izin verir misiniz?

  $ git add selam.txt && git commit -m 'Selamlama dosyası ekle'


› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `git add selam.txt` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
"""

private let editScreen = """
  Would you like to make the following edits?

  notes/hello.txt (+1 -0)

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for these files (a)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
"""

@Suite struct CodexApprovalParsingTests {
    private func parse(_ screen: String) -> CodexApprovalDialog? {
        CodexApprovalDialog.parse(screen.components(separatedBy: "\n"))
    }

    @Test func readsACommandApproval() throws {
        let dialog = try #require(parse(commitScreen))
        #expect(dialog.title == "Would you like to run the following command?")
        #expect(dialog.command == "git add selam.txt && git commit -m 'Selamlama dosyası ekle'")
        #expect(dialog.reason?.hasSuffix("bu git komutlarına izin verir misiniz?") == true) // wrapped line joined
        #expect(dialog.options.map(\.number) == [1, 2, 3])
        #expect(dialog.options.map(\.allows) == [true, true, false])
        #expect(dialog.options[0].label == "Yes, proceed")
        #expect(dialog.alwaysOption?.label == "Yes, and don't ask again for commands that start with `git add selam.txt`")
        #expect(CodexApprovalBar.title(dialog) == "Codex bir komut çalıştırmak istiyor")
    }

    @Test func aCommandWrappedOntoTheNextLineStaysWhole() throws {
        let screen = commitScreen.replacingOccurrences(
            of: "  $ git add selam.txt && git commit -m 'Selamlama dosyası ekle'",
            with: "  $ git add selam.txt && git commit -m 'Selamlama dosyası ekle' && git\n  status --short"
        )
        #expect(try #require(parse(screen)).command == "git add selam.txt && git commit -m 'Selamlama dosyası ekle' && git status --short")
    }

    @Test func readsAnEditApproval() throws {
        let dialog = try #require(parse(editScreen))
        #expect(dialog.command == nil)
        #expect(dialog.alwaysOption?.number == 2)
        #expect(dialog.alwaysOption?.label == "Yes, and don't ask again for these files")
    }

    @Test func aChoiceWrappedOntoTheNextLineStaysWhole() throws {
        let screen = editScreen.replacingOccurrences(
            of: "  2. Yes, and don't ask again for these files (a)",
            with: "  2. Yes, and don't ask again for\n     these files (a)"
        )
        #expect(try #require(parse(screen)).alwaysOption?.label == "Yes, and don't ask again for these files")
    }

    @Test func aNumberedListInAReplyIsNotADialog() {
        #expect(parse("• Plan:\n  1. Read the code\n  2. Fix it\n\n› Ask Codex to do anything") == nil)
        #expect(parse("") == nil)
    }
}

@MainActor
@Suite struct CodexApprovalAnswerTests {
    @Test func notificationsOfferWhatEachAgentCanAnswer() {
        let codex = AgentActivity(provider: .codex)
        codex.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "git commit"]])
        #expect(WorkspaceStore.notificationCategory(for: codex) == .permissionWithAlways)
        codex.handle(["hook_event_name": "PermissionRequest", "tool_name": "mcp__github__create_issue", "tool_input": [:]])
        #expect(WorkspaceStore.notificationCategory(for: codex) == .permission)

        let claude = ClaudeActivity()
        claude.handle(["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": [:]])
        #expect(WorkspaceStore.notificationCategory(for: claude) == nil)
        claude.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        #expect(WorkspaceStore.notificationCategory(for: claude) == .permission)
    }

    /// The answer from a notification picks the dialog's choice by its number, and only while
    /// the dialog it was shown for is still open.
    @Test func answersTheDialogOnScreen() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        let screen = base.appendingPathComponent("screen.txt")
        try Data(commitScreen.utf8).write(to: screen)
        let quiet = ["DISABLE_AUTO_UPDATE": "true", "DISABLE_UPDATE_PROMPT": "true"]
        let session = TerminalSession(directory: root, title: "Codex", command: "cat \(AgentMonitor.quote(screen.path)); cat",
                                      environment: quiet, agent: AgentActivity(provider: .codex))
        defer { session.terminate() }
        project.tabs.append(.terminal(session))
        let activity = try #require(session.agent)
        activity.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "git commit"]])
        for _ in 0..<100 where session.codexApproval == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.codexApproval?.options.count == 3)

        #expect(!store.answerPermission(tab: session.id, request: activity.requestSerial + 1, answer: .allow)) // an older dialog
        #expect(store.answerPermission(tab: session.id, request: activity.requestSerial, answer: .always))
        #expect(activity.state == .working)
        #expect(session.codexApproval == nil) // not asking anymore
        for _ in 0..<100 where !session.view.bufferLines().contains(where: { $0.hasSuffix("2") }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.view.bufferLines().last { !$0.isEmpty }?.hasSuffix("2") == true) // option 2 went to the terminal
    }
}
