import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct ProjectBoardTests {
    @Test func addMoveAndFinish() {
        let board = ProjectBoard()
        var saves = 0
        board.onChange = { saves += 1 }

        let a = board.add("Write tests")!
        let b = board.add("Fix login")!
        #expect(board.add("   ") == nil)
        #expect(board.cards(in: .todo).map(\.title) == ["Fix login", "Write tests"]) // newest on top

        board.move(a.id, to: .doing)
        #expect(board.cards(in: .doing).map(\.id) == [a.id])

        board.toggleDone(b.id)
        let done = board.cards(in: .done)
        #expect(done.map(\.id) == [b.id])
        #expect(done[0].completedAt != nil)

        board.toggleDone(b.id) // un-check: back to do, no completion date
        #expect(board.cards(in: .todo).first?.id == b.id)
        #expect(board.cards(in: .todo).first?.completedAt == nil)

        // Reorder within a column by dropping before another card.
        let c = board.add("Ship")!
        board.move(b.id, to: .todo, before: c.id)
        #expect(board.cards(in: .todo).map(\.id) == [b.id, c.id])
        #expect(saves == 7)
    }

    @Test func boardIsSavedWithTheWorkspace() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let snapshot = base.appendingPathComponent("workspace.json")

        let store = WorkspaceStore(snapshotURL: snapshot, agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: true)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        project.board.add("Remember me")
        store.showBoard()
        store.persist()
        project.stopWatching()

        let restarted = WorkspaceStore(snapshotURL: snapshot, agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: true)
        let reopened = try #require(restarted.activeProject)
        defer { reopened.stopWatching() }
        #expect(reopened.board.cards.map(\.title) == ["Remember me"])
        for _ in 0..<100 where reopened.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(reopened.tabs.contains { $0.id == reopened.board.id }) // the tab comes back too
    }

    @Test func savingWhileTabsAreRestoredKeepsThemAll() async throws {
        let root = try await makeRepository(["a.txt": "a\n", "b.txt": "b\n"])
        let base = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let snapshot = base.appendingPathComponent("workspace.json")

        let store = WorkspaceStore(snapshotURL: snapshot, agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: true)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        store.openFile(root.appendingPathComponent("a.txt"))
        store.openFile(root.appendingPathComponent("b.txt"))
        store.showBoard()
        store.persist()
        project.stopWatching()

        // A save before the tabs are back (a board change, the app going to the background)
        // must not write the half-restored list.
        let restarted = WorkspaceStore(snapshotURL: snapshot, agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: true)
        restarted.persist()
        let reopened = try #require(restarted.activeProject)
        reopened.stopWatching()

        let again = WorkspaceStore(snapshotURL: snapshot, agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: true)
        let project3 = try #require(again.activeProject)
        defer { project3.stopWatching() }
        for _ in 0..<100 where project3.tabs.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(project3.tabs.count == 3)
    }
}
