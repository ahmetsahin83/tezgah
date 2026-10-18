import Foundation

/// An agent a lead agent started with `agent_spawn`, and what Tezgah keeps for it.
struct AgentWorker: Equatable {
    /// The lead's tab.
    let lead: UUID
    let name: String
    let provider: AgentProvider
    /// Its own worktree and branch, unless it works in the lead's folder.
    var worktree: URL?
    var branch: String?
    /// The commit the branch started from.
    var base: String?
    /// The board card it works on, if the lead gave one.
    var cardID: UUID?
    /// When the lead last gave it work; the turn that answers ends after this.
    var sentAt: Date
    /// Tezgah quit while it worked; its session came back but the turn it was in did not.
    var wasInterrupted = false
}
