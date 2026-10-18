import Foundation

/// The orchestra: takes a board card through develop → review → decide → merge by itself.
///
/// The developer works in the card's worktree and commits there. When its turn ends with new
/// commits, every reviewer looks at what changed since the branch started (read-only) and gives a
/// verdict with Tezgah's `review_verdict` tool. One reviewer's verdict stands; several go to the
/// judge, who weighs them into one. An approval is merged into the project's checked-out branch
/// and the worktree goes; changes asked for go back to the developer for another round. The run
/// stops and tells the user when it can't go on by itself: no commits, a merge that conflicts,
/// the round limit.
extension WorkspaceStore {
    /// "Orkestrayla Başlat" on a card, with the project's team. `inBackground` leaves the user
    /// where they are, for the queue.
    func startOrchestra(_ card: BoardCard, in project: Project, inBackground: Bool = false) {
        guard let root = project.git.root else {
            cannotStartOrchestra(card, in: project, "Bunun için proje bir git deposu olmalı.")
            return
        }
        let team = project.orchestraTeam
        let projectURL = project.url
        Task { [weak self, weak project] in
            do {
                let created = try await Worktrees.create(named: card.title, projectURL: projectURL, root: root)
                let base = try await Git.run(["rev-parse", "HEAD"], in: created.url).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, let project, var current = project.board.cards.first(where: { $0.id == card.id }) else { return }
                current.worktree = BoardCard.Worktree(branch: created.branch, path: created.url.path)
                project.board.update(current)
                project.board.move(card.id, to: .doing)
                let run = OrchestraRun(
                    cardID: card.id, team: team, branch: created.branch, worktree: created.url,
                    directory: created.url.appendingPathComponent(project.git.prefix, isDirectory: true), base: base
                )
                orchestraRuns[card.id] = run
                _ = await AgentModels.codexModels() // so the story names Codex's models, not their ids
                project.board.beginRun(on: card.id, team: team, branch: created.branch)
                if !inBackground {
                    if activeProjectID != project.id { select(project) }
                    showRunPage(of: card.id, in: project)
                }
                if team.plans {
                    await startPlanning(run, in: project)
                } else {
                    await startDeveloper(run, in: project)
                }
            } catch {
                guard let self, let project else { return }
                cannotStartOrchestra(card, in: project, error.localizedDescription)
            }
        }
    }

    /// The planner reads the card and the code, without changing anything, and hands its plan over
    /// with `plan_ready`. A planner that can't start leaves the developer to work without a plan.
    func startPlanning(_ run: OrchestraRun, in project: Project) async {
        guard let card = project.board.cards.first(where: { $0.id == run.cardID }) else { return }
        run.set(.planning)
        run.reminded = []
        logRun(card.id, in: project, .planning, "Planlama başladı · \(run.team.planner.title)")
        guard let planner = await launchAgent(
            run.team.planner, in: project, directory: run.directory, prompt: Self.plannerPrompt(card: card),
            readOnly: true, asksQuestions: false
        ) else {
            logRun(card.id, in: project, .note, "\(run.team.planner.provider.displayName) başlatılamadı; plansız geliştirmeye geçiliyor")
            await startDeveloper(run, in: project)
            return
        }
        run.plannerTab = planner.id
    }

    /// `plan_ready` from the planner.
    func recordPlan(from tab: UUID, _ plan: BoardCard.RunPlan) -> MCPToolResult {
        guard let run = orchestraRun(of: tab), tab == run.plannerTab, run.phase == .planning, let (_, project) = claudeTab(tab) else {
            return .error("Şu an bu oturumdan bir plan beklenmiyor.")
        }
        Task { await planReady(run, plan, in: project) }
        return .text("Plan kaydedildi ve geliştiriciye gidiyor. Başka bir şey yapmana gerek yok.")
    }

    /// The plan goes on the card and to the developer; nil goes on without one. A plan that says
    /// the card is blocked stops the run until the user answers.
    private func planReady(_ run: OrchestraRun, _ plan: BoardCard.RunPlan?, in project: Project) async {
        guard run.phase == .planning else { return }
        if let plan, let blocked = plan.blocked {
            project.board.setPlan(plan, on: run.cardID)
            run.plannerTab = nil
            stop(run, "Bilgi gerekiyor: \(blocked)", in: project, needsAnswers: true)
            return
        }
        if let plan {
            project.board.setPlan(plan, on: run.cardID)
            var counts = ["\(plan.doneCriteria.count) ölçüt"]
            if !plan.includedIdeas.isEmpty { counts.append("\(plan.includedIdeas.count) katkı") }
            if !plan.separateIdeas.isEmpty { counts.append("\(plan.separateIdeas.count) ayrı öneri") }
            logRun(run.cardID, in: project, .planned, "Plan hazır · " + counts.joined(separator: ", "), detail: plan.summary)
        }
        closeStepTabs(of: run, in: project)
        run.plannerTab = nil
        await startDeveloper(run, in: project)
    }

    /// The developer starts on the card, with the plan when there is one and what the last review
    /// asked for when it takes over a later round.
    private func startDeveloper(_ run: OrchestraRun, in project: Project) async {
        guard let card = project.board.cards.first(where: { $0.id == run.cardID }) else { return }
        run.set(.developing)
        run.reminded = []
        logRun(card.id, in: project, .started, "Geliştirici başladı · \(run.team.developer.title)")
        let prompt = Self.developerPrompt(for: card, branch: run.branch, plan: card.run?.plan, notes: run.round > 1 ? run.lastNotes : nil)
        guard let developer = await launchAgent(
            run.team.developer, in: project, directory: run.directory, prompt: prompt, readOnly: false, asksQuestions: false
        ) else {
            stop(run, "\(run.team.developer.provider.displayName) bulunamadı", in: project)
            return
        }
        run.developerTab = developer.id
    }

    /// "Devam Et" for a stopped card, for its button; nil while it runs, or when it waits for the
    /// answers to the planner's questions (answering is its way on).
    func continueTitle(for cardID: UUID) -> String? {
        guard let run = orchestraRuns[cardID], case .needsUser = run.phase else { return nil }
        let card = projects.lazy.compactMap { $0.board.cards.first { $0.id == cardID } }.first
        return card?.run?.isWaitingForAnswers == true ? nil : "Devam Et"
    }

    /// Takes a stopped run on from where it is, on the same branch, with no round limit from now on.
    /// A step that ran out of time starts again. Otherwise the branch decides: new commits go to
    /// review, uncommitted work gets finished and committed, and a developer with nothing new gets
    /// what the last review asked for (a new round after the round limit), or is told to go on.
    @discardableResult
    func continueOrchestra(of cardID: UUID, in project: Project) async -> Bool {
        guard continueTitle(for: cardID) != nil, let run = orchestraRuns[cardID] else { return false }
        let continuation = run.continuation
        run.continuation = nil
        run.ignoresRoundLimit = true
        logRun(cardID, in: project, .resumed, "Devam ettirildi; bu kartta tur sınırı yok")
        switch continuation {
        case .moreTime(.plan):
            await startPlanning(run, in: project)
            return true
        case .moreTime(.review), .moreTime(.judge):
            await startReview(of: run, in: project)
            return true
        default:
            break
        }
        let head = (try? await Git.run(["rev-parse", "HEAD"], in: run.worktree).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let isClean = (try? await Worktrees.hasUncommittedChanges(at: run.worktree)) == false
        if isClean, !head.isEmpty, head != (run.reviewedHead ?? run.base) {
            run.reviewedHead = head
            await startReview(of: run, in: project)
            return true
        }
        let notes = run.lastNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt: String
        if !isClean {
            run.set(.developing)
            prompt = Self.commitReminder
        } else if continuation == .moreRounds, !notes.isEmpty {
            run.nextRound(notes: notes)
            logRun(cardID, in: project, .round, Self.roundText(run) + ": istenen değişiklikler geliştiriciye gitti")
            prompt = Self.feedbackPrompt(notes, round: run.round, of: run.maxRounds)
        } else {
            run.set(.developing)
            prompt = notes.isEmpty ? Self.continuePrompt : Self.feedbackPrompt(notes, round: run.round, of: run.maxRounds)
        }
        if let developer = run.developerTab.flatMap({ claudeTab($0)?.session }), developer.agent?.state != .ended {
            sendPrompt(prompt, to: developer)
        } else {
            await startDeveloper(run, in: project) // takes the plan and the last notes
        }
        return true
    }

    /// "Tur 4/5", or "Tur 6" with no limit.
    static func roundText(_ run: OrchestraRun) -> String {
        "Tur \(run.round)" + (run.maxRounds.map { "/\($0)" } ?? "")
    }

    static let continuePrompt = "Orkestra durmuştu; kullanıcı devam etmeni istedi. İşi kaldığın yerden sürdür, bitince değişiklikleri bu dalda commit'le."

    /// Whether a restart would throw work away: uncommitted changes, or commits the project's
    /// branch doesn't have.
    func hasWork(on card: BoardCard, in project: Project) async -> Bool {
        guard let worktree = card.worktree, FileManager.default.fileExists(atPath: worktree.path), let root = project.git.root else { return false }
        if (try? await Worktrees.hasUncommittedChanges(at: URL(fileURLWithPath: worktree.path, isDirectory: true))) == true { return true }
        let ahead = (try? await Git.run(["rev-list", "--count", "HEAD..\(worktree.branch)"], in: root).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0"
        return (Int(ahead) ?? 0) > 0
    }

    /// Runs a stopped card again from the start: its run, tabs, worktree and branch go, its story
    /// stays. `answer` (to the planner's questions) goes into the card's notes first. When the
    /// branch has work the user is asked, unless they already agreed (`confirmed`, from Telegram).
    /// With the queue on, the card goes to the top of "Yapılacak" for the queue to take next.
    @discardableResult
    func restartOrchestra(of cardID: UUID, in project: Project, answer: String? = nil, confirmed: Bool = false) async -> Bool {
        guard var card = project.board.cards.first(where: { $0.id == cardID }), orchestraRuns[cardID]?.isActive != true else { return false }
        if !confirmed, await hasWork(on: card, in: project) {
            guard await ConfirmSheet.ask(
                title: "“\(card.title)” baştan başlatılsın mı?",
                message: "“\(card.worktree?.branch ?? "")” dalındaki iş silinir; kartın akışı kalır.",
                confirm: "Baştan Başlat"
            ) else { return false }
        }
        let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !answer.isEmpty {
            card.notes = [card.notes.trimmingCharacters(in: .whitespacesAndNewlines), "Planlayıcının sorularına cevap:\n\(answer)"]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            project.board.update(card)
        }
        if let run = orchestraRuns[cardID] { closeStepTabs(of: run, in: project) }
        orchestraRuns[cardID] = nil
        if card.worktree != nil {
            await finishWorktree(of: card, in: project, closing: worktreeTabs(of: card, in: project), force: true)
        }
        logRun(cardID, in: project, .resumed, answer.isEmpty ? "Baştan başlatıldı" : "Sorular cevaplandı; baştan başlatıldı", detail: answer.isEmpty ? nil : answer)
        guard let fresh = project.board.cards.first(where: { $0.id == cardID }) else { return false }
        if project.orchestraQueue != nil {
            project.board.move(cardID, to: .todo, before: project.board.cards(in: .todo).first { $0.id != cardID }?.id)
            advanceQueue(in: project)
        } else {
            startOrchestra(fresh, in: project, inBackground: true)
        }
        return true
    }

    /// Stops runs that went past their step's time limit: an agent stuck on a command or in a loop
    /// would otherwise hold the card, and the queue behind it, for good. Its turn is cut off too.
    func checkOrchestraTimeouts(now: Date = .now) {
        for run in orchestraRuns.values where run.isActive {
            guard let minutes = run.team.minutes(for: run.phase),
                  now.timeIntervalSince(run.phaseStartedAt) > Double(minutes) * 60,
                  let project = projects.first(where: { $0.board.cards.contains { $0.id == run.cardID } }) else { continue }
            let stage = RunStage.current(run.phase) ?? .develop
            if let developer = run.developerTab.flatMap({ claudeTab($0)?.session }), run.phase == .developing {
                developer.sendClaudeKey(.escape)
            }
            stop(run, "Süre sınırı doldu: \(stage.title.lowercased(with: Locale(identifier: "tr"))) \(minutes) dakikayı geçti", in: project,
                 continuation: .moreTime(stage))
        }
    }

    /// A card the user started gets an alert; the queue's card stops the queue, which would only
    /// fail the same way on the next one.
    private func cannotStartOrchestra(_ card: BoardCard, in project: Project, _ reason: String) {
        if project.orchestraQueue?.cardID == card.id {
            stopQueue(in: project, because: "Orkestra başlatılamadı: \(reason)")
        } else {
            Self.showWorktreeError("Orkestra başlatılamadı", reason)
        }
    }

    /// Stops the card's run; its worktree and the developer's tab stay for the board's own actions.
    func stopOrchestra(of card: BoardCard, in project: Project) {
        guard let run = orchestraRuns[card.id] else { return }
        closeStepTabs(of: run, in: project)
        orchestraRuns[card.id] = nil
        logRun(card.id, in: project, .stopped, "Orkestra elle durduruldu")
        queueCardTakenOver(card.id, in: project)
    }

    /// A step of the card's run, for its page.
    func logRun(_ cardID: UUID, in project: Project, _ kind: BoardCard.RunEvent.Kind, _ text: String, detail: String? = nil, commits: Int = 0) {
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        project.board.logRun(
            on: cardID, BoardCard.RunEvent(kind: kind, text: text, detail: detail?.isEmpty == false ? detail : nil), commits: commits
        )
    }

    func orchestraRun(of tab: UUID) -> OrchestraRun? {
        orchestraRuns.values.first { $0.contains(tab) }
    }

    /// Every agent state change goes through here; a tab of a run moves the run along.
    func orchestraNoticed(_ activity: AgentActivity, in session: TerminalSession, project: Project) {
        guard let run = orchestraRun(of: session.id) else { return }
        switch activity.state {
        case .finished:
            let turn = activity.turnStartedAt ?? .distantPast
            guard run.handledTurns[session.id] != turn else { return }
            run.handledTurns[session.id] = turn
            Task { await turnFinished(in: session, of: run, project: project) }
        case .ended where session.id == run.developerTab && run.isActive:
            stop(run, "Geliştiricinin oturumu kapandı", in: project)
        case .ended where session.id == run.plannerTab && run.phase == .planning:
            logRun(run.cardID, in: project, .note, "Planlayıcının oturumu kapandı; plansız geliştirmeye geçiliyor")
            Task { await planReady(run, nil, in: project) }
        default:
            break
        }
    }

    /// `review_verdict` from a reviewer or the judge.
    func recordVerdict(from tab: UUID, approved: Bool, notes: String) -> MCPToolResult {
        guard let run = orchestraRun(of: tab), let (_, project) = claudeTab(tab) else {
            return .error("Bu oturum Tezgah'ta bir gözden geçirme yapmıyor.")
        }
        let verdict = OrchestraRun.Verdict(approved: approved, notes: notes)
        if tab == run.judgeTab, run.phase == .judging {
            logRun(run.cardID, in: project, approved ? .approved : .changesRequested,
                   "Karar verici " + (approved ? "onayladı" : "değişiklik istedi"), detail: notes)
            Task { await finishRound(of: run, with: verdict, in: project) }
            return .text("Karar kaydedildi; Tezgah buradan devam ediyor. Başka bir şey yapmana gerek yok.")
        }
        guard let member = run.reviewers[tab], run.phase == .reviewing, run.verdicts[tab] == nil else {
            return .error("Şu an bu oturumdan bir karar beklenmiyor.")
        }
        logRun(run.cardID, in: project, approved ? .approved : .changesRequested,
               "\(member.title) " + (approved ? "onayladı" : "değişiklik istedi"), detail: notes)
        run.record(verdict, from: tab)
        Task { await reviewsMayBeIn(run, in: project) }
        return .text("Değerlendirmen kaydedildi. Başka bir şey yapmana gerek yok.")
    }

    // MARK: Steps

    private func turnFinished(in session: TerminalSession, of run: OrchestraRun, project: Project) async {
        if session.id == run.plannerTab {
            // Done without plan_ready: reminded once, then what it wrote goes on as the plan.
            guard run.phase == .planning else { return }
            if !run.reminded.contains(session.id) {
                run.reminded.insert(session.id)
                sendPrompt(Self.planReminder, to: session)
                return
            }
            let said = session.agent?.lastReply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logRun(run.cardID, in: project, .note, "Planlayıcı planını araçla bildirmedi; yazdıkları plan olarak geliştiriciye gidiyor")
            await planReady(run, said.isEmpty ? nil : BoardCard.RunPlan(summary: said), in: project)
            return
        }
        if session.id == run.developerTab {
            switch run.phase {
            case .developing: await developerFinished(session, run, in: project)
            case .needsUser: await stoppedDeveloperFinished(session, run, in: project)
            default: break
            }
            return
        }
        // A reviewer or the judge ended its turn: fine if it gave its verdict, else remind it once.
        let isJudge = session.id == run.judgeTab
        guard isJudge ? run.phase == .judging : (run.phase == .reviewing && run.verdicts[session.id] == nil) else { return }
        if !run.reminded.contains(session.id) {
            run.reminded.insert(session.id)
            sendPrompt(Self.verdictReminder, to: session)
        } else if isJudge {
            stop(run, "Karar verici karar bildirmedi", in: project)
        } else {
            // Its words still reach the judge.
            let who = run.reviewers[session.id]?.title ?? "Gözden geçiren"
            logRun(run.cardID, in: project, .silent, "\(who) karar bildirmedi; yazdıkları karar vericiye gidiyor")
            run.record(OrchestraRun.Verdict(approved: nil, notes: session.agent?.lastReply ?? ""), from: session.id)
            await reviewsMayBeIn(run, in: project)
        }
    }

    /// The developer of a stopped run ended a turn, e.g. one the user asked for in its tab. With new
    /// commits and nothing left uncommitted the run goes on; otherwise it stays stopped as it was,
    /// with its reason kept.
    private func stoppedDeveloperFinished(_ session: TerminalSession, _ run: OrchestraRun, in project: Project) async {
        let head = (try? await Git.run(["rev-parse", "HEAD"], in: run.worktree).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !head.isEmpty, head != (run.reviewedHead ?? run.base),
              (try? await Worktrees.hasUncommittedChanges(at: run.worktree)) == false else { return }
        run.continuation = nil
        await developerFinished(session, run, in: project)
    }

    private func developerFinished(_ session: TerminalSession, _ run: OrchestraRun, in project: Project) async {
        // The user answered a stopped run's developer, who went on.
        let wasStopped = if case .needsUser = run.phase { true } else { false }
        if (try? await Worktrees.hasUncommittedChanges(at: run.worktree)) == true {
            if !run.reminded.contains(session.id) {
                run.reminded.insert(session.id)
                run.set(.developing)
                logRun(run.cardID, in: project, .reminder, "Commit'lenmemiş değişiklik vardı; geliştiriciye commit'lemesi hatırlatıldı")
                sendPrompt(Self.commitReminder, to: session)
            } else {
                stop(run, "Geliştirici commit'lenmemiş değişiklik bıraktı", in: project)
            }
            return
        }
        let head = (try? await Git.run(["rev-parse", "HEAD"], in: run.worktree).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let since = run.reviewedHead ?? run.base
        guard !head.isEmpty, head != since else {
            stop(run, run.round == 1 ? "Geliştirici commit'siz bitirdi" : "Geliştirici yeni commit eklemedi", in: project)
            return
        }
        // The branch's own commits; a merged-in project branch brings its history along.
        let commits = ((try? await Git.run(["log", "--first-parent", "--format=%h %s", "\(since)..\(head)"], in: run.worktree).text) ?? "")
            .split(separator: "\n").map(String.init)
        if wasStopped {
            logRun(run.cardID, in: project, .resumed, "Geliştirici işi sürdürdü; koşu devam ediyor")
        }
        if let latest = commits.first {
            let subject = latest.split(separator: " ", maxSplits: 1).last.map(String.init) ?? latest
            logRun(run.cardID, in: project, .commits,
                   (run.conflictTarget == nil ? "" : "Çakışma çözüldü · ") + "\(commits.count) commit: “\(subject)”",
                   detail: commits.count > 1 ? commits.joined(separator: "\n") : nil, commits: commits.count)
        }
        if let target = run.conflictTarget {
            // The project's branch is in now: what the branch adds is what came after its tip.
            guard (try? await Git.run(["merge-base", "--is-ancestor", target, "HEAD"], in: run.worktree)) != nil,
                  let tip = try? await Git.run(["rev-parse", target], in: run.worktree).text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                stop(run, "Geliştirici çakışmayı çözmeden bitirdi (\(target) dala birleştirilmemiş)", in: project)
                return
            }
            run.base = tip
        }
        run.reviewedHead = head
        await startReview(of: run, in: project)
    }

    func startReview(of run: OrchestraRun, in project: Project) async {
        guard !run.team.reviewers.isEmpty else {
            await finishRound(of: run, with: OrchestraRun.Verdict(approved: true, notes: ""), in: project)
            return
        }
        let card = project.board.cards.first { $0.id == run.cardID }
        run.startReview()
        for (index, member) in run.team.reviewers.enumerated() {
            let prompt = Self.reviewPrompt(card: card, run: run, member: member, number: index + 1)
            if let session = await launchAgent(member, in: project, directory: run.directory, prompt: prompt, readOnly: true, asksQuestions: false) {
                run.addReviewer(member, in: session.id)
            }
        }
        run.reviewersStarted()
        guard !run.reviewers.isEmpty else {
            stop(run, "Gözden geçirenler başlatılamadı", in: project)
            return
        }
        logRun(run.cardID, in: project, .review, "Gözden geçirme başladı · " + run.reviewers.values.map(\.title).sorted().joined(separator: ", "))
        await reviewsMayBeIn(run, in: project)
    }

    private func reviewsMayBeIn(_ run: OrchestraRun, in project: Project) async {
        guard run.reviewsAreIn else { return }
        if run.reviewers.count == 1, let only = run.verdicts.values.first {
            guard only.approved != nil else {
                stop(run, "Gözden geçiren karar bildirmedi", in: project)
                return
            }
            await finishRound(of: run, with: only, in: project)
            return
        }
        let card = project.board.cards.first { $0.id == run.cardID }
        let reviews = run.reviewers.sorted { lhs, rhs in
            (run.team.reviewers.firstIndex { $0.id == lhs.value.id } ?? 0) < (run.team.reviewers.firstIndex { $0.id == rhs.value.id } ?? 0)
        }.map { (member: $0.value, verdict: run.verdicts[$0.key]) }
        let prompt = Self.judgePrompt(card: card, run: run, reviews: reviews)
        guard let judge = await launchAgent(run.team.judge, in: project, directory: run.directory, prompt: prompt, readOnly: true, asksQuestions: false) else {
            stop(run, "Karar verici başlatılamadı", in: project)
            return
        }
        logRun(run.cardID, in: project, .judging, "Karar verici değerlendirmeleri tartıyor · \(run.team.judge.title)")
        run.startJudging(in: judge.id)
    }

    func finishRound(of run: OrchestraRun, with verdict: OrchestraRun.Verdict, in project: Project) async {
        closeStepTabs(of: run, in: project)
        await undoReviewChanges(of: run, in: project)
        run.conflictTarget = nil
        guard verdict.approved == true else {
            if let limit = run.maxRounds, run.round >= limit {
                run.lastNotes = verdict.notes
                stop(run, "Tur sınırı doldu (\(limit)); hâlâ değişiklik isteniyor", in: project, continuation: .moreRounds)
                return
            }
            run.nextRound(notes: verdict.notes)
            logRun(run.cardID, in: project, .round, Self.roundText(run) + ": istenen değişiklikler geliştiriciye gitti")
            guard let developer = run.developerTab.flatMap({ claudeTab($0)?.session }), developer.agent?.state != .ended else {
                // Its session didn't come back after a restart: a new developer gets the plan and the notes.
                await startDeveloper(run, in: project)
                return
            }
            sendPrompt(Self.feedbackPrompt(verdict.notes, round: run.round, of: run.maxRounds), to: developer)
            return
        }

        guard let root = project.git.root, let card = project.board.cards.first(where: { $0.id == run.cardID }) else { return }
        run.set(.merging)
        // Worked out first, so a conflict never touches the user's checkout.
        let conflicts = await Worktrees.conflicts(merging: run.branch, root: root)
        if let conflicts, !conflicts.isEmpty {
            await askToResolve(conflicts, of: run, in: project, root: root)
            return
        }
        do {
            try await Worktrees.merge(branch: run.branch, root: root)
        } catch {
            await project.git.refresh()
            if conflicts == nil, error.localizedDescription.contains("CONFLICT") {
                await askToResolve([], of: run, in: project, root: root) // git could not tell beforehand
            } else {
                let why = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? ""
                stop(run, "Birleştirilemedi; dal ve worktree duruyor" + (why.isEmpty ? "" : " (\(why))"), in: project)
            }
            return
        }
        orchestraRuns[run.cardID] = nil
        await finishWorktree(of: card, in: project, closing: worktreeTabs(of: card, in: project), force: false)
        project.board.move(card.id, to: .done)
        logRun(card.id, in: project, .merged, "Birleştirildi" + (project.git.status.branch.map { " → \($0)" } ?? ""))
        Notifier.shared.post(title: "\(project.name) · Birleştirildi", body: card.title, tabID: card.id)
        let pushed: Bool? = project.orchestraTeam.pushesAfterMerge ? await pushMerge(of: card, in: project, root: root) : nil
        announceMerge(of: card, rounds: run.round, pushed: pushed, in: project)
        queueCardFinished(card.id, merged: true, in: project)
    }

    /// "Birleşince push'la": the merge goes to the remote too. One the remote won't take is
    /// reported and stays local; the queue goes on.
    private func pushMerge(of card: BoardCard, in project: Project, root: URL) async -> Bool {
        defer { Task { await project.git.refresh() } }
        do {
            try await Git.push(in: root)
            logRun(card.id, in: project, .pushed, "Push'landı" + (project.git.status.branch.map { " → \($0)" } ?? ""))
            return true
        } catch {
            let message = error.localizedDescription
            logRun(card.id, in: project, .pushFailed, "Push edilemedi; birleştirme yerelde duruyor",
                   detail: message.split(separator: "\n").prefix(6).joined(separator: "\n"))
            Notifier.shared.post(
                title: "\(project.name) · Push edilemedi", body: "\(card.title) · \(Self.pushFailureReason(message))", tabID: card.id
            )
            return false
        }
    }

    /// The line of git's output that says why a push failed.
    static func pushFailureReason(_ message: String) -> String {
        let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let telling = lines.first { $0.contains("[rejected]") || $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        return telling ?? lines.first ?? "bilinmeyen bir hata"
    }

    /// Reviewers run commands in the developer's worktree (builds, tests). Whatever they changed
    /// there (tracked files, new files git doesn't ignore, commits) goes, so what merges or goes back
    /// to the developer is the branch that was reviewed. Build output git ignores stays.
    func undoReviewChanges(of run: OrchestraRun, in project: Project) async {
        guard let reviewed = run.reviewedHead else { return }
        let head = (try? await Git.run(["rev-parse", "HEAD"], in: run.worktree).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? reviewed
        let status = (try? await Git.run(["status", "--porcelain"], in: run.worktree).lines) ?? []
        guard head != reviewed || !status.isEmpty else { return }
        var changed = status.map { String($0.dropFirst(3)) }
        if head != reviewed { changed.insert("commit \(String(head.prefix(7)))", at: 0) }
        _ = try? await Git.run(["reset", "--hard", reviewed], in: run.worktree)
        _ = try? await Git.run(["clean", "-fd"], in: run.worktree)
        logRun(run.cardID, in: project, .note, "Gözden geçirenlerin worktree'de bıraktığı değişiklikler geri alındı",
               detail: changed.prefix(10).joined(separator: "\n") + (changed.count > 10 ? "\n…" : ""))
    }

    /// Conflicting merges the developer is asked to resolve before the orchestra stops.
    static let maxConflictAttempts = 2

    /// The approved branch would conflict with the project's: the developer merges the project's
    /// branch in, resolves, commits, and the review looks again.
    private func askToResolve(_ files: [String], of run: OrchestraRun, in project: Project, root: URL) async {
        guard run.conflictAttempts < Self.maxConflictAttempts else {
            stop(run, "Birleştirme yine çakıştı" + (files.isEmpty ? "" : " (\(files.joined(separator: ", ")))") + "; dal ve worktree duruyor", in: project)
            return
        }
        guard let developer = run.developerTab.flatMap({ claudeTab($0)?.session }), developer.agent?.state != .ended else {
            stop(run, "Birleştirme çakıştı ve geliştiricinin oturumu kapalı", in: project)
            return
        }
        // A detached checkout has no branch name; its commit does as well.
        var target = project.git.status.branch ?? "HEAD"
        if project.git.status.branch == nil, let commit = try? await Git.run(["rev-parse", "HEAD"], in: root) {
            target = commit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        run.conflictAttempts += 1
        run.conflictTarget = target
        run.reminded = []
        run.set(.developing)
        logRun(run.cardID, in: project, .conflict,
               "Birleştirme \(target) ile çakıştı; geliştirici çözüyor (deneme \(run.conflictAttempts)/\(Self.maxConflictAttempts))",
               detail: files.joined(separator: "\n"))
        sendPrompt(Self.conflictPrompt(target: target, files: files), to: developer)
    }

    /// The run waits for the user. `needsAnswers`: the planner asked questions; the card waits for
    /// them, which doesn't count against the queue.
    /// `continuation`: the limit it stopped on, which "Devam Et" can lift.
    private func stop(_ run: OrchestraRun, _ reason: String, in project: Project, needsAnswers: Bool = false,
                      continuation: OrchestraRun.Continuation? = nil) {
        closeStepTabs(of: run, in: project)
        run.continuation = continuation
        run.set(.needsUser(reason))
        logRun(run.cardID, in: project, needsAnswers ? .blocked : .stopped, reason,
               detail: needsAnswers ? project.board.cards.first { $0.id == run.cardID }?.run?.plan?.questions.map { "- \($0)" }.joined(separator: "\n") : nil)
        let card = project.board.cards.first { $0.id == run.cardID }
        Notifier.shared.post(
            title: "\(project.name) · " + (needsAnswers ? "Bilgi gerekiyor" : "Orkestra durdu"),
            body: [card?.title, reason].compactMap { $0 }.joined(separator: " · "),
            tabID: run.cardID // opens the run's page
        )
        if let card { announceStop(of: card, reason: reason, needsAnswers: needsAnswers, in: project) }
        queueCardFinished(run.cardID, merged: false, countsAsStuck: !needsAnswers, in: project)
    }

    private func closeStepTabs(of run: OrchestraRun, in project: Project) {
        for tab in run.stepTabs {
            guard let (session, _) = claudeTab(tab) else { continue }
            session.terminate()
            removeTab(tab, from: project)
        }
    }

    // MARK: Restart

    /// What a run saved in `phase` does next when Tezgah opens again. The agents' turns were cut
    /// off at quit: a developer with nothing committed since is told to go on; a review is done
    /// again; a merge is finished.
    enum ResumeStep: Equatable {
        case wait, plan, review, remindDeveloper, merge
    }

    static func resumeStep(for phase: OrchestraRun.Phase, hasNewCommits: Bool, isClean: Bool) -> ResumeStep {
        switch phase {
        case .needsUser, .merged: .wait
        case .planning: .plan
        case .merging: .merge
        case .reviewing, .judging: .review
        case .developing: hasNewCommits && isClean ? .review : .remindDeveloper
        }
    }

    static func conflictPrompt(target: String, files: [String]) -> String {
        let place = files.isEmpty ? "çakışıyor" : "şu dosyalarda çakışıyor: \(files.joined(separator: ", "))"
        return """
        İşin onaylandı, ama ana dal (`\(target)`) bu dal açıldığından beri ilerledi ve birleştirme \(place).
        `git merge \(target)` ile ana dalı bu dala birleştir, çakışmaları iki tarafın amacını da koruyarak çöz, \
        testleri çalıştır ve commit'le. Ardından iş yeniden gözden geçirilip birleştirilecek.
        """
    }

    static let resumePrompt = "Tezgah yeniden açıldı ve yarım kalan turun kesildi. İşe kaldığın yerden devam et; bitince değişiklikleri bu dalda commit'le."

    /// Picks up runs saved at quit, once their agents' tabs are back.
    func resumeOrchestraRuns(_ saved: [SavedOrchestraRun], in project: Project, tabs: [String: UUID]) {
        for item in saved where project.board.cards.contains(where: { $0.id == item.cardID }) {
            let run = OrchestraRun(saved: item)
            run.developerTab = item.developerSession.flatMap { tabs[$0] }
            orchestraRuns[item.cardID] = run
            Task { await continueRun(run, in: project) }
        }
    }

    private func continueRun(_ run: OrchestraRun, in project: Project) async {
        if case .needsUser = run.phase { return }
        guard FileManager.default.fileExists(atPath: run.worktree.path) else {
            stop(run, "Worktree bulunamadı", in: project)
            return
        }
        let head = (try? await Git.run(["rev-parse", "HEAD"], in: run.worktree).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let isClean = (try? await Worktrees.hasUncommittedChanges(at: run.worktree)) == false
        let hasNewCommits = !head.isEmpty && head != (run.reviewedHead ?? run.base)
        let step = Self.resumeStep(for: run.phase, hasNewCommits: hasNewCommits, isClean: isClean)
        if step != .wait {
            logRun(run.cardID, in: project, .resumed, "Tezgah yeniden açıldı; koşu kaldığı yerden sürüyor")
        }
        switch step {
        case .wait:
            break
        case .plan:
            await startPlanning(run, in: project) // the planner's tab doesn't come back
        case .review:
            if run.phase == .developing { run.reviewedHead = head }
            await startReview(of: run, in: project)
        case .remindDeveloper:
            if let developer = run.developerTab.flatMap({ claudeTab($0)?.session }) {
                run.set(.developing)
                sendWhenReady(Self.resumePrompt, to: developer)
            } else if !hasNewCommits, isClean {
                // Tezgah closed while the developer was still starting: with nothing done on the
                // branch there is nothing to lose, so a new one takes over.
                logRun(run.cardID, in: project, .note, "Geliştiricinin oturumu geri gelmedi; yeni bir geliştirici başlıyor")
                await startDeveloper(run, in: project)
            } else {
                stop(run, "Geliştiricinin oturumu geri gelmedi; worktree'de yarım iş var", in: project)
            }
        case .merge:
            await finishRound(of: run, with: OrchestraRun.Verdict(approved: true, notes: ""), in: project)
        }
    }

    /// Like `sendPrompt`, for an agent that may still be starting: Claude's composer waits by
    /// itself, Codex's terminal must show its UI first.
    func sendWhenReady(_ prompt: String, to session: TerminalSession) {
        guard session.claude == nil else {
            sendPrompt(prompt, to: session)
            return
        }
        Task { [weak self, weak session] in
            for _ in 0..<120 where session?.agent?.state == .starting {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(1)) // its prompt draws a moment after the title
            guard let self, let session, session.agent?.state != .ended else { return }
            sendPrompt(prompt, to: session)
        }
    }

    // MARK: Agents

    /// Starts a member's agent in a tab next to the others, without bringing it to the front.
    /// `asksQuestions: false` is for the orchestra's agents, who have nobody to answer them.
    func launchAgent(
        _ member: OrchestraTeam.Member, in project: Project, directory: URL, prompt: String, readOnly: Bool,
        asksQuestions: Bool = true
    ) async -> TerminalSession? {
        let session: TerminalSession
        switch member.provider {
        case .claude:
            guard let claudePath = await Self.findClaude() else { return nil }
            session = await makeClaudeSession(
                in: project, launch: .new, claudePath: claudePath, directory: directory, model: member.model, effort: member.effort,
                readOnly: readOnly, asksQuestions: asksQuestions
            )
            session.claude?.composer.text = prompt
            session.sendComposerDraft()
        case .codex:
            guard let codexPath = await Self.findCodex() else { return nil }
            session = await makeCodexSession(
                in: project, launch: .new, codexPath: codexPath, directory: directory, prompt: prompt,
                model: member.model, effort: member.effort, readOnly: readOnly
            )
        }
        project.tabs.append(.terminal(session))
        return session
    }

    /// Gives an agent its next prompt.
    func sendPrompt(_ prompt: String, to session: TerminalSession) {
        if let claude = session.claude {
            claude.composer.text = prompt
            session.sendComposerDraft()
        } else {
            session.submitPrompt(prompt)
        }
    }

    // MARK: Prompts

    /// The card for the planner: understand it, look through the code, plan, add what makes the
    /// idea better without growing it into another job.
    static func plannerPrompt(card: BoardCard) -> String {
        """
        Bir planlayıcısın. Aşağıdaki işi kodu yazacak geliştirici için planla. Kod yazmıyorsun: \
        hiçbir dosyayı değiştirme, commit atma.

        \(taskText(card))

        1. İşi anla: kart ne istiyor, bu projede ne anlama geliyor. Kodu tara; ilgili dosyaları, \
        mevcut yapıyı, benzer örnekleri ve testleri bul.
        2. Yaklaşımı çıkar: hangi adımlar, hangi dosyalar ve katmanlar (veri, sunucu, arayüz, testler).
        3. “Bitti” ölçütlerini yaz: gözden geçirenlerin tek tek kontrol edebileceği somut maddeler, \
        testler dahil. Her birini kodda doğrula:
           - Ölçütte geçen her ekranın, bileşenin, sütunun, uç noktanın ve davranışın kodda gerçekten \
        var olduğunu dosyayı açıp gör; görmediğin bir şey için ölçüt yazma.
           - Kapsamla çelişen ölçüt yazma: bir katmana dokunulmayacaksa o katmanda değişiklik \
        gerektiren bir ölçüt olamaz.
           - Her ölçütün sonuna nasıl kontrol edileceğini yaz: koda bakarak, testle ya da çalıştırarak \
        (hangi komutla).
        4. Fikre katkı ara: işi daha iyi yapacak küçük ve doğrudan ilgili iyileştirmeleri plana kat \
        (included_ideas). Kapsamı büyüten, kendi başına bir iş sayılacak fikirleri bu karta katma; \
        separate_ideas olarak öner, onlara kullanıcı karar verecek.

        Soru sorabileceğin kimse yok; küçük belirsizliklerde en makul yorumu seç ve özette belirt. \
        Ama kart bu haliyle yapılamıyorsa, ne istendiği anlaşılmıyorsa ya da kullanıcının vermesi \
        gereken bir bilgi, erişim ya da karar eksikse tahminle plan yazma: `plan_ready`'yi `blocked` \
        (nedeni) ve `questions` (kullanıcıya soruların, tek tek) ile çağır. Kart, kullanıcı cevaplayana \
        kadar bekler.

        Bitirince Tezgah'ın `plan_ready` aracını çağır.
        """
    }

    static let planReminder = "Planını Tezgah'ın plan_ready aracıyla bildir: summary, approach, done_criteria; varsa included_ideas ve separate_ideas."

    /// The card for the developer, who can't stop to ask: the run goes on when its turn ends. With
    /// the plan to follow, and what the last review asked for when it takes over a later round.
    static func developerPrompt(for card: BoardCard, branch: String, plan: BoardCard.RunPlan? = nil, notes: String? = nil) -> String {
        var parts = [worktreePrompt(for: card, branch: branch)]
        if let plan {
            parts.append(plan.promptText)
            parts.append("""
            Planı uygula ve “bitti” ölçütlerinin hepsini karşıla. Planda yanlış ya da eksik gördüğün bir \
            yer olursa makul olanı yap ve commit mesajında belirt. Bir ölçüt yanlışsa ya da uygulanamıyorsa \
            ona “karşılandı” deme; commit mesajında “Ölçüt N uygulanamaz: neden” diye açıkça yaz.
            """)
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append("Bu dalda önceki bir geliştirici çalıştı; son gözden geçirmede şunlar istendi, bunları uygula:\n\n\(notes)")
        }
        parts.append("""
        Bu işte soru sorabileceğin kimse yok; cevap beklersen iş durur. Belirsiz kalan bir yerde en \
        makul olanı seç ve devam et, yaptığın varsayımları commit mesajına yaz.
        """)
        return parts.joined(separator: "\n\n")
    }

    static let commitReminder = "Commit'lenmemiş değişiklikler var. Onları bu dalda commit'le, sonra bitir."
    static let verdictReminder = "Kararını Tezgah'ın review_verdict aracıyla bildir: decision \"approve\" ya da \"request_changes\", notes alanında gerekçen."

    static func reviewPrompt(card: BoardCard?, run: OrchestraRun, member: OrchestraTeam.Member, number: Int) -> String {
        var lines = [
            "Bir gözden geçiricisin. Aşağıdaki iş için `\(run.branch)` dalında yapılanları incele.",
            "",
            taskText(card),
        ]
        lines += planCheck(card)
        lines += [
            "",
            "Değişiklikler: `git log --oneline \(run.base)..HEAD` ve `git diff \(run.base)..HEAD`. Gerekirse dosyaları oku; build, vet ve testleri çalıştırabilirsin. Kaynak dosyalarını değiştirme, commit atma; worktree'de bıraktığın değişiklikler gözden geçirme bitince geri alınır.",
        ]
        let focus = member.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !focus.isEmpty {
            lines.append("Özellikle şuna bak: \(focus)")
        }
        if let target = run.conflictTarget {
            lines.append("Geliştirici bu turda `\(target)` dalını bu dala birleştirip çakışmaları çözdü; çözümün iki tarafın amacını da koruduğuna özellikle bak.")
        }
        lines += [
            "",
            "İncelemeyi bitirince Tezgah'ın `review_verdict` aracını çağır: iş tamam ve doğruysa decision \"approve\"; değişiklik gerekiyorsa \"request_changes\" ve notes alanına geliştiricinin uygulayabileceği somut maddeler yaz.",
        ]
        return lines.joined(separator: "\n")
    }

    static func judgePrompt(
        card: BoardCard?, run: OrchestraRun, reviews: [(member: OrchestraTeam.Member, verdict: OrchestraRun.Verdict?)]
    ) -> String {
        var lines = [
            "Karar vericisin. `\(run.branch)` dalındaki iş için \(reviews.count) gözden geçirici değerlendirme yaptı.",
            "",
            taskText(card),
        ]
        lines += planCheck(card)
        for (index, review) in reviews.enumerated() {
            let focus = review.member.focus.trimmingCharacters(in: .whitespacesAndNewlines)
            let decision = switch review.verdict?.approved {
            case true: "Onaylıyor"
            case false: "Değişiklik istiyor"
            default: "Karar bildirmedi"
            }
            lines += [
                "",
                "### \(index + 1). \(review.member.title)" + (focus.isEmpty ? "" : " · odak: \(focus)"),
                "Karar: \(decision)",
            ]
            let notes = review.verdict?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !notes.isEmpty { lines.append(notes) }
        }
        lines += [
            "",
            "Değerlendirmeleri tart; gerekirse `git diff \(run.base)..HEAD` ile kendin bak. Dosyaları değiştirme. Son kararı Tezgah'ın `review_verdict` aracıyla ver: \"approve\" ya da \"request_changes\"; request_changes ise notes alanına geliştiriciye gidecek birleşik, tekrarsız ve net bir liste yaz.",
        ]
        return lines.joined(separator: "\n")
    }

    static func feedbackPrompt(_ notes: String, round: Int, of rounds: Int?) -> String {
        """
        Gözden geçirme sonucu değişiklik istendi (tur \(round)\(rounds.map { "/\($0)" } ?? "")):

        \(notes.trimmingCharacters(in: .whitespacesAndNewlines))

        Bunları uygula ve aynı dalda commit'le.
        """
    }

    /// What the plan promised, for those who check the work.
    private static func planCheck(_ card: BoardCard?) -> [String] {
        guard let plan = card?.run?.plan, !plan.doneCriteria.isEmpty || !plan.includedIdeas.isEmpty else { return [] }
        var lines = [""]
        if !plan.doneCriteria.isEmpty {
            lines.append("Planlayıcının belirlediği “bitti” ölçütleri; her birinin karşılandığını kontrol et, karşılanmayanı değişiklik olarak iste. Geliştiricinin gerekçesiyle “uygulanamaz” dediği bir ölçütü, gerekçe doğruysa engel sayma; yanlışsa değişiklik iste:")
            lines += plan.doneCriteria.map { "- \($0)" }
        }
        if !plan.includedIdeas.isEmpty {
            lines.append("Plana göre bu işe şunlar da dahil:")
            lines += plan.includedIdeas.map { "- \($0)" }
        }
        return lines
    }

    private static func taskText(_ card: BoardCard?) -> String {
        guard let card else { return "İş: (kart silinmiş)" }
        let notes = card.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return "İş: \(card.title)" + (notes.isEmpty ? "" : "\n\(notes)")
    }
}
