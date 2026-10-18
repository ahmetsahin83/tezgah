import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct RunRecordTests {
    @Test func aRunsStepsStayOnTheCardAndEndWithAMergeOrAStop() throws {
        let board = ProjectBoard()
        let card = try #require(board.add("Giriş ekranı"))
        board.logRun(on: card.id, BoardCard.RunEvent(kind: .note, text: "kayıt yokken yazılmaz"))
        #expect(board.cards[0].run == nil)

        board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/giris")
        board.logRun(on: card.id, BoardCard.RunEvent(kind: .started, text: "Geliştirici başladı"))
        board.logRun(on: card.id, BoardCard.RunEvent(kind: .commits, text: "2 commit"), commits: 2)
        board.logRun(on: card.id, BoardCard.RunEvent(kind: .stopped, text: "Tur sınırı doldu"))
        var record = try #require(board.cards[0].run)
        #expect(record.commits == 2)
        #expect(record.endedAt != nil)
        #expect(record.stopReason == "Tur sınırı doldu")
        #expect(!record.isMerged)

        // The user answered the developer, who went on and the work merged.
        board.logRun(on: card.id, BoardCard.RunEvent(kind: .resumed, text: "sürdü"))
        #expect(board.cards[0].run?.endedAt == nil)
        #expect(board.cards[0].run?.stopReason == nil)
        board.logRun(on: card.id, BoardCard.RunEvent(kind: .merged, text: "Birleştirildi"))
        record = try #require(board.cards[0].run)
        #expect(record.isMerged && record.events.count == 5)

        // Run again: what happened before stays.
        board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/giris-2")
        #expect(board.cards[0].run?.events.count == 5)
        #expect(board.cards[0].run?.endedAt == nil)
        #expect(board.cards[0].run?.branch == "tezgah/giris-2")
    }

    @Test func oldCardsAndUnknownStepsStillLoad() throws {
        let old = try JSONDecoder().decode(BoardCard.self, from: Data(#"{"id":"6F1E2B9C-3D4A-4B5C-8D7E-1F2A3B4C5D6E","title":"Eski","notes":"","column":"todo","createdAt":0}"#.utf8))
        #expect(old.run == nil)

        var card = BoardCard(title: "Yeni")
        card.run = BoardCard.RunRecord(team: OrchestraTeam(), branch: "tezgah/yeni", events: [BoardCard.RunEvent(kind: .approved, text: "Onayladı", detail: "iyi")])
        let data = try JSONEncoder().encode(card)
        #expect(try JSONDecoder().decode(BoardCard.self, from: data) == card)

        // A step a newer Tezgah wrote.
        let newer = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""approved""#, with: #""teleported""#)
        let decoded = try JSONDecoder().decode(BoardCard.self, from: Data(newer.utf8))
        #expect(decoded.run?.events.first?.kind == .note)
    }

    @Test func stagesFollowTheTeamAndWhereTheRunGotTo() {
        var team = OrchestraTeam()
        team.plans = false
        team.reviewers = []
        #expect(RunStage.stages(for: team) == [.develop, .merge])
        team.reviewers = [OrchestraTeam.Member(provider: .codex)]
        #expect(RunStage.stages(for: team) == [.develop, .review, .merge])
        team.reviewers.append(OrchestraTeam.Member(provider: .claude))
        #expect(RunStage.stages(for: team) == [.develop, .review, .judge, .merge])

        #expect(RunStage.current(.judging) == .judge)
        #expect(RunStage.current(.needsUser("dur")) == nil)

        let events = [BoardCard.RunEvent(kind: .started, text: ""), BoardCard.RunEvent(kind: .review, text: ""),
                      BoardCard.RunEvent(kind: .stopped, text: "Gözden geçiren karar bildirmedi")]
        #expect(RunStage.reached(events) == .review)
        #expect(RunStage.reached([]) == .develop)
    }

    @Test func durationsReadLikeAPerson() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(OrchestraRunView.duration(from: start, to: start.addingTimeInterval(20)) == "az önce başladı")
        #expect(OrchestraRunView.duration(from: start, to: start.addingTimeInterval(18 * 60)) == "18 dk")
        #expect(OrchestraRunView.duration(from: start, to: start.addingTimeInterval(125 * 60)) == "2 sa 5 dk")
    }
}

@MainActor
@Suite struct RunPageTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    @Test func aCardsNotificationOpensItsRunPageOnce() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))

        store.focusTab(card.id)
        store.focusTab(card.id)
        #expect(project.selectedTabID == card.id)
        #expect(project.tabs.filter { $0.id == card.id }.count == 1)
        guard case .run(let page) = project.selectedTab else {
            Issue.record("the run page is not open")
            return
        }
        #expect(page.card?.title == "İş")

        store.focusTab(project.board.id)
        #expect(project.selectedTabID == project.board.id)
    }

    @Test func theRunPageIsSavedWithTheTabs() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        store.showRunPage(of: card.id, in: project)
        let state = WorkspaceStore.state(of: project)
        #expect(state.tabs.contains(.run(card: card.id)))
        let decoded = try JSONDecoder().decode(WorkspaceStore.ProjectState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func stoppingByHandEndsTheStory() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        project.board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/is")
        store.orchestraRuns[card.id] = OrchestraRun(
            cardID: card.id, team: OrchestraTeam(), branch: "tezgah/is", worktree: base, directory: base, base: "abc"
        )
        store.stopOrchestra(of: card, in: project)
        let record = try #require(project.board.cards.first?.run)
        #expect(record.events.last?.kind == .stopped)
        #expect(record.stopReason == "Orkestra elle durduruldu")
    }
}

@MainActor
@Suite struct PushAfterMergeTests {
    @Test func theSettingIsOffForOldTeamsAndSaved() throws {
        let old = try JSONDecoder().decode(OrchestraTeam.self, from: Data(#"{"maxRounds":2}"#.utf8))
        #expect(!old.pushesAfterMerge)
        var team = OrchestraTeam()
        team.pushesAfterMerge = true
        #expect(try JSONDecoder().decode(OrchestraTeam.self, from: JSONEncoder().encode(team)).pushesAfterMerge)
    }

    @Test func pushSetsUpTheRemoteOnceThenFollowsIt() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        await #expect(throws: GitError.self) { try await Git.push(in: root) } // no remote yet

        let remote = base.appendingPathComponent("remote.git")
        _ = try await Git.run(["init", "-q", "--bare", remote.path], in: base)
        _ = try await Git.run(["remote", "add", "origin", remote.path], in: root)
        try await Git.push(in: root)
        #expect(try await Git.run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: root).text.hasPrefix("origin/"))

        try Data("b\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qam", "y"], in: root)
        try await Git.push(in: root)
        let local = try await Git.run(["rev-parse", "HEAD"], in: root).text
        let pushed = try await Git.run(["rev-parse", "HEAD"], in: remote).text
        #expect(local == pushed)
    }

    @Test func aFailedPushSaysWhy() {
        let message = """
            To github.com:ahmet/tezgah.git
             ! [rejected]        main -> main (fetch first)
            error: failed to push some refs to 'github.com:ahmet/tezgah.git'
            """
        #expect(WorkspaceStore.pushFailureReason(message) == "! [rejected]        main -> main (fetch first)")
        #expect(WorkspaceStore.pushFailureReason("fatal: Authentication failed") == "fatal: Authentication failed")
        #expect(WorkspaceStore.pushFailureReason("") == "bilinmeyen bir hata")
    }

    @Test func aPushAfterTheMergeKeepsItMerged() {
        let record = BoardCard.RunRecord(
            team: OrchestraTeam(), branch: "tezgah/is", endedAt: .now,
            events: [BoardCard.RunEvent(kind: .merged, text: ""), BoardCard.RunEvent(kind: .pushFailed, text: "")]
        )
        #expect(record.isMerged)
        #expect(record.stopReason == nil)
        #expect(RunStage.reached(record.events) == .merge)
    }
}

@MainActor
@Suite struct PlanningTests {
    private func run(_ team: OrchestraTeam = OrchestraTeam()) -> OrchestraRun {
        OrchestraRun(cardID: UUID(), team: team, branch: "tezgah/abone", worktree: URL(fileURLWithPath: "/w"),
                     directory: URL(fileURLWithPath: "/w"), base: "abc123")
    }

    private var plan: BoardCard.RunPlan {
        BoardCard.RunPlan(
            summary: "Ücretli ve ücretsiz aboneler ayrı sayılacak.", approach: "Abonelik kaynağına göre filtre ekle.",
            doneCriteria: ["Ücretli abone sayısı ayrı görünür", "Filtre testleri geçer"],
            includedIdeas: ["Filtre seçimi adreste tutulur"],
            separateIdeas: [BoardCard.RunPlan.Idea(title: "Gelir grafiği", detail: "Aylık ücretli gelir")]
        )
    }

    @Test func teamsPlanByDefaultAndCanTurnItOff() throws {
        let old = try JSONDecoder().decode(OrchestraTeam.self, from: Data(#"{"maxRounds":3}"#.utf8))
        #expect(old.plans && old.planner.provider == .claude)
        var team = OrchestraTeam()
        team.plans = false
        team.planner = OrchestraTeam.Member(provider: .codex, model: "gpt-6-astra")
        let decoded = try JSONDecoder().decode(OrchestraTeam.self, from: JSONEncoder().encode(team))
        #expect(!decoded.plans && decoded.planner.provider == .codex)
        #expect(RunStage.stages(for: OrchestraTeam()).first == .plan)
    }

    @Test func thePlanToolReadsWhatThePlannerGave() {
        let parsed = WorkspaceStore.plan(from: [
            "summary": "  Özet  ", "approach": "Adımlar",
            "done_criteria": ["Test geçer", "", "  Liste ayrı  "],
            "included_ideas": ["Küçük iyileştirme"],
            "separate_ideas": [["title": "Büyük fikir", "detail": "Ayrıntı"], ["detail": "başlıksız"]],
        ])
        #expect(parsed?.summary == "Özet")
        #expect(parsed?.doneCriteria == ["Test geçer", "Liste ayrı"])
        #expect(parsed?.includedIdeas == ["Küçük iyileştirme"])
        #expect(parsed?.separateIdeas.map(\.title) == ["Büyük fikir"])
        #expect(WorkspaceStore.plan(from: ["approach": "özetsiz"]) == nil)
    }

    @Test func thePlanGoesToTheDeveloperAndTheReviewers() {
        var card = BoardCard(title: "Ücretli aboneler", notes: "Ücretsizlerle birlikte sayılıyor")
        let planner = WorkspaceStore.plannerPrompt(card: card)
        #expect(planner.contains("İş: Ücretli aboneler\nÜcretsizlerle birlikte sayılıyor"))
        #expect(planner.contains("plan_ready") && planner.contains("separate_ideas"))

        let developer = WorkspaceStore.developerPrompt(for: card, branch: "tezgah/abone", plan: plan, notes: "Testi ekle")
        #expect(developer.hasPrefix(WorkspaceStore.worktreePrompt(for: card, branch: "tezgah/abone")))
        #expect(developer.contains("## Plan\n\nÜcretli ve ücretsiz aboneler ayrı sayılacak."))
        #expect(developer.contains("- Ücretli abone sayısı ayrı görünür"))
        #expect(developer.contains("- Filtre seçimi adreste tutulur"))
        #expect(!developer.contains("Gelir grafiği")) // separate ideas aren't done here
        #expect(developer.contains("son gözden geçirmede şunlar istendi, bunları uygula:\n\nTesti ekle"))
        #expect(!WorkspaceStore.developerPrompt(for: card, branch: "b").contains("## Plan"))

        card.run = BoardCard.RunRecord(team: OrchestraTeam(), branch: "tezgah/abone", plan: plan)
        let run = run()
        let review = WorkspaceStore.reviewPrompt(card: card, run: run, member: OrchestraTeam.Member(provider: .codex), number: 1)
        #expect(review.contains("“bitti” ölçütleri") && review.contains("- Filtre testleri geçer"))
        let judge = WorkspaceStore.judgePrompt(card: card, run: run, reviews: [])
        #expect(judge.contains("- Ücretli abone sayısı ayrı görünür"))
    }

    @Test func aBigIdeaBecomesItsOwnCardAtTheEndOnce() throws {
        let board = ProjectBoard()
        let first = try #require(board.add("Önce sıradaki"))
        let card = try #require(board.add("Ücretli aboneler"))
        board.beginRun(on: card.id, team: OrchestraTeam(), branch: "tezgah/abone")
        board.setPlan(plan, on: card.id)
        let idea = try #require(board.cards.first { $0.id == card.id }?.run?.plan?.separateIdeas.first)

        let added = try #require(board.addIdea(idea.id, from: card.id))
        #expect(board.cards(in: .todo).map(\.id) == [card.id, first.id, added.id])
        #expect(added.notes.contains("Aylık ücretli gelir") && added.notes.contains("“Ücretli aboneler” kartının planından"))
        #expect(board.cards.first { $0.id == card.id }?.run?.plan?.separateIdeas.first?.isOnBoard == true)
        #expect(board.addIdea(idea.id, from: card.id) == nil)
        #expect(board.cards.count == 3)
    }

    @Test func planningIsAStepOfItsOwn() throws {
        let run = run()
        run.set(.planning)
        let planner = UUID()
        run.plannerTab = planner
        #expect(run.contains(planner) && run.stepTabs.contains(planner))
        #expect(run.summary == "Planlanıyor")
        #expect(RunStage.current(run.phase) == .plan)
        #expect(WorkspaceStore.resumeStep(for: .planning, hasNewCommits: false, isClean: true) == .plan)
        let saved = run.saved(developerSession: nil)
        #expect(try JSONDecoder().decode(SavedOrchestraRun.self, from: JSONEncoder().encode(saved)).phase == .planning)
        #expect(RunStage.reached([BoardCard.RunEvent(kind: .planning, text: ""), BoardCard.RunEvent(kind: .stopped, text: "")]) == .plan)
    }

    @Test func onlyThePlannerCanHandInThePlan() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let card = try #require(project.board.add("İş"))
        let run = run()
        store.orchestraRuns[card.id] = run
        #expect(store.recordPlan(from: UUID(), plan).isError) // not one of the run's tabs
        run.plannerTab = UUID()
        run.set(.developing)
        #expect(store.recordPlan(from: run.plannerTab!, plan).isError) // planning is over
    }
}
