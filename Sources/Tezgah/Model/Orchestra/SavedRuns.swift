import Foundation

/// An orchestra run as saved with the workspace, to go on when Tezgah opens again. Agents are
/// named by their session ids, the one thing about them that stays the same across a restart.
struct SavedOrchestraRun: Codable, Equatable {
    var cardID: UUID
    var team: OrchestraTeam
    var branch: String
    var worktree: String
    var directory: String
    var base: String
    var phase: OrchestraRun.Phase
    var round: Int
    var reviewedHead: String?
    var lastNotes: String?
    var developerSession: String?
    /// Optional, so runs saved before these were known still load.
    var conflictAttempts: Int?
    var conflictTarget: String?
    var extraRounds: Int?
    var ignoresRoundLimit: Bool?
    var continuation: OrchestraRun.Continuation?
}

/// An agent a lead started, as saved with the workspace.
struct SavedAgentWorker: Codable, Equatable {
    var leadSession: String
    /// nil when its tab was closed; its branch can still be merged.
    var workerSession: String?
    var name: String
    var provider: AgentProvider
    var worktree: String?
    var branch: String?
    var base: String?
    var cardID: UUID?
}
