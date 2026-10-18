import Foundation

/// The orchestra's tools: the planner hands over its plan, reviewers and the judge give their verdict.
extension WorkspaceStore {
    func registerOrchestraTools() {
        mcpServer.register(MCPTool(
            name: "plan_ready",
            description: "Only when Tezgah asked you to plan a card: hand your plan to the developer who will write the code.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "What the work is, as you understood it, and any assumption you made"],
                    "approach": ["type": "string", "description": "How to do it: the steps and the files or layers to touch"],
                    "done_criteria": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Concrete, checkable conditions for the work to count as done, tests included; each one verified against the code (what it names exists, it fits the scope) and saying how to check it",
                    ],
                    "included_ideas": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Small improvements closely tied to this work, to do in this card too",
                    ],
                    "separate_ideas": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["title": ["type": "string"], "detail": ["type": "string"]],
                            "required": ["title"],
                        ],
                        "description": "Bigger ideas worth a card of their own; not done here, the user decides",
                    ],
                    "blocked": [
                        "type": "string",
                        "description": "Only when the card can't be done or needs the user's information, access or decision first: why. Then the run stops and the user answers your questions",
                    ],
                    "questions": [
                        "type": "array", "items": ["type": "string"],
                        "description": "With blocked: the questions the user should answer, each on its own",
                    ],
                ],
                "required": ["summary"],
            ]
        ) { [weak self] arguments, tab in
            guard let self else { return .error("Tezgah is closing.") }
            guard let plan = Self.plan(from: arguments) else { return .error("summary is required (or blocked with questions)") }
            return self.recordPlan(from: tab, plan)
        })

        mcpServer.register(MCPTool(
            name: "review_verdict",
            description: "Only when Tezgah asked you to review or decide on a branch: give your verdict. "
                + "approve when the work is done and right; request_changes with notes the developer can act on.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "decision": ["type": "string", "enum": ["approve", "request_changes"]],
                    "notes": ["type": "string", "description": "Why; for request_changes, the concrete changes to make"],
                ],
                "required": ["decision"],
            ]
        ) { [weak self] arguments, tab in
            guard let self else { return .error("Tezgah is closing.") }
            guard let decision = arguments["decision"] as? String, ["approve", "request_changes"].contains(decision) else {
                return .error("decision must be approve or request_changes")
            }
            return self.recordVerdict(from: tab, approved: decision == "approve", notes: arguments["notes"] as? String ?? "")
        })
    }

    /// `plan_ready`'s arguments as a plan; nil without a summary.
    static func plan(from arguments: [String: Any]) -> BoardCard.RunPlan? {
        func text(_ key: String) -> String {
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func list(_ key: String) -> [String] {
            ((arguments[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let summary = text("summary")
        let blocked = text("blocked")
        guard !summary.isEmpty || !blocked.isEmpty else { return nil }
        let ideas = ((arguments["separate_ideas"] as? [Any]) ?? []).compactMap { item -> BoardCard.RunPlan.Idea? in
            guard let idea = item as? [String: Any],
                  let title = (idea["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            return BoardCard.RunPlan.Idea(title: title, detail: (idea["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return BoardCard.RunPlan(
            summary: summary, approach: text("approach"), doneCriteria: list("done_criteria"),
            includedIdeas: list("included_ideas"), separateIdeas: ideas,
            blocked: blocked.isEmpty ? nil : blocked, questions: list("questions")
        )
    }
}
