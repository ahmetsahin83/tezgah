import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct OrchestraQueueTests {
    @Test func aMergeResetsTheCountAndTwoStopsInARowEndTheQueue() {
        var queue = OrchestraQueue(cardID: UUID())
        let afterStop = queue.cardFinished(merged: false)
        #expect(afterStop && queue.cardID == nil && queue.stopsInARow == 1)
        let afterMerge = queue.cardFinished(merged: true)
        #expect(afterMerge && queue.stopsInARow == 0)
        let afterOneStop = queue.cardFinished(merged: false)
        let afterTwoStops = queue.cardFinished(merged: false)
        #expect(afterOneStop && !afterTwoStops)
    }

    @Test func theTopToDoCardNobodyStartedIsNext() throws {
        let board = ProjectBoard()
        #expect(OrchestraQueue.nextCard(on: board) == nil)
        let older = try #require(board.add("Önce eklenen"))
        var started = try #require(board.add("Başlatılmış"))
        started.worktree = BoardCard.Worktree(branch: "tezgah/baslatilmis", path: "/w")
        board.update(started)
        board.add("Bitmiş", to: .done)
        #expect(OrchestraQueue.nextCard(on: board)?.id == older.id)
        let newest = try #require(board.add("Yeni")) // new cards go on top
        #expect(OrchestraQueue.nextCard(on: board)?.id == newest.id)
    }

    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    @Test func theQueueStopsOnTheSecondStuckCardInARow() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        project.orchestraQueue = OrchestraQueue(cardID: card.id, stopsInARow: 1)

        store.queueCardFinished(UUID(), merged: false, in: project) // another card's run
        #expect(project.orchestraQueue?.stopsInARow == 1)
        store.queueCardFinished(card.id, merged: false, in: project)
        #expect(project.orchestraQueue == nil)
    }

    @Test func theQueueEndsWhenNoToDoCardIsLeft() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş", to: .done))
        project.orchestraQueue = OrchestraQueue(cardID: card.id)
        store.queueCardFinished(card.id, merged: true, in: project)
        #expect(project.orchestraQueue == nil)
    }

    @Test func stoppingTheQueuesCardByHandStopsTheQueue() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        store.orchestraRuns[card.id] = OrchestraRun(
            cardID: card.id, team: OrchestraTeam(), branch: "tezgah/is", worktree: base, directory: base, base: "abc"
        )
        project.orchestraQueue = OrchestraQueue(cardID: card.id)
        store.stopOrchestra(of: card, in: project)
        #expect(project.orchestraQueue == nil)
        #expect(store.orchestraRuns[card.id] == nil)
    }

    @Test func theQueueIsSavedWithTheProject() async throws {
        let (_, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        project.orchestraQueue = OrchestraQueue(cardID: UUID(), stopsInARow: 1)
        let state = WorkspaceStore.state(of: project)
        #expect(state.orchestraQueue == project.orchestraQueue)
        let decoded = try JSONDecoder().decode(WorkspaceStore.ProjectState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let old = try JSONDecoder().decode(WorkspaceStore.ProjectState.self, from: Data(#"{"tabs":[]}"#.utf8))
        #expect(old.orchestraQueue == nil)
    }
}
