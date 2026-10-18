import Foundation
import Observation

/// One note on a project's board.
struct BoardCard: Codable, Identifiable, Equatable, Sendable {
    enum Column: String, Codable, CaseIterable, Sendable {
        case todo, doing, done

        var title: String {
            switch self {
            case .todo: "Yapılacak"
            case .doing: "Yapılıyor"
            case .done: "Bitti"
            }
        }
    }

    /// The git worktree an agent works on the card in.
    struct Worktree: Codable, Equatable, Sendable {
        var branch: String
        var path: String
    }

    var id = UUID()
    var title: String
    var notes = ""
    var column = Column.todo
    var createdAt = Date()
    var completedAt: Date?
    var worktree: Worktree?
    /// What the orchestra did on the card, if it ran it.
    var run: RunRecord?
}

/// A project's to-do board: notes in three columns, kept in Tezgah's own state (not in the repo).
@MainActor
@Observable
final class ProjectBoard: Identifiable {
    let id = UUID()
    /// In display order within each column.
    private(set) var cards: [BoardCard] = []
    /// Saves the workspace after every change.
    @ObservationIgnored var onChange: (() -> Void)?

    init(cards: [BoardCard] = []) {
        self.cards = cards
    }

    /// Cards read back from the saved workspace; not a change worth saving.
    func restore(_ cards: [BoardCard]) {
        self.cards = cards
    }

    func cards(in column: BoardCard.Column) -> [BoardCard] {
        cards.filter { $0.column == column }
    }

    var openCount: Int { cards.filter { $0.column != .done }.count }

    @discardableResult
    func add(_ title: String, notes: String = "", to column: BoardCard.Column = .todo) -> BoardCard? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var card = BoardCard(title: title, notes: notes, column: column)
        if column == .done { card.completedAt = .now }
        // New cards go on top of their column.
        let index = cards.firstIndex { $0.column == column } ?? cards.endIndex
        cards.insert(card, at: index)
        onChange?()
        return card
    }

    func update(_ card: BoardCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        var card = card
        card.title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !card.title.isEmpty, cards[index] != card else { return }
        cards[index] = card
        onChange?()
    }

    func remove(_ id: BoardCard.ID) {
        cards.removeAll { $0.id == id }
        onChange?()
    }

    /// Moves a card to a column, before `target` (a card in that column) or at the end.
    func move(_ id: BoardCard.ID, to column: BoardCard.Column, before target: BoardCard.ID? = nil) {
        guard id != target, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        var card = cards.remove(at: index)
        if card.column != column {
            card.completedAt = column == .done ? .now : nil
            card.column = column
        }
        if let target, let targetIndex = cards.firstIndex(where: { $0.id == target }) {
            cards.insert(card, at: targetIndex)
        } else if column == .done {
            // Finished work reads newest first.
            cards.insert(card, at: cards.firstIndex { $0.column == .done } ?? cards.endIndex)
        } else {
            cards.insert(card, at: (cards.lastIndex { $0.column == column }.map { $0 + 1 }) ?? cards.endIndex)
        }
        onChange?()
    }

    /// The check on a card: done, or back to do.
    func toggleDone(_ id: BoardCard.ID) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        move(id, to: card.column == .done ? .todo : .done)
    }

    func clearDone() {
        cards.removeAll { $0.column == .done }
        onChange?()
    }
}
