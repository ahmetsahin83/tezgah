import Foundation
import Observation

extension BoardCard {
    /// What the orchestra did on the card. Kept on the card after the run, so a finished card
    /// still tells how it was done.
    struct RunRecord: Codable, Equatable, Sendable {
        var team: OrchestraTeam
        var branch: String
        var startedAt = Date()
        /// Merged or stopped; nil while the run goes on.
        var endedAt: Date?
        var commits = 0
        var events: [RunEvent] = []
        /// The planner's plan, once it gave one.
        var plan: RunPlan?

        /// Why the run stopped, while it stays stopped. An agent's query after the stop doesn't change it.
        var stopReason: String? {
            guard endedAt != nil, let last = events.last(where: { $0.kind != .query }),
                  last.kind == .stopped || last.kind == .blocked else { return nil }
            return last.text
        }

        /// Stopped on the planner's questions, waiting for the user's answers.
        var isWaitingForAnswers: Bool {
            stopReason != nil && events.last(where: { $0.kind != .query })?.kind == .blocked && plan?.blocked != nil
        }

        /// A push after the merge doesn't change that it merged.
        var isMerged: Bool {
            endedAt != nil && events.last { $0.kind != .pushed && $0.kind != .pushFailed }?.kind == .merged
        }
    }

    /// The planner's plan: handed to the developer, and what the reviewers check the work against.
    struct RunPlan: Codable, Equatable, Sendable {
        /// A bigger idea the planner had; never done in this card, the user may put it on the board.
        struct Idea: Codable, Equatable, Identifiable, Sendable {
            var id = UUID()
            var title: String
            var detail = ""
            var isOnBoard = false
        }

        /// What the work is, as the planner understood it.
        var summary: String
        /// The steps and the places in the code to touch.
        var approach = ""
        /// Checkable conditions for the work to count as done.
        var doneCriteria: [String] = []
        /// Small, closely related improvements done in this card too.
        var includedIdeas: [String] = []
        var separateIdeas: [Idea] = []
        /// Set when the card can't go on without the user: why, and what to answer.
        var blocked: String?
        var questions: [String] = []

        init(
            summary: String, approach: String = "", doneCriteria: [String] = [], includedIdeas: [String] = [],
            separateIdeas: [Idea] = [], blocked: String? = nil, questions: [String] = []
        ) {
            self.summary = summary
            self.approach = approach
            self.doneCriteria = doneCriteria
            self.includedIdeas = includedIdeas
            self.separateIdeas = separateIdeas
            self.blocked = blocked
            self.questions = questions
        }

        /// Fields added later fall back to their defaults instead of failing the whole board.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            approach = try container.decodeIfPresent(String.self, forKey: .approach) ?? ""
            doneCriteria = try container.decodeIfPresent([String].self, forKey: .doneCriteria) ?? []
            includedIdeas = try container.decodeIfPresent([String].self, forKey: .includedIdeas) ?? []
            separateIdeas = try container.decodeIfPresent([Idea].self, forKey: .separateIdeas) ?? []
            blocked = try container.decodeIfPresent(String.self, forKey: .blocked)
            questions = try container.decodeIfPresent([String].self, forKey: .questions) ?? []
        }

        /// The plan as the developer and the reviewers read it.
        var promptText: String {
            var parts = ["## Plan", summary]
            if !approach.isEmpty { parts += ["### Yaklaşım", approach] }
            if !doneCriteria.isEmpty { parts += ["### “Bitti” ölçütleri", doneCriteria.map { "- \($0)" }.joined(separator: "\n")] }
            if !includedIdeas.isEmpty { parts += ["### Bu işe dahil edilen katkılar", includedIdeas.map { "- \($0)" }.joined(separator: "\n")] }
            return parts.joined(separator: "\n\n")
        }
    }

    /// One step of a run, for the run page's "Akış".
    struct RunEvent: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case planning, planned
            /// The planner found the card can't go on without the user.
            case blocked
            case started, commits, reminder, review, approved, changesRequested, silent, judging, round, conflict, merged, pushed, pushFailed
            case stopped, resumed, note
            /// An agent's database query, with what came of it.
            case query

            /// A kind a newer Tezgah wrote reads as a plain note instead of failing the whole board.
            init(from decoder: Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .note
            }
        }

        var id = UUID()
        var date = Date()
        var kind: Kind
        var text: String
        /// Notes or commit subjects, shown under the text.
        var detail: String?
    }
}

/// A card's orchestra run on a page of its own. The tab's id is the card's, so a notification
/// about the card can open it.
@MainActor
@Observable
final class RunPage {
    let cardID: UUID
    let board: ProjectBoard

    init(cardID: UUID, board: ProjectBoard) {
        self.cardID = cardID
        self.board = board
    }

    var card: BoardCard? { board.cards.first { $0.id == cardID } }
}

/// The steps a run goes through, as its page shows them.
enum RunStage: Int, CaseIterable, Comparable, Codable, Sendable {
    case plan, develop, review, judge, merge

    var title: String {
        switch self {
        case .plan: "Planlama"
        case .develop: "Geliştirme"
        case .review: "Gözden geçirme"
        case .judge: "Karar"
        case .merge: "Birleştirme"
        }
    }

    /// The team's steps: no plan when it doesn't plan, no review without reviewers, no judge for a single one.
    static func stages(for team: OrchestraTeam) -> [RunStage] {
        allCases.filter { stage in
            switch stage {
            case .plan: team.plans
            case .review: !team.reviewers.isEmpty
            case .judge: team.reviewers.count > 1
            default: true
            }
        }
    }

    /// Where a running run is; nil once it merged or stopped.
    static func current(_ phase: OrchestraRun.Phase) -> RunStage? {
        switch phase {
        case .planning: .plan
        case .developing: .develop
        case .reviewing: .review
        case .judging: .judge
        case .merging: .merge
        case .merged, .needsUser: nil
        }
    }

    /// Where a run that is over got to, read from its last steps.
    static func reached(_ events: [BoardCard.RunEvent]) -> RunStage {
        for event in events.reversed() {
            switch event.kind {
            case .merged, .pushed, .pushFailed: return .merge
            case .judging: return .judge
            case .review, .approved, .changesRequested, .silent: return .review
            case .started, .commits, .reminder, .round, .conflict, .resumed: return .develop
            case .planning, .planned, .blocked: return .plan
            case .stopped, .note, .query: continue
            }
        }
        return .develop
    }

    static func < (lhs: RunStage, rhs: RunStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension ProjectBoard {
    /// Starts the card's run record; a card run again keeps what happened before.
    func beginRun(on id: BoardCard.ID, team: OrchestraTeam, branch: String) {
        guard var card = cards.first(where: { $0.id == id }) else { return }
        var record = card.run ?? BoardCard.RunRecord(team: team, branch: branch)
        record.team = team
        record.branch = branch
        record.startedAt = .now
        record.endedAt = nil
        record.plan = nil // a new run plans again
        card.run = record
        update(card)
    }

    func setPlan(_ plan: BoardCard.RunPlan, on id: BoardCard.ID) {
        guard var card = cards.first(where: { $0.id == id }), card.run != nil else { return }
        card.run?.plan = plan
        update(card)
    }

    /// One of a plan's separate ideas becomes a card of its own, at the end of "Yapılacak" so it
    /// doesn't jump ahead of what was already lined up.
    @discardableResult
    func addIdea(_ ideaID: UUID, from id: BoardCard.ID) -> BoardCard? {
        guard var card = cards.first(where: { $0.id == id }),
              let index = card.run?.plan?.separateIdeas.firstIndex(where: { $0.id == ideaID }),
              let idea = card.run?.plan?.separateIdeas[index], !idea.isOnBoard else { return nil }
        let notes = [idea.detail, "(“\(card.title)” kartının planından)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard let added = add(idea.title, notes: notes, to: .todo) else { return nil }
        move(added.id, to: .todo)
        card.run?.plan?.separateIdeas[index].isOnBoard = true
        update(card)
        return added
    }

    /// Adds a step to the card's run; a merge or a stop (questions included) ends it.
    func logRun(on id: BoardCard.ID, _ event: BoardCard.RunEvent, commits: Int = 0) {
        guard var card = cards.first(where: { $0.id == id }), var record = card.run else { return }
        record.events.append(event)
        record.commits += commits
        switch event.kind {
        case .merged, .stopped, .blocked: record.endedAt = event.date
        case .resumed: record.endedAt = nil
        default: break
        }
        card.run = record
        update(card)
    }
}
