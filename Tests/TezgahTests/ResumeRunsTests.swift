import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct ResumeRunsTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    /// An agent tab whose agent is `cat`, with a session id as its hooks would have reported.
    private func agentTab(_ provider: AgentProvider, session: String, in project: Project) -> TerminalSession {
        let activity: AgentActivity = provider == .claude ? ClaudeActivity() : AgentActivity(provider: provider)
        activity.handle(["hook_event_name": "SessionStart", "session_id": session])
        let tab = TerminalSession(directory: project.url, title: provider.displayName, command: "cat", agent: activity)
        project.tabs.append(.terminal(tab))
        return tab
    }

    @Test func runsAndLeadsAreSavedByTheirAgentsSessions() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        let developer = agentTab(.claude, session: "dev-session", in: project)
        let reviewer = agentTab(.codex, session: "review-session", in: project)
        let lead = agentTab(.claude, session: "lead-session", in: project)
        let worker = agentTab(.codex, session: "worker-session", in: project)
        defer { [developer, reviewer, lead, worker].forEach { $0.terminate() } }

        var team = OrchestraTeam()
        team.reviewers = [OrchestraTeam.Member(provider: .codex), OrchestraTeam.Member(provider: .codex)]
        let run = OrchestraRun(cardID: card.id, team: team, branch: "tezgah/is", worktree: base, directory: base, base: "abc")
        run.developerTab = developer.id
        run.startReview()
        run.addReviewer(team.reviewers[0], in: reviewer.id)
        run.reviewersStarted()
        run.startJudging(in: UUID())
        let workers = [worker.id: AgentWorker(lead: lead.id, name: "w", provider: .codex, branch: "tezgah/w", sentAt: .now)]

        let state = WorkspaceStore.state(of: project, runs: [run], workers: workers)
        #expect(!state.tabs.contains(.codex(sessionID: "review-session", directory: project.url.path))) // reviews start over
        #expect(state.tabs.contains(.claude(sessionID: "dev-session", directory: project.url.path)))
        let saved = try #require(state.orchestraRuns?.first)
        #expect(saved.developerSession == "dev-session")
        #expect(saved.phase == .reviewing) // judging is saved as a review to do again
        #expect(state.agentWorkers == [SavedAgentWorker(leadSession: "lead-session", workerSession: "worker-session", name: "w",
                                                       provider: .codex, branch: "tezgah/w")])

        let decoded = try JSONDecoder().decode(WorkspaceStore.ProjectState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func eachPhaseGoesOnTheRightWay() {
        typealias Store = WorkspaceStore
        #expect(Store.resumeStep(for: .developing, hasNewCommits: false, isClean: true) == .remindDeveloper)
        #expect(Store.resumeStep(for: .developing, hasNewCommits: true, isClean: false) == .remindDeveloper) // half done
        #expect(Store.resumeStep(for: .developing, hasNewCommits: true, isClean: true) == .review)
        #expect(Store.resumeStep(for: .reviewing, hasNewCommits: false, isClean: true) == .review)
        #expect(Store.resumeStep(for: .merging, hasNewCommits: true, isClean: true) == .merge)
        #expect(Store.resumeStep(for: .needsUser("Tur sınırı doldu"), hasNewCommits: true, isClean: true) == .wait)
    }

    @Test func aRunComesBackWhereItWas() {
        let saved = SavedOrchestraRun(
            cardID: UUID(), team: OrchestraTeam(), branch: "tezgah/is", worktree: "/w", directory: "/w/app", base: "abc",
            phase: .needsUser("Birleştirme çakıştı"), round: 2, reviewedHead: "def", lastNotes: "Testi ekle", developerSession: "s"
        )
        let run = OrchestraRun(saved: saved)
        #expect(run.phase == .needsUser("Birleştirme çakıştı"))
        #expect(run.round == 2)
        #expect(run.directory.path == "/w/app")
        #expect(run.saved(developerSession: "s") == saved)
    }

    @Test func restoredAgentsCountAsWaitingForTheirLead() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let lead = agentTab(.claude, session: "lead-session", in: project)
        let worker = agentTab(.codex, session: "worker-session", in: project)
        defer { lead.terminate(); worker.terminate() }

        store.resumeAgentWorkers([
            SavedAgentWorker(leadSession: "lead-session", workerSession: "worker-session", name: "w", provider: .codex),
            SavedAgentWorker(leadSession: "lead-session", workerSession: nil, name: "closed", provider: .codex, branch: "tezgah/c"),
            SavedAgentWorker(leadSession: "gone", workerSession: "worker-session", name: "orphan", provider: .codex),
        ], tabs: ["lead-session": lead.id, "worker-session": worker.id])

        let restored = store.workers(of: lead.id)
        #expect(Set(restored.map(\.worker.name)) == ["w", "closed"]) // without its lead an agent is the user's
        let w = try #require(store.agentWorkers[worker.id])
        #expect(w.wasInterrupted)
        worker.agent?.uiAppeared()
        #expect(store.isDone(w, tab: worker.id)) // its turn is gone; agent_wait doesn't hang on it
    }

    @Test func aResumedSessionIsSavedEvenBeforeItsNextPrompt() {
        let codex = AgentActivity(provider: .codex)
        codex.resumes(session: "019a")
        #expect(codex.sessionID == "019a")
        codex.handle(["hook_event_name": "SessionStart", "session_id": "019b"]) // hooks win
        #expect(codex.sessionID == "019b")
    }
}
