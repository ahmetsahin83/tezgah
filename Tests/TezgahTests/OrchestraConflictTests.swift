import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct OrchestraConflictTests {
    private func git(_ args: [String], in directory: URL) async throws {
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, in: directory)
    }

    private func commit(_ text: String, to file: String, in directory: URL, message: String) async throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(file))
        try await git(["add", "-A"], in: directory)
        try await git(["commit", "-q", "-m", message], in: directory)
    }

    /// A project whose card's branch and own branch both changed a.txt.
    private func makeConflict() async throws -> (WorkspaceStore, Project, URL, Worktrees.Created, String) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        await project.git.refresh()
        let created = try await Worktrees.create(named: "İş", projectURL: root, root: root)
        let start = try await Git.run(["rev-parse", "HEAD"], in: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit("dal\n", to: "a.txt", in: created.url, message: "dalda")
        try await commit("ana\n", to: "a.txt", in: root, message: "anada")
        await project.git.refresh()
        return (store, project, base, created, start)
    }

    @Test func conflictsAreFoundWithoutTouchingTheCheckout() async throws {
        let (_, project, base, created, _) = try await makeConflict()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        #expect(await Worktrees.conflicts(merging: created.branch, root: project.url) == ["a.txt"])
        #expect(try await Git.run(["status", "--porcelain"], in: project.url).text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: project.url.appendingPathComponent(".git/MERGE_HEAD").path))

        try await git(["merge", "-q", "-X", "theirs", "--no-edit", project.git.status.branch ?? "HEAD"], in: created.url)
        #expect(await Worktrees.conflicts(merging: created.branch, root: project.url) == [])
    }

    @Test func theDeveloperResolvesAndTheRunMerges() async throws {
        let (store, project, base, created, start) = try await makeConflict()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let target = try #require(project.git.status.branch)
        let card = try #require(project.board.add("İş"))
        var current = card
        current.worktree = BoardCard.Worktree(branch: created.branch, path: created.url.path)
        project.board.update(current)

        let quiet = ["DISABLE_AUTO_UPDATE": "true", "DISABLE_UPDATE_PROMPT": "true"]
        let developer = TerminalSession(directory: created.url, title: "Codex", command: "cat; true", environment: quiet, agent: AgentActivity(provider: .codex))
        defer { developer.terminate() }
        project.tabs.append(.terminal(developer))
        var team = OrchestraTeam()
        team.reviewers = [] // an approval goes straight to the merge
        let run = OrchestraRun(cardID: card.id, team: team, branch: created.branch, worktree: created.url, directory: created.url, base: start)
        run.developerTab = developer.id
        store.orchestraRuns[card.id] = run

        await store.finishRound(of: run, with: OrchestraRun.Verdict(approved: true, notes: ""), in: project)
        #expect(run.phase == .developing)
        #expect(run.conflictAttempts == 1)
        #expect(run.conflictTarget == target)
        #expect(try String(contentsOf: project.url.appendingPathComponent("a.txt"), encoding: .utf8) == "ana\n") // untouched
        for _ in 0..<100 where !developer.view.bufferLines().joined().contains("git merge \(target)") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(developer.view.bufferLines().joined().contains("git merge \(target)")) // the developer was told

        // It merges the project's branch in, keeps both sides, commits.
        _ = try? await Git.run(["merge", target], in: created.url, allowedExitCodes: [0, 1])
        try await commit("ana\ndal\n", to: "a.txt", in: created.url, message: "çakışmayı çöz")
        let activity = try #require(developer.agent)
        activity.handle(["hook_event_name": "UserPromptSubmit"])
        activity.handle(["hook_event_name": "Stop", "last_assistant_message": "Çözdüm"])
        store.orchestraNoticed(activity, in: developer, project: project)
        for _ in 0..<200 where project.board.cards.first(where: { $0.id == card.id })?.column != .done {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.orchestraRuns[card.id] == nil)
        #expect(try String(contentsOf: project.url.appendingPathComponent("a.txt"), encoding: .utf8) == "ana\ndal\n")
        #expect(project.board.cards.first { $0.id == card.id }?.column == .done)
        #expect(!FileManager.default.fileExists(atPath: created.url.path))
    }

    @Test func itStopsAfterTwoAttempts() async throws {
        let (store, project, base, created, start) = try await makeConflict()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        let run = OrchestraRun(cardID: card.id, team: OrchestraTeam(), branch: created.branch, worktree: created.url, directory: created.url, base: start)
        run.conflictAttempts = WorkspaceStore.maxConflictAttempts
        store.orchestraRuns[card.id] = run
        await store.finishRound(of: run, with: OrchestraRun.Verdict(approved: true, notes: ""), in: project)
        #expect(run.phase == .needsUser("Birleştirme yine çakıştı (a.txt); dal ve worktree duruyor"))
    }

    @Test func aLeadIsToldWhatConflictsInsteadOfAFailedMerge() async throws {
        let (store, project, base, created, start) = try await makeConflict()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let lead = TerminalSession(directory: project.url, title: "Claude", command: "cat", agent: ClaudeActivity())
        let worker = TerminalSession(directory: created.url, title: "Codex", command: "cat", agent: AgentActivity(provider: .codex))
        defer { lead.terminate(); worker.terminate() }
        project.tabs += [.terminal(lead), .terminal(worker)]
        store.agentWorkers[worker.id] = AgentWorker(lead: lead.id, name: "iş", provider: .codex, worktree: created.url, branch: created.branch, base: start, sentAt: .now)

        let result = await store.mergeWorker(of: lead.id, ["id": String(worker.id.uuidString.prefix(8))])
        #expect(result.isError)
        guard case .text(let text) = result.content.first else { Issue.record("no text"); return }
        #expect(text.contains("would conflict in: a.txt"))
        #expect(try await Git.run(["status", "--porcelain"], in: project.url).text.isEmpty)
    }

    @Test func promptsTellAboutTheConflict() {
        let prompt = WorkspaceStore.conflictPrompt(target: "main", files: ["README.md", "a.sh"])
        #expect(prompt.contains("`main`"))
        #expect(prompt.contains("şu dosyalarda çakışıyor: README.md, a.sh"))
        #expect(prompt.contains("git merge main"))

        let run = OrchestraRun(cardID: UUID(), team: OrchestraTeam(), branch: "tezgah/x", worktree: URL(fileURLWithPath: "/w"), directory: URL(fileURLWithPath: "/w"), base: "abc")
        run.conflictTarget = "main"
        #expect(WorkspaceStore.reviewPrompt(card: nil, run: run, member: OrchestraTeam.Member(provider: .codex), number: 1).contains("çakışmaları çözdü"))
        #expect(run.summary.hasPrefix("Çakışma çözülüyor"))
    }

    @Test func runsSavedBeforeConflictsWereKnownStillLoad() throws {
        let json = #"{"cardID":"6F1C3A52-1D2B-4F0E-9C3A-2B1D4E5F6A7B","team":{},"branch":"tezgah/x","worktree":"/w","directory":"/w","base":"abc","phase":{"developing":{}},"round":1}"#
        let saved = try JSONDecoder().decode(SavedOrchestraRun.self, from: Data(json.utf8))
        #expect(OrchestraRun(saved: saved).conflictAttempts == 0)
    }
}
