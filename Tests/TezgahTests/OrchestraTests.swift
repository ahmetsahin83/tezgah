import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct OrchestraTeamTests {
    @Test func teamsSurviveSavingAndOldProjectsGetTheDefault() throws {
        var team = OrchestraTeam()
        team.reviewers.append(OrchestraTeam.Member(provider: .claude, model: "opus", focus: "güvenlik"))
        team.maxRounds = 5
        let decoded = try JSONDecoder().decode(OrchestraTeam.self, from: JSONEncoder().encode(team))
        #expect(decoded == team)

        let old = try JSONDecoder().decode(WorkspaceStore.ProjectState.self, from: Data(#"{"tabs":[]}"#.utf8))
        #expect(old.orchestraTeam == nil)
        // A team saved with fewer fields than Tezgah knows now.
        let partial = try JSONDecoder().decode(OrchestraTeam.self, from: Data(#"{"reviewers":[{"provider":"claude"}]}"#.utf8))
        #expect(partial.reviewers.map(\.provider) == [.claude])
        #expect(partial.maxRounds == OrchestraTeam().maxRounds)
    }

    @Test func codexModelsComeFromItsCatalog() {
        let catalog = #"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list"},{"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide"},{"slug":"plain"}]}"#
        let models = AgentModels.codexModels(fromCatalog: Data(catalog.utf8))
        #expect(models.map(\.id) == ["gpt-6.1-sol", "plain"])
        #expect(models.first?.name == "GPT-6.1-Sol")
        #expect(AgentModels.codexModels(fromCatalog: Data("not json".utf8)).isEmpty)
    }

    @Test func membersAreNamedByAgentAndModel() {
        #expect(OrchestraTeam.Member(provider: .claude, model: "opus").title == "Claude · Opus")
        #expect(OrchestraTeam.Member(provider: .codex).title == "Codex")
    }
}

@MainActor
@Suite struct OrchestraLaunchTests {
    @Test func reviewersStartReadOnlyWithTheirModel() {
        let claude = ClaudeMonitor(directory: URL(fileURLWithPath: "/tmp/c"), hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        let command = claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh", model: "sonnet", readOnly: true)
        #expect(command.hasPrefix("'/c' --disallowedTools Edit MultiEdit NotebookEdit Write --settings "))
        #expect(command.contains("--model 'sonnet'"))
        #expect(!claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh").contains("--disallowedTools"))

        let codex = CodexMonitor(hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        let review = codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh", prompt: "incele", model: "gpt-6-sol", readOnly: true)
        #expect(review.hasPrefix("'/x' --no-daemon --model 'gpt-6-sol' --sandbox read-only -c "))
        #expect(review.hasSuffix(" 'incele'; exec '/bin/zsh' -l"))
    }

    @Test func agentsCanRunWithoutAskingWhileReviewersStayReadOnly() {
        let claude = ClaudeMonitor(directory: URL(fileURLWithPath: "/tmp/c"), hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        #expect(!claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh").contains("--dangerously-skip-permissions"))
        #expect(claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh", skipPermissions: true).contains("--dangerously-skip-permissions"))
        let review = claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh", readOnly: true, skipPermissions: true)
        #expect(review.hasPrefix("'/c' --disallowedTools Edit MultiEdit NotebookEdit Write --settings "))
        #expect(review.contains("--dangerously-skip-permissions"))

        let codex = CodexMonitor(hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        let plain = codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh")
        #expect(!plain.contains("--dangerously-bypass-approvals-and-sandbox") && !plain.contains("--ask-for-approval"))
        let developer = codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh", skipPermissions: true)
        #expect(developer.hasPrefix("'/x' --no-daemon --dangerously-bypass-approvals-and-sandbox -c "))
        // A reviewer too, so it can build and test; the orchestra undoes what a review leaves behind.
        let reviewer = codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh", readOnly: true, skipPermissions: true)
        #expect(reviewer.hasPrefix("'/x' --no-daemon --dangerously-bypass-approvals-and-sandbox -c "))
        #expect(!reviewer.contains("--sandbox"))
        let resumed = codex.command(for: .resume(sessionID: "abc"), codexPath: "/x", shell: "/bin/zsh", skipPermissions: true)
        #expect(resumed.hasPrefix("'/x' resume --no-daemon --dangerously-bypass-approvals-and-sandbox -c "))
    }

    @Test func theOrchestrasAgentsCantStopToAskAQuestion() {
        let claude = ClaudeMonitor(directory: URL(fileURLWithPath: "/tmp/c"), hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        let developer = claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh", asksQuestions: false)
        #expect(developer.hasPrefix("'/c' --disallowedTools AskUserQuestion --settings "))
        let reviewer = claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh", readOnly: true, asksQuestions: false)
        #expect(reviewer.hasPrefix("'/c' --disallowedTools AskUserQuestion Edit MultiEdit NotebookEdit Write --settings "))
        #expect(!claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh").contains("AskUserQuestion"))
    }

    @Test func bypassPermissionsIsAModeClaudeReports() {
        #expect(TerminalSession.ClaudeMode(rawValue: "bypassPermissions") == .bypassPermissions)
        #expect(TerminalSession.ClaudeMode.bypassPermissions.marker == "bypass permissions on")
    }

    @Test func theFullReplyIsKept() {
        let activity = AgentActivity(provider: .codex)
        activity.handle(["hook_event_name": "Stop", "last_assistant_message": "Onaylıyorum.\nAyrıntılar burada."])
        #expect(activity.message == "Onaylıyorum.")
        #expect(activity.lastReply == "Onaylıyorum.\nAyrıntılar burada.")
    }
}

@MainActor
@Suite struct OrchestraPromptTests {
    private func run() -> OrchestraRun {
        var team = OrchestraTeam()
        team.reviewers = [
            OrchestraTeam.Member(provider: .codex, focus: "güvenlik"),
            OrchestraTeam.Member(provider: .claude, model: "opus"),
        ]
        return OrchestraRun(
            cardID: UUID(), team: team, branch: "tezgah/giris", worktree: URL(fileURLWithPath: "/w"),
            directory: URL(fileURLWithPath: "/w"), base: "abc123"
        )
    }

    @Test func reviewersLookAtTheBranchAndAnswerWithTheTool() {
        let run = run()
        let card = BoardCard(title: "Giriş ekranı", notes: "Şifre alanı kayıyor")
        let prompt = WorkspaceStore.reviewPrompt(card: card, run: run, member: run.team.reviewers[0], number: 1)
        #expect(prompt.contains("git diff abc123..HEAD"))
        #expect(prompt.contains("İş: Giriş ekranı\nŞifre alanı kayıyor"))
        #expect(prompt.contains("Özellikle şuna bak: güvenlik"))
        #expect(prompt.contains("review_verdict"))
        #expect(!WorkspaceStore.reviewPrompt(card: card, run: run, member: run.team.reviewers[1], number: 2).contains("Özellikle"))
    }

    @Test func theJudgeSeesEveryReview() {
        let run = run()
        let prompt = WorkspaceStore.judgePrompt(card: nil, run: run, reviews: [
            (run.team.reviewers[0], OrchestraRun.Verdict(approved: false, notes: "SQL injection riski")),
            (run.team.reviewers[1], nil),
        ])
        #expect(prompt.contains("### 1. Codex · odak: güvenlik\nKarar: Değişiklik istiyor\nSQL injection riski"))
        #expect(prompt.contains("### 2. Claude · Opus\nKarar: Karar bildirmedi"))
        #expect(prompt.contains("review_verdict"))
    }

    @Test func theDeveloperDecidesForItselfAndWritesItsAssumptionsDown() {
        let card = BoardCard(title: "Giriş ekranı", notes: "Şifre alanı kayıyor")
        let prompt = WorkspaceStore.developerPrompt(for: card, branch: "tezgah/giris")
        #expect(prompt.hasPrefix(WorkspaceStore.worktreePrompt(for: card, branch: "tezgah/giris")))
        #expect(prompt.contains("soru sorabileceğin kimse yok"))
        #expect(prompt.contains("varsayımları commit mesajına yaz"))
    }

    @Test func feedbackTellsTheRound() {
        let prompt = WorkspaceStore.feedbackPrompt("  Testi ekle\n", round: 2, of: 3)
        #expect(prompt.hasPrefix("Gözden geçirme sonucu değişiklik istendi (tur 2/3):\n\nTesti ekle\n\n"))
    }
}

@MainActor
@Suite struct OrchestraVerdictTests {
    @Test func verdictsCountOnlyFromThisRoundsReviewers() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        var team = OrchestraTeam()
        team.reviewers = [OrchestraTeam.Member(provider: .codex), OrchestraTeam.Member(provider: .codex)]
        let run = OrchestraRun(cardID: UUID(), team: team, branch: "tezgah/x", worktree: root, directory: root, base: "abc")
        store.orchestraRuns[run.cardID] = run
        let reviewer = TerminalSession(directory: root, title: "R", command: "cat", agent: AgentActivity(provider: .codex))
        let other = TerminalSession(directory: root, title: "O", command: "cat", agent: AgentActivity(provider: .codex))
        defer { reviewer.terminate(); other.terminate() }
        project.tabs += [.terminal(reviewer), .terminal(other)]

        #expect(store.recordVerdict(from: reviewer.id, approved: true, notes: "").isError) // not a reviewer yet
        run.startReview()
        run.addReviewer(team.reviewers[0], in: reviewer.id)
        run.addReviewer(team.reviewers[1], in: other.id)
        run.reviewersStarted()

        #expect(!store.recordVerdict(from: reviewer.id, approved: true, notes: "iyi").isError)
        #expect(store.recordVerdict(from: reviewer.id, approved: false, notes: "tekrar").isError) // once per round
        #expect(run.verdicts[reviewer.id] == OrchestraRun.Verdict(approved: true, notes: "iyi"))
        #expect(!run.reviewsAreIn)
        #expect(store.recordVerdict(from: UUID(), approved: true, notes: "").isError)
    }
}

@MainActor
@Suite struct ThinkingLevelTests {
    @Test func membersKeepTheirLevelAndOldOnesHaveNone() throws {
        let old = try JSONDecoder().decode(OrchestraTeam.Member.self, from: Data(#"{"provider":"codex","model":"gpt-6-astra"}"#.utf8))
        #expect(old.effort == nil)
        let member = OrchestraTeam.Member(provider: .claude, model: "fable", effort: "xhigh")
        #expect(try JSONDecoder().decode(OrchestraTeam.Member.self, from: JSONEncoder().encode(member)).effort == "xhigh")
    }

    @Test func codexModelsBringTheirLevels() {
        let catalog = #"{"models":[{"slug":"gpt-6.1-sol","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"ultra"}]},{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#
        let models = AgentModels.codexModels(fromCatalog: Data(catalog.utf8))
        #expect(models.first?.efforts == ["low", "high", "ultra"])

        #expect(AgentModels.efforts(for: OrchestraTeam.Member(provider: .codex, model: "gpt-6.1-sol"), codexModels: models) == ["low", "high", "ultra"])
        // Codex's own default model: what every listed model takes.
        #expect(AgentModels.efforts(for: OrchestraTeam.Member(provider: .codex), codexModels: models) == ["low", "high"])
        #expect(AgentModels.efforts(for: OrchestraTeam.Member(provider: .codex), codexModels: []) == ["low", "medium", "high", "xhigh"])
        #expect(AgentModels.efforts(for: OrchestraTeam.Member(provider: .claude), codexModels: models) == TerminalSession.effortLevels)
        #expect(AgentModels.effortTitle("xhigh") == "Çok yüksek")
    }

    @Test func theLevelReachesTheAgent() {
        let claude = ClaudeMonitor(directory: URL(fileURLWithPath: "/tmp/c"), hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        #expect(claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh", model: "fable", effort: "xhigh").contains("--model 'fable' --effort 'xhigh'"))
        #expect(!claude.command(for: .new, claudePath: "/c", shell: "/bin/zsh").contains("--effort"))

        let codex = CodexMonitor(hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        let review = codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh", model: "gpt-6-astra", effort: "high", readOnly: true)
        #expect(review.hasPrefix(#"'/x' --no-daemon --model 'gpt-6-astra' -c 'model_reasoning_effort="high"' --sandbox read-only "#))
        #expect(!codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh").contains("model_reasoning_effort"))
    }
}
