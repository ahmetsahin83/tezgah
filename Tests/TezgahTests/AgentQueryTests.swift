import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct AgentQueryTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    @Test func agentsQueryOnTheirOwnSessionAndSignTheHistory() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        FileManager.default.createFile(atPath: project.url.appendingPathComponent("app.db").path, contents: nil)
        var config = DatabaseConfig(name: "app", kind: .sqlite, path: "app.db")
        config.autoCommit = false // the user works in manual commit mode
        project.databases = [config]
        let selected = project.selectedTabID

        let agents = try #require(store.databaseSession(nil, project: project))
        #expect(agents.isForAgents && agents.autoCommit) // never waits in a transaction
        #expect(store.databaseSession("app", project: project) === agents)
        #expect(project.tabs.isEmpty && project.selectedTabID == selected) // nobody gets pulled to a tab

        let sql = "CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1), (2); SELECT * FROM t"
        let (results, error) = await agents.runAndWait(sql, agent: "Geliştirici · Claude · Fable — İş")
        #expect(error == nil)
        let statements = SQLText.statementRanges(in: sql).map { (sql as NSString).substring(with: $0) }
        #expect(WorkspaceStore.summary(of: results ?? [], statements: statements) == "tamam, 2 satır değişti, 2 satır")
        #expect(agents.history.entries.first?.agent == "Geliştirici · Claude · Fable — İş")

        // The tab the user opens shares the history: the agent's queries are there.
        let tab = store.openDatabase(config, in: project)
        #expect(tab !== agents && tab.history === agents.history)
        #expect(tab.history.entries.count == 3)
    }

    @Test func oldHistoryHasNoAgent() throws {
        let old = #"[{"id":"6F1E2B9C-3D4A-4B5C-8D7E-1F2A3B4C5D6E","sql":"select 1","date":"2026-10-14T21:00:00Z","duration":0.1}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([QueryHistoryEntry].self, from: Data(old.utf8))
        #expect(entries.first?.agent == nil)
    }

    @Test func anOrchestraAgentsQueryGoesIntoTheCardsStory() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("Abone sayısı"))
        var team = OrchestraTeam()
        team.developer = OrchestraTeam.Member(provider: .claude, model: "fable")
        project.board.beginRun(on: card.id, team: team, branch: "tezgah/abone")
        let run = OrchestraRun(cardID: card.id, team: team, branch: "tezgah/abone", worktree: base, directory: base, base: "abc")
        let developer = UUID()
        run.developerTab = developer
        store.orchestraRuns[card.id] = run

        #expect(store.agentName(developer) == "Geliştirici · Claude · Fable — Abone sayısı")
        store.logQuery("SELECT count(*)\nFROM subscriptions", from: developer, outcome: "sorgu çalıştırdı · 1 satır", in: project)
        let event = try #require(project.board.cards.first?.run?.events.last)
        #expect(event.kind == .query)
        #expect(event.text == "Geliştirici · Claude · Fable sorgu çalıştırdı · 1 satır")
        #expect(event.detail == "SELECT count(*)\nFROM subscriptions")
        store.logQuery("SELECT 1", from: UUID(), outcome: "x", in: project) // not one of the run's agents
        #expect(project.board.cards.first?.run?.events.count == 1)
    }

    @Test func rolesAreToldToCheckTheirCriteria() {
        let card = BoardCard(title: "İş")
        #expect(WorkspaceStore.plannerPrompt(card: card).contains("Her birini kodda doğrula"))
        let plan = BoardCard.RunPlan(summary: "Özet", doneCriteria: ["Ölçüt"])
        #expect(WorkspaceStore.developerPrompt(for: card, branch: "b", plan: plan).contains("“Ölçüt N uygulanamaz: neden”"))
        var planned = card
        planned.run = BoardCard.RunRecord(team: OrchestraTeam(), branch: "b", plan: plan)
        let run = OrchestraRun(cardID: card.id, team: OrchestraTeam(), branch: "b", worktree: URL(fileURLWithPath: "/w"), directory: URL(fileURLWithPath: "/w"), base: "a")
        #expect(WorkspaceStore.reviewPrompt(card: planned, run: run, member: OrchestraTeam.Member(provider: .codex), number: 1).contains("gerekçe doğruysa engel sayma"))
    }
}
