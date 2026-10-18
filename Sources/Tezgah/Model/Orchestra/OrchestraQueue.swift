import Foundation

/// "Sırayla yürüt": the orchestra takes the board's to-do cards one after another, top first.
/// A merged card moves the queue on; so does a card the orchestra stopped on, which stays on the
/// board with its branch for the user. Cards stopping in a row stop the queue: then the trouble
/// is likely not the card's (a plan limit, uncommitted changes in the project).
struct OrchestraQueue: Codable, Equatable, Sendable {
    /// The card the queue is running now.
    var cardID: UUID?
    /// Cards the orchestra stopped on since the last merge.
    var stopsInARow = 0

    static let maxStopsInARow = 2

    /// The queue's card is over; false when the queue should stop. A card that only waits for the
    /// user's answers says nothing about the system, so it doesn't count as stuck.
    mutating func cardFinished(merged: Bool, countsAsStuck: Bool = true) -> Bool {
        cardID = nil
        if merged {
            stopsInARow = 0
        } else if countsAsStuck {
            stopsInARow += 1
        }
        return stopsInARow < Self.maxStopsInARow
    }

    /// The top to-do card nobody has started yet.
    @MainActor static func nextCard(on board: ProjectBoard) -> BoardCard? {
        board.cards(in: .todo).first { $0.worktree == nil }
    }
}

extension WorkspaceStore {
    func startQueue(in project: Project) {
        guard project.orchestraQueue == nil else { return }
        project.orchestraQueue = OrchestraQueue()
        advanceQueue(in: project)
    }

    /// Takes no more cards; a card already running goes on by itself.
    func stopQueue(in project: Project, because reason: String? = nil) {
        guard project.orchestraQueue != nil else { return }
        project.orchestraQueue = nil
        persist()
        if let reason {
            Notifier.shared.post(title: "\(project.name) · Sıra durdu", body: reason, tabID: project.board.id)
            announceQueue("\(project.name) · Sıra durdu\n\(reason)", in: project)
        }
    }

    /// Starts the next to-do card, unless the queue's card is still running.
    func advanceQueue(in project: Project) {
        guard var queue = project.orchestraQueue else { return }
        if let current = queue.cardID, orchestraRuns[current]?.isActive == true { return }
        guard let card = OrchestraQueue.nextCard(on: project.board) else {
            project.orchestraQueue = nil
            persist()
            Notifier.shared.post(title: "\(project.name) · Sıra bitti", body: "Yapılacak kart kalmadı", tabID: project.board.id)
            announceQueue("\(project.name) · Sıra bitti: Yapılacak'ta kart kalmadı.", in: project)
            return
        }
        queue.cardID = card.id
        project.orchestraQueue = queue
        persist()
        startOrchestra(card, in: project, inBackground: true)
    }

    /// The orchestra merged the queue's card or stopped on it.
    func queueCardFinished(_ cardID: UUID, merged: Bool, countsAsStuck: Bool = true, in project: Project) {
        guard var queue = project.orchestraQueue, queue.cardID == cardID else { return }
        let goesOn = queue.cardFinished(merged: merged, countsAsStuck: countsAsStuck)
        project.orchestraQueue = queue
        guard goesOn else {
            stopQueue(in: project, because: "Üst üste \(queue.stopsInARow) kart takıldı; takılanlar dallarıyla panoda duruyor")
            return
        }
        advanceQueue(in: project)
    }

    /// The user stepped in on the queue's card (stopped its run, threw its worktree away).
    func queueCardTakenOver(_ cardID: UUID, in project: Project) {
        guard project.orchestraQueue?.cardID == cardID else { return }
        stopQueue(in: project)
    }
}
