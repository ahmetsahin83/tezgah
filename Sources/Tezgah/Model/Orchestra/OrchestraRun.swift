import Foundation
import Observation

/// One card going through the orchestra: the developer works on its branch, the reviewers look
/// at what changed, the judge decides; changes asked for go back to the developer, an approval
/// is merged. Lives while Tezgah runs; after a restart the card keeps its worktree for the
/// board's own actions.
@MainActor
@Observable
final class OrchestraRun {
    enum Phase: Codable, Equatable {
        /// The planner reads the card and the code and writes the plan.
        case planning
        case developing
        case reviewing
        case judging
        case merging
        case merged
        /// Stopped until the user looks; the reason says why. A developer that finishes again
        /// with commits picks the run up where it left off.
        case needsUser(String)
    }

    /// How "Devam Et" takes a stopped run on: more rounds after the round limit, or the step
    /// again after its time limit.
    enum Continuation: Codable, Equatable {
        case moreRounds
        case moreTime(RunStage)
    }

    struct Verdict: Equatable {
        /// nil: the reviewer finished without giving one.
        let approved: Bool?
        let notes: String
    }

    let cardID: UUID
    let team: OrchestraTeam
    let branch: String
    let worktree: URL
    /// Where the agents work: the worktree, or the project's sub-folder in it.
    let directory: URL
    /// The commit the branch started from; reviews look at what came after it. After the
    /// developer merges the project's branch in to resolve a conflict, its tip.
    var base: String
    private(set) var phase = Phase.developing {
        didSet { phaseStartedAt = .now }
    }
    /// When the run got where it is, for the step's time limit. After a restart the step starts over.
    private(set) var phaseStartedAt = Date()
    private(set) var round = 1
    var developerTab: UUID?
    /// While planning: the planner's tab.
    var plannerTab: UUID?
    /// This round's reviewers by tab, and the verdicts they gave.
    private(set) var reviewers: [UUID: OrchestraTeam.Member] = [:]
    private(set) var verdicts: [UUID: Verdict] = [:]
    private(set) var judgeTab: UUID?
    /// Reviewers are still being started; their verdicts wait until all are in.
    private(set) var isLaunchingReviewers = false
    /// The commit last sent to review, so a round without new commits is noticed.
    var reviewedHead: String?
    /// What the last review asked for, shown when the run stops.
    var lastNotes: String?
    /// Times the developer was asked to resolve a conflicting merge.
    var conflictAttempts = 0
    /// Rounds added on top of the team's limit (kept from runs that saved them).
    var extraRounds = 0
    /// "Devam Et" took the run on: rounds aren't counted against a limit any more.
    var ignoresRoundLimit = false
    /// Set while stopped on a limit, so "Devam Et" knows what to take on.
    var continuation: Continuation?

    /// The rounds this run may take; nil when there is no limit (the team's 0, or after "Devam Et").
    var maxRounds: Int? {
        team.maxRounds == 0 || ignoresRoundLimit ? nil : team.maxRounds + extraRounds
    }
    /// While the developer resolves a conflict: the branch it merges in. The review after it looks
    /// at the resolution in particular.
    var conflictTarget: String?
    /// Tabs already reminded once this round (to commit, to give a verdict).
    @ObservationIgnored var reminded: Set<UUID> = []
    /// The last turn of each tab the run acted on, so a turn is handled once.
    @ObservationIgnored var handledTurns: [UUID: Date] = [:]

    init(cardID: UUID, team: OrchestraTeam, branch: String, worktree: URL, directory: URL, base: String) {
        self.cardID = cardID
        self.team = team
        self.branch = branch
        self.worktree = worktree
        self.directory = directory
        self.base = base
    }

    /// A run saved when Tezgah quit; `developerTab` is for the caller to find again.
    convenience init(saved: SavedOrchestraRun) {
        self.init(
            cardID: saved.cardID, team: saved.team, branch: saved.branch,
            worktree: URL(fileURLWithPath: saved.worktree, isDirectory: true),
            directory: URL(fileURLWithPath: saved.directory, isDirectory: true), base: saved.base
        )
        phase = saved.phase
        round = saved.round
        reviewedHead = saved.reviewedHead
        lastNotes = saved.lastNotes
        conflictAttempts = saved.conflictAttempts ?? 0
        conflictTarget = saved.conflictTarget
        extraRounds = saved.extraRounds ?? 0
        ignoresRoundLimit = saved.ignoresRoundLimit ?? false
        continuation = saved.continuation
        // Stopped on the round limit before "Devam Et" was kept: the reason still tells.
        if continuation == nil, case .needsUser(let reason) = phase, reason.hasPrefix("Tur sınırı doldu") {
            continuation = .moreRounds
        }
    }

    /// What to save, with the developer named by its session id. A review is saved as about to
    /// start: its agents don't come back, the round is done again.
    func saved(developerSession: String?) -> SavedOrchestraRun {
        SavedOrchestraRun(
            cardID: cardID, team: team, branch: branch, worktree: worktree.path, directory: directory.path, base: base,
            phase: phase == .judging ? .reviewing : phase, round: round, reviewedHead: reviewedHead, lastNotes: lastNotes,
            developerSession: developerSession, conflictAttempts: conflictAttempts == 0 ? nil : conflictAttempts,
            conflictTarget: conflictTarget, extraRounds: extraRounds == 0 ? nil : extraRounds,
            ignoresRoundLimit: ignoresRoundLimit ? true : nil, continuation: continuation
        )
    }

    var isActive: Bool {
        switch phase {
        case .merged, .needsUser: false
        default: true
        }
    }

    /// Tabs that don't outlive their step: the planner, this round's reviewers and the judge.
    /// They close when it's over and aren't saved; after a restart the step is done again.
    var stepTabs: [UUID] { Array(reviewers.keys) + [judgeTab, plannerTab].compactMap { $0 } }

    func contains(_ tab: UUID) -> Bool {
        tab == developerTab || reviewers[tab] != nil || tab == judgeTab || tab == plannerTab
    }

    func set(_ phase: Phase) {
        self.phase = phase
    }

    func startReview() {
        reviewers = [:]
        verdicts = [:]
        judgeTab = nil
        isLaunchingReviewers = true
        phase = .reviewing
    }

    func addReviewer(_ member: OrchestraTeam.Member, in tab: UUID) {
        reviewers[tab] = member
    }

    func reviewersStarted() {
        isLaunchingReviewers = false
    }

    /// Every reviewer has had its say.
    var reviewsAreIn: Bool {
        phase == .reviewing && !isLaunchingReviewers && !reviewers.isEmpty && verdicts.count == reviewers.count
    }

    func record(_ verdict: Verdict, from tab: UUID) {
        verdicts[tab] = verdict
    }

    func startJudging(in tab: UUID) {
        judgeTab = tab
        phase = .judging
    }

    /// Changes were asked for: the developer's turn again.
    func nextRound(notes: String) {
        lastNotes = notes
        round += 1
        reviewers = [:]
        verdicts = [:]
        judgeTab = nil
        reminded = []
        phase = .developing
    }

    /// For the card: where the run is.
    var summary: String {
        let rounds = "tur \(round)" + (maxRounds.map { "/\($0)" } ?? "")
        return switch phase {
        case .planning: "Planlanıyor"
        case .developing: (conflictTarget == nil ? "Geliştiriliyor" : "Çakışma çözülüyor") + " · \(rounds)"
        case .reviewing: "Gözden geçiriliyor (\(verdicts.count)/\(reviewers.count)) · \(rounds)"
        case .judging: "Karar veriliyor · \(rounds)"
        case .merging: "Birleştiriliyor"
        case .merged: "Birleştirildi"
        case .needsUser(let reason): reason
        }
    }
}
