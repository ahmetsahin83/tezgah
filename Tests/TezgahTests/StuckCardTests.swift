import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct StuckCardTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    private func run(for card: BoardCard, base: URL, team: OrchestraTeam = OrchestraTeam()) -> OrchestraRun {
        OrchestraRun(cardID: card.id, team: team, branch: "tezgah/is", worktree: base, directory: base, base: "abc")
    }

    @Test func thePlannerCanSayTheCardIsBlocked() throws {
        let blocked = try #require(WorkspaceStore.plan(from: [
            "blocked": "Hangi ödeme sağlayıcısının kullanılacağı belli değil",
            "questions": ["iyzico mu Stripe mı?", "", "Test anahtarları nerede?"],
        ]))
        #expect(blocked.blocked == "Hangi ödeme sağlayıcısının kullanılacağı belli değil")
        #expect(blocked.questions == ["iyzico mu Stripe mı?", "Test anahtarları nerede?"])
        #expect(blocked.summary.isEmpty)
        #expect(WorkspaceStore.plannerPrompt(card: BoardCard(title: "İş")).contains("`blocked`"))

        // Plans saved before blocked and questions existed still load.
        let old = try JSONDecoder().decode(BoardCard.RunPlan.self, from: Data(#"{"summary":"Özet","approach":"","doneCriteria":["a"],"includedIdeas":[],"separateIdeas":[]}"#.utf8))
        #expect(old.blocked == nil && old.questions.isEmpty && old.doneCriteria == ["a"])
    }

    @Test func aCardWaitingForAnswersDoesNotCountAgainstTheQueue() {
        var queue = OrchestraQueue(cardID: UUID(), stopsInARow: 1)
        let goesOn = queue.cardFinished(merged: false, countsAsStuck: false)
        #expect(goesOn && queue.stopsInARow == 1)
    }

    @Test func stepsHaveTimeLimits() throws {
        let old = try JSONDecoder().decode(OrchestraTeam.self, from: Data(#"{"maxRounds":3}"#.utf8))
        #expect(old.planMinutes == 30 && old.developMinutes == 90 && old.reviewMinutes == 30)
        var team = OrchestraTeam()
        team.reviewMinutes = 0
        #expect(team.minutes(for: .developing) == 90)
        #expect(team.minutes(for: .judging) == nil) // 0 is no limit
        #expect(team.minutes(for: .merging) == nil)
    }

    @Test func aRunPastItsLimitStops() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        project.board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/is")
        let run = run(for: card, base: base)
        store.orchestraRuns[card.id] = run

        store.checkOrchestraTimeouts(now: .now.addingTimeInterval(60 * 60)) // within 90 minutes
        #expect(run.isActive)
        store.checkOrchestraTimeouts(now: .now.addingTimeInterval(91 * 60))
        #expect(!run.isActive)
        #expect(project.board.cards.first?.run?.stopReason == "Süre sınırı doldu: geliştirme 90 dakikayı geçti")
    }

    @Test func answeringTheQuestionsStartsTheCardOverThroughTheQueue() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let busy = try #require(project.board.add("Çalışan"))
        let card = try #require(project.board.add("Ödeme", notes: "Ödeme ekle"))
        project.board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/odeme")
        project.board.setPlan(BoardCard.RunPlan(summary: "", blocked: "Sağlayıcı belli değil", questions: ["iyzico mu?"]), on: card.id)
        project.board.logRun(on: card.id, BoardCard.RunEvent(kind: .blocked, text: "Bilgi gerekiyor: Sağlayıcı belli değil"))
        project.board.logRun(on: card.id, BoardCard.RunEvent(kind: .query, text: "sorgu")) // doesn't hide the stop
        project.board.move(card.id, to: .doing)
        #expect(project.board.cards.first { $0.id == card.id }?.run?.isWaitingForAnswers == true)
        // The queue is busy with another card, so the restarted one waits at the top of "Yapılacak".
        store.orchestraRuns[busy.id] = run(for: busy, base: base)
        project.orchestraQueue = OrchestraQueue(cardID: busy.id)

        let restarted = await store.restartOrchestra(of: card.id, in: project, answer: "iyzico")
        #expect(restarted)
        let now = try #require(project.board.cards.first { $0.id == card.id })
        #expect(now.notes == "Ödeme ekle\n\nPlanlayıcının sorularına cevap:\niyzico")
        #expect(project.board.cards(in: .todo).first?.id == card.id)
        #expect(now.run?.stopReason == nil && now.run?.events.last?.kind == .resumed)
    }
}

@MainActor
@Suite struct ContinueRunTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    /// A developer tab whose agent is `cat`: prompts sent to it wait in its composer.
    private func developer(in project: Project) -> TerminalSession {
        let session = TerminalSession(directory: project.url, title: "Claude", command: "cat", agent: ClaudeActivity())
        project.tabs.append(.terminal(session))
        return session
    }

    /// A run on the project's own repository, at its current commit, with a developer tab.
    private func run(for card: BoardCard, team: OrchestraTeam = OrchestraTeam(), in project: Project, store: WorkspaceStore) async throws -> (OrchestraRun, TerminalSession) {
        let head = try await Git.run(["rev-parse", "HEAD"], in: project.url).text.trimmingCharacters(in: .whitespacesAndNewlines)
        project.board.beginRun(on: card.id, team: team, branch: "tezgah/is")
        let run = OrchestraRun(cardID: card.id, team: team, branch: "tezgah/is", worktree: project.url, directory: project.url, base: head)
        let tab = developer(in: project)
        run.developerTab = tab.id
        store.orchestraRuns[card.id] = run
        return (run, tab)
    }

    @Test func goingOnAfterTheRoundLimitHasNoLimitAnyMore() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("Abone filtresi"))
        var team = OrchestraTeam()
        team.maxRounds = 3
        let (run, tab) = try await run(for: card, team: team, in: project, store: store)
        defer { tab.terminate() }
        run.nextRound(notes: "a")
        run.nextRound(notes: "b") // round 3 of 3

        await store.finishRound(of: run, with: OrchestraRun.Verdict(approved: false, notes: "Filtre testini ekle"), in: project)
        #expect(!run.isActive && run.continuation == .moreRounds)
        #expect(store.continueTitle(for: card.id) == "Devam Et")

        #expect(await store.continueOrchestra(of: card.id, in: project))
        #expect(run.isActive && run.round == 4 && run.maxRounds == nil)
        #expect(tab.claude?.composer.text.contains("(tur 4):\n\nFiltre testini ekle") == true)
        let record = try #require(project.board.cards.first?.run)
        #expect(record.stopReason == nil)
        #expect(record.events.suffix(2).map(\.text) == ["Devam ettirildi; bu kartta tur sınırı yok", "Tur 4: istenen değişiklikler geliştiriciye gitti"])
        #expect(await !store.continueOrchestra(of: card.id, in: project)) // it runs again

        // Asked for changes again: no limit stops it now.
        await store.finishRound(of: run, with: OrchestraRun.Verdict(approved: false, notes: "Bir şey daha"), in: project)
        #expect(run.isActive && run.round == 5)
    }

    @Test func anyStopGoesOnFromWhereItWas() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        let (run, tab) = try await run(for: card, in: project, store: store)
        defer { tab.terminate() }
        run.nextRound(notes: "Dockerfile'daki TZ satırını kaldır") // round 2: what the last review asked for
        run.set(.needsUser("Geliştirici yeni commit eklemedi"))

        // The developer ending another turn without commits leaves the stop as it was.
        let activity = try #require(tab.agent)
        activity.handle(["hook_event_name": "UserPromptSubmit"])
        activity.handle(["hook_event_name": "Stop", "last_assistant_message": "Bitti"])
        store.orchestraNoticed(activity, in: tab, project: project)
        try await Task.sleep(for: .milliseconds(400))
        #expect(run.phase == .needsUser("Geliştirici yeni commit eklemedi"))

        #expect(store.continueTitle(for: card.id) == "Devam Et")
        #expect(await store.continueOrchestra(of: card.id, in: project))
        #expect(run.phase == .developing && run.round == 2)
        // The developer was ready, so it went out at once (it waits in the composer while one starts).
        #expect(tab.claude?.composer.history.last?.contains("(tur 2):\n\nDockerfile'daki TZ satırını kaldır") == true)
    }

    @Test func aRunPastItsTimeLimitGoesOnWithTheClockReset() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        let (run, tab) = try await run(for: card, in: project, store: store)
        defer { tab.terminate() }

        store.checkOrchestraTimeouts(now: .now.addingTimeInterval(91 * 60))
        #expect(run.continuation == .moreTime(.develop))
        #expect(await store.continueOrchestra(of: card.id, in: project))
        #expect(run.isActive && run.phase == .developing)
        #expect(tab.claude?.composer.text == WorkspaceStore.continuePrompt)
        store.checkOrchestraTimeouts(now: .now.addingTimeInterval(60 * 60)) // the clock started over
        #expect(run.isActive)
    }

    @Test func aCardWaitingForAnswersIsAnsweredNotContinued() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        let (run, tab) = try await run(for: card, in: project, store: store)
        defer { tab.terminate() }
        project.board.setPlan(BoardCard.RunPlan(summary: "", blocked: "Belli değil", questions: ["Hangisi?"]), on: card.id)
        project.board.logRun(on: card.id, BoardCard.RunEvent(kind: .blocked, text: "Bilgi gerekiyor: Belli değil"))
        run.set(.needsUser("Bilgi gerekiyor: Belli değil"))
        #expect(store.continueTitle(for: card.id) == nil)
    }

    @Test func noLimitAndWhatGoesOnSurviveARestart() throws {
        var team = OrchestraTeam()
        team.maxRounds = 0
        let unlimited = OrchestraRun(cardID: UUID(), team: team, branch: "b", worktree: URL(fileURLWithPath: "/w"), directory: URL(fileURLWithPath: "/w"), base: "a")
        #expect(unlimited.maxRounds == nil && unlimited.summary == "Geliştiriliyor · tur 1")
        #expect(WorkspaceStore.feedbackPrompt("Testi ekle", round: 6, of: nil).hasPrefix("Gözden geçirme sonucu değişiklik istendi (tur 6):"))

        let run = OrchestraRun(cardID: UUID(), team: OrchestraTeam(), branch: "b", worktree: URL(fileURLWithPath: "/w"), directory: URL(fileURLWithPath: "/w"), base: "a")
        run.ignoresRoundLimit = true
        run.continuation = .moreTime(.review)
        let saved = try JSONDecoder().decode(SavedOrchestraRun.self, from: JSONEncoder().encode(run.saved(developerSession: nil)))
        let back = OrchestraRun(saved: saved)
        #expect(back.maxRounds == nil && back.continuation == .moreTime(.review))

        // A run that stopped on its round limit before continuations were saved.
        var old = run.saved(developerSession: nil)
        old.continuation = nil
        old.phase = .needsUser("Tur sınırı doldu (5); hâlâ değişiklik isteniyor")
        #expect(OrchestraRun(saved: old).continuation == .moreRounds)
    }
}

@MainActor
@Suite struct ReviewLeftoverTests {
    @Test func whatAReviewLeavesInTheWorktreeGoes() async throws {
        let root = try await makeRepository(["a.txt": "a\n", ".gitignore": "build/\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        project.board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/is")
        let reviewed = try await Git.run(["rev-parse", "HEAD"], in: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = OrchestraRun(cardID: card.id, team: OrchestraTeam(), branch: "tezgah/is", worktree: root, directory: root, base: reviewed)
        run.reviewedHead = reviewed
        store.orchestraRuns[card.id] = run

        // Nothing left behind: nothing happens.
        await store.undoReviewChanges(of: run, in: project)
        #expect(project.board.cards.first?.run?.events.isEmpty == true)

        // A reviewer committed, edited, added a file and built.
        try Data("reviewer\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qam", "review"], in: root)
        try Data("again\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("x\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: root.appendingPathComponent("build/out"))

        await store.undoReviewChanges(of: run, in: project)
        #expect(try await Git.run(["rev-parse", "HEAD"], in: root).text.trimmingCharacters(in: .whitespacesAndNewlines) == reviewed)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("build/out").path)) // ignored build output stays
        let event = try #require(project.board.cards.first?.run?.events.last)
        #expect(event.text == "Gözden geçirenlerin worktree'de bıraktığı değişiklikler geri alındı")
        #expect(event.detail?.contains("notes.txt") == true && event.detail?.hasPrefix("commit ") == true)
    }
}
