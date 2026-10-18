import Foundation

/// Who works on a card when the orchestra runs it: a developer, any number of reviewers, and a
/// judge who weighs the reviews into one decision. Kept per project.
struct OrchestraTeam: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var provider: AgentProvider
        /// The model to start with; nil is the agent's own default.
        var model: String?
        /// What a reviewer looks at in particular, e.g. "güvenlik"; empty for a general review.
        var focus = ""
        /// How hard it thinks ("low" … "max"; Codex also "ultra"); nil is the agent's own default.
        var effort: String?

        init(provider: AgentProvider, model: String? = nil, focus: String = "", effort: String? = nil) {
            self.provider = provider
            self.model = model
            self.focus = focus
            self.effort = effort
        }

        /// Fields added later fall back to their defaults instead of failing the whole workspace.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            provider = try container.decode(AgentProvider.self, forKey: .provider)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            focus = try container.decodeIfPresent(String.self, forKey: .focus) ?? ""
            effort = try container.decodeIfPresent(String.self, forKey: .effort)
        }

        @MainActor var title: String {
            let model = model.map { AgentModels.name(of: $0, for: provider) }
            return model.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
        }
    }

    /// Whether a run starts with the planner; off goes straight to the developer.
    var plans = true
    /// Reads the card and the code first (without changing anything) and writes the plan the
    /// developer follows and the reviewers check against.
    var planner = Member(provider: .claude)
    var developer = Member(provider: .claude)
    var reviewers = [Member(provider: .codex)]
    /// Decides when there are several reviewers; a single reviewer's verdict stands by itself.
    var judge = Member(provider: .claude)
    /// Review rounds before the orchestra stops and asks the user; 0 is no limit.
    var maxRounds = 3
    /// "Birleşince push'la": each merge goes to the remote too.
    var pushesAfterMerge = false
    /// Minutes a step may take before the run counts as stuck; 0 is no limit. Review covers the judge.
    var planMinutes = 30
    var developMinutes = 90
    var reviewMinutes = 30

    static let minuteLimits = 0...480

    /// The limit for where a run is, in minutes; nil when there is none.
    func minutes(for phase: OrchestraRun.Phase) -> Int? {
        let minutes = switch phase {
        case .planning: planMinutes
        case .developing: developMinutes
        case .reviewing, .judging: reviewMinutes
        case .merging, .merged, .needsUser: 0
        }
        return minutes > 0 ? minutes : nil
    }

    static let roundLimits = 0...20

    init() {}

    /// Fields added later fall back to their defaults instead of failing the whole workspace.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OrchestraTeam()
        plans = try container.decodeIfPresent(Bool.self, forKey: .plans) ?? defaults.plans
        planner = try container.decodeIfPresent(Member.self, forKey: .planner) ?? defaults.planner
        developer = try container.decodeIfPresent(Member.self, forKey: .developer) ?? defaults.developer
        reviewers = try container.decodeIfPresent([Member].self, forKey: .reviewers) ?? defaults.reviewers
        judge = try container.decodeIfPresent(Member.self, forKey: .judge) ?? defaults.judge
        maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? defaults.maxRounds
        pushesAfterMerge = try container.decodeIfPresent(Bool.self, forKey: .pushesAfterMerge) ?? defaults.pushesAfterMerge
        planMinutes = try container.decodeIfPresent(Int.self, forKey: .planMinutes) ?? defaults.planMinutes
        developMinutes = try container.decodeIfPresent(Int.self, forKey: .developMinutes) ?? defaults.developMinutes
        reviewMinutes = try container.decodeIfPresent(Int.self, forKey: .reviewMinutes) ?? defaults.reviewMinutes
    }
}

/// The models each agent can start with.
enum AgentModels {
    struct Model: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// The thinking levels it takes, from Codex's catalog; empty when unknown.
        var efforts: [String] = []
    }

    /// Thinking levels for an agent's model. Codex's own default model gets the levels every
    /// listed model takes.
    @MainActor static func efforts(for member: OrchestraTeam.Member, codexModels: [Model]) -> [String] {
        guard member.provider == .codex else { return TerminalSession.effortLevels }
        if let model = member.model, let listed = codexModels.first(where: { $0.id == model }), !listed.efforts.isEmpty {
            return listed.efforts
        }
        let known = codexModels.map(\.efforts).filter { !$0.isEmpty }
        guard let first = known.first else { return ["low", "medium", "high", "xhigh"] }
        return first.filter { level in known.allSatisfy { $0.contains(level) } }
    }

    static func effortTitle(_ level: String) -> String {
        switch level {
        case "low": "Düşük"
        case "medium": "Orta"
        case "high": "Yüksek"
        case "xhigh": "Çok yüksek"
        case "max": "En yüksek"
        case "ultra": "Ultra (işi dağıtır)"
        default: level
        }
    }

    /// Claude Code takes aliases for its latest models.
    static let claude = [
        Model(id: "fable", name: "Fable"),
        Model(id: "opus", name: "Opus"),
        Model(id: "sonnet", name: "Sonnet"),
        Model(id: "haiku", name: "Haiku"),
    ]

    /// Codex's own list (`codex debug models`), read once.
    @MainActor private static var codex: [Model] = []

    /// A model's name, as far as Tezgah knows it.
    @MainActor static func name(of id: String, for provider: AgentProvider) -> String {
        (provider == .claude ? claude : codex).first { $0.id == id }?.name ?? id
    }

    /// Codex's models, read from it the first time.
    @MainActor static func codexModels() async -> [Model] {
        if codex.isEmpty, let codexPath = await WorkspaceStore.findCodex() {
            codex = await readCodexModels(codexPath: codexPath)
        }
        return codex
    }

    private static func readCodexModels(codexPath: String) async -> [Model] {
        let environment = await ShellEnvironment.shared.environment()
        let data = await Task.detached { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["debug", "models"]
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        return data.map(codexModels(fromCatalog:)) ?? []
    }

    /// The models Codex lists for people to pick, from its catalog JSON.
    static func codexModels(fromCatalog data: Data) -> [Model] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries = (json as? [[String: Any]])
            ?? ((json as? [String: Any])?["models"] as? [[String: Any]])
            ?? []
        return entries.compactMap { entry in
            guard let slug = entry["slug"] as? String, entry["visibility"] as? String != "hide" else { return nil }
            let efforts = (entry["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
            return Model(id: slug, name: entry["display_name"] as? String ?? slug, efforts: efforts)
        }
    }
}
