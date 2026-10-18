import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct ClaudeWorkspaceTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(
            snapshotURL: base.appendingPathComponent("workspace.json"),
            agentsDirectory: base.appendingPathComponent("agents"),
            restoresTabs: false
        )
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    /// A Claude tab whose "Claude" is `cat`, so keys sent to it go nowhere harmful.
    private func claudeTab(in project: Project) -> TerminalSession {
        let session = TerminalSession(directory: project.url, title: "Claude", command: "cat", agent: ClaudeActivity())
        project.tabs.append(.terminal(session))
        project.selectedTabID = session.id
        return session
    }

    @Test func notificationAnswerOnlyReachesTheDialogItWasShownFor() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let session = claudeTab(in: project)
        defer { session.terminate() }
        let activity = try #require(session.claude)

        activity.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        let shown = activity.requestSerial
        // Another dialog replaced it before the user clicked.
        activity.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])

        #expect(!store.answerPermission(tab: session.id, request: shown, answer: .allow))
        #expect(activity.state == .needsPermission)
        #expect(store.answerPermission(tab: session.id, request: activity.requestSerial, answer: .deny))
        #expect(activity.state == .working)
    }

    @Test func commandsRunBesideTheConversationInOneTerminal() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let claude = claudeTab(in: project)
        defer { claude.terminate() }

        store.runInTerminal("true", directory: project.url)
        let runner = try #require(project.terminals.first { $0.runsClaudeCommands })
        defer { runner.terminate() }
        #expect(project.selectedTabID == claude.id) // the conversation stays in front
        #expect(project.splitTabID == runner.id)

        // Back at the prompt: the same terminal takes the next command.
        for _ in 0..<100 where runner.foregroundProcessName != nil { try await Task.sleep(for: .milliseconds(30)) }
        store.runInTerminal("true", directory: project.url)
        #expect(project.terminals.filter(\.runsClaudeCommands).count == 1)
    }

    @Test func boardCardGoesToTheClaudeComposer() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let session = claudeTab(in: project)
        defer { session.terminate() }
        let card = try #require(project.board.add("Fix the login bug", notes: "Keyboard covers the field"))
        store.showBoard()

        store.giveToClaude(card, in: project)
        #expect(session.claude?.composer.text == "Fix the login bug\n\nKeyboard covers the field")
        #expect(project.selectedTabID == session.id)
        #expect(project.board.cards(in: .doing).map(\.id) == [card.id])
    }
}
