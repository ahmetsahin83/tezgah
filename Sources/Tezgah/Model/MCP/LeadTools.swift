import Foundation

/// Tools that let any agent lead others: start agents (each on its own worktree and branch),
/// wait for them, give them more work, merge what they finished. Every agent shows up as a tab
/// in Tezgah, so the user sees and can step into all of it.
extension WorkspaceStore {
    /// How long agent_wait may wait, in seconds; the agents' tool timeouts are raised to match.
    static let maxAgentWait = 1800
    /// Agents one lead may have at a time.
    static let maxWorkersPerLead = 6

    func registerLeadTools() {
        func object(_ properties: [String: [String: any Sendable]], required: [String] = []) -> [String: any Sendable] {
            ["type": "object", "properties": properties, "required": required]
        }

        leadTool("agent_spawn", """
            Start another coding agent on a task, in a new Tezgah tab. By default it gets its own git worktree \
            and branch (tezgah/<name>) and is asked to commit there; merge its work with agent_merge. Returns its id. \
            It starts working right away; use agent_wait to wait for it.
            """,
            object([
                "prompt": ["type": "string", "description": "The task, complete enough to work on alone"],
                "agent": ["type": "string", "enum": ["claude", "codex"], "description": "Default claude"],
                "model": ["type": "string", "description": "e.g. opus, sonnet, haiku for claude; a Codex model id for codex. Default: the agent's own"],
                "effort": ["type": "string", "description": "How hard it thinks: low, medium, high, xhigh, max (codex also ultra). Default: the agent's own"],
                "name": ["type": "string", "description": "Short name, also used for the branch"],
                "worktree": ["type": "boolean", "description": "Default true. false: work in your own folder (only for tasks that don't edit files)"],
                "read_only": ["type": "boolean", "description": "Default false. true: may not edit files (reviews, research); works in your folder"],
                "card": ["type": "string", "description": "Board card id (board_list) the task is for; the card follows its branch"],
            ], required: ["prompt"])
        ) { store, lead, arguments in
            await store.spawnWorker(for: lead, arguments)
        }

        leadTool("agent_list", "The agents you started: id, state, branch, commits.", object([:])) { store, lead, _ in
            let workers = store.workers(of: lead)
            guard !workers.isEmpty else { return .text("You have not started any agents.") }
            var lines: [String] = []
            for (tab, worker) in workers {
                lines.append(await store.describe(worker, tab: tab, withReply: false))
            }
            return .text(lines.joined(separator: "\n"))
        }

        leadTool("agent_wait", """
            Wait until agents finish what you gave them (or stop for a permission only the user can answer), then \
            report their state, last reply and commits. Waits for all of them unless mode is "any".
            """,
            object([
                "ids": ["type": "array", "items": ["type": "string"], "description": "Default: all your agents"],
                "mode": ["type": "string", "enum": ["all", "any"]],
                "timeout_seconds": ["type": "integer", "description": "Default 600, at most \(Self.maxAgentWait)"],
            ])
        ) { store, lead, arguments in
            await store.waitForWorkers(of: lead, arguments)
        }

        leadTool("agent_send", "Give one of your agents its next message, e.g. review feedback. Only when it is not working.",
                 object(["id": ["type": "string"], "message": ["type": "string"]], required: ["id", "message"])) { store, lead, arguments in
            store.sendToWorker(of: lead, arguments)
        }

        leadTool("agent_merge", """
            Merge an agent's branch into the branch the project has checked out, then remove its worktree, branch and tab. \
            Refuses while it has uncommitted changes or is working; a conflicting merge is undone.
            """,
                 object(["id": ["type": "string"]], required: ["id"])) { store, lead, arguments in
            await store.mergeWorker(of: lead, arguments)
        }

        leadTool("agent_stop", "Close one of your agents' tab. Its worktree and branch stay unless discard is true.",
                 object(["id": ["type": "string"], "discard": ["type": "boolean", "description": "Also delete its worktree and branch, unmerged work included"]],
                        required: ["id"])) { store, lead, arguments in
            await store.stopWorker(of: lead, arguments)
        }
    }

    private func leadTool(
        _ name: String, _ description: String, _ schema: [String: any Sendable],
        run: @escaping @MainActor (WorkspaceStore, UUID, [String: Any]) async -> MCPToolResult
    ) {
        mcpServer.register(MCPTool(name: name, description: description, inputSchema: schema) { [weak self] arguments, tab in
            guard let self, claudeTab(tab)?.session.agent != nil else { return .error("This session is not in Tezgah anymore.") }
            return await run(self, tab, arguments)
        })
    }

    // MARK: Workers

    /// The agents a lead started, oldest first.
    func workers(of lead: UUID) -> [(tab: UUID, worker: AgentWorker)] {
        agentWorkers.filter { $0.value.lead == lead }
            .sorted { $0.value.sentAt < $1.value.sentAt }
            .map { (tab: $0.key, worker: $0.value) }
    }

    private func worker(_ reference: Any?, of lead: UUID) -> (tab: UUID, worker: AgentWorker)? {
        guard let text = (reference as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).uppercased(), text.count >= 4 else { return nil }
        let matches = workers(of: lead).filter { $0.tab.uuidString.hasPrefix(text) }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func shortID(_ tab: UUID) -> String {
        String(tab.uuidString.prefix(8)).lowercased()
    }

    func spawnWorker(for lead: UUID, _ arguments: [String: Any]) async -> MCPToolResult {
        guard let (leadSession, project) = claudeTab(lead) else { return .error("This session is not in Tezgah anymore.") }
        guard agentWorkers[lead] == nil else { return .error("Agents started by a lead can't start agents themselves.") }
        guard workers(of: lead).count < Self.maxWorkersPerLead else {
            return .error("You already have \(Self.maxWorkersPerLead) agents; merge or stop some first (agent_merge, agent_stop).")
        }
        guard let prompt = (arguments["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return .error("prompt is required")
        }
        guard let provider = AgentProvider(rawValue: (arguments["agent"] as? String) ?? "claude") else {
            return .error("agent must be claude or codex")
        }
        let model = (arguments["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let effort = (arguments["effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (arguments["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? String(prompt.split(separator: "\n").first?.prefix(40) ?? "ajan")
        let readOnly = arguments["read_only"] as? Bool ?? false
        let useWorktree = !readOnly && (arguments["worktree"] as? Bool ?? true)
        let card = (arguments["card"] as? String).flatMap { reference in
            project.board.cards.first { $0.id.uuidString.hasPrefix(reference.uppercased()) && reference.count >= 4 }
        }

        var worker = AgentWorker(lead: lead, name: name, provider: provider, sentAt: .now)
        var directory = leadSession.directory
        var workerPrompt = prompt
        if useWorktree {
            guard let root = project.git.root else {
                return .error("The project is not a git repository, so there is no worktree to give; use worktree: false for a task that doesn't edit files.")
            }
            do {
                let created = try await Worktrees.create(named: name, projectURL: project.url, root: root)
                worker.worktree = created.url
                worker.branch = created.branch
                worker.base = try await Git.run(["rev-parse", "HEAD"], in: created.url).text.trimmingCharacters(in: .whitespacesAndNewlines)
                directory = created.url.appendingPathComponent(project.git.prefix, isDirectory: true)
            } catch {
                return .error("Could not create a worktree: \(error.localizedDescription)")
            }
            workerPrompt += "\n\nBu iş için ayrı bir git worktree'sindesin (dal: \(worker.branch ?? "")). Değişiklikleri bu dalda yap ve iş bitince commit'le; birleştirmeyi seni başlatan ajan yapacak."
        }
        if var card, let worktree = worker.worktree, let branch = worker.branch, card.worktree == nil {
            card.worktree = BoardCard.Worktree(branch: branch, path: worktree.path)
            project.board.update(card)
            project.board.move(card.id, to: .doing)
            worker.cardID = card.id
        }

        let member = OrchestraTeam.Member(provider: provider, model: model, effort: effort)
        guard let session = await launchAgent(member, in: project, directory: directory, prompt: workerPrompt, readOnly: readOnly) else {
            if let worktree = worker.worktree, let branch = worker.branch, let root = project.git.root {
                try? await Worktrees.remove(worktree, branch: branch, root: root, force: true)
            }
            return .error("\(provider.displayName) is not installed on this Mac.")
        }
        worker.sentAt = .now
        agentWorkers[session.id] = worker
        return .text(await describe(worker, tab: session.id, withReply: false) + "\nIt is working on the task now; agent_wait waits for it.")
    }

    /// A worker's turn after the lead's last message is over, or it can't go on without the user.
    func isDone(_ worker: AgentWorker, tab: UUID) -> Bool {
        guard let activity = claudeTab(tab)?.session.agent else { return true } // tab closed
        switch activity.state {
        case .ended, .needsPermission: return true
        case .finished, .idle: return worker.wasInterrupted || (activity.turnEndedAt ?? .distantPast) > worker.sentAt
        case .starting, .working: return false
        }
    }

    static let leadResumePrompt = """
        Tezgah yeniden açıldı; başlattığın ajanlar geri geldi ama yarım kalan turları kesildi. agent_list ile \
        durumlarına bak, gerekirse agent_send ile işlerine devam etmelerini söyle ve kaldığın yerden sürdür.
        """

    /// Brings back the agents leads started before Tezgah quit, and tells each lead to go on.
    func resumeAgentWorkers(_ saved: [SavedAgentWorker], tabs: [String: UUID]) {
        var leads: Set<UUID> = []
        for item in saved {
            guard let lead = tabs[item.leadSession] else { continue } // without its lead, an agent is the user's
            // A worker whose tab did not come back keeps its branch to merge.
            let tab = item.workerSession.flatMap { tabs[$0] } ?? UUID()
            agentWorkers[tab] = AgentWorker(
                lead: lead, name: item.name, provider: item.provider,
                worktree: item.worktree.map { URL(fileURLWithPath: $0, isDirectory: true) },
                branch: item.branch, base: item.base, cardID: item.cardID, sentAt: .now, wasInterrupted: true
            )
            leads.insert(lead)
        }
        for lead in leads {
            guard let session = claudeTab(lead)?.session else { continue }
            sendWhenReady(Self.leadResumePrompt, to: session)
        }
    }

    func waitForWorkers(of lead: UUID, _ arguments: [String: Any]) async -> MCPToolResult {
        var targets = workers(of: lead)
        if let ids = arguments["ids"] as? [Any], !ids.isEmpty {
            let picked = ids.compactMap { worker($0, of: lead) }
            guard picked.count == ids.count else { return .error("Unknown agent id; see agent_list.") }
            targets = picked
        }
        guard !targets.isEmpty else { return .error("You have not started any agents.") }
        let waitsForAll = (arguments["mode"] as? String) != "any"
        let timeout = min(max((arguments["timeout_seconds"] as? NSNumber)?.intValue ?? 600, 5), Self.maxAgentWait)
        let deadline = Date.now.addingTimeInterval(TimeInterval(timeout))
        while Date.now < deadline {
            let done = targets.filter { isDone($0.worker, tab: $0.tab) }
            if waitsForAll ? done.count == targets.count : !done.isEmpty { break }
            try? await Task.sleep(for: .seconds(2))
        }
        var lines: [String] = []
        for target in targets {
            lines.append(await describe(agentWorkers[target.tab] ?? target.worker, tab: target.tab, withReply: true))
        }
        return .text(lines.joined(separator: "\n\n"))
    }

    func sendToWorker(of lead: UUID, _ arguments: [String: Any]) -> MCPToolResult {
        guard let (tab, worker) = worker(arguments["id"], of: lead) else { return .error("Unknown agent id; see agent_list.") }
        guard let message = (arguments["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return .error("message is required")
        }
        guard let session = claudeTab(tab)?.session, let activity = session.agent else { return .error("Its tab was closed.") }
        switch activity.state {
        case .working: return .error("It is still working; wait for it with agent_wait.")
        case .needsPermission: return .error("It is waiting for a permission only the user can give in Tezgah.")
        case .ended: return .error("Its session has ended.")
        case .starting where session.claude == nil: return .error("It is still starting; try again in a moment.")
        default: break
        }
        sendPrompt(message, to: session)
        agentWorkers[tab]?.sentAt = .now
        agentWorkers[tab]?.wasInterrupted = false
        return .text("Sent to \(worker.name). agent_wait waits for its answer.")
    }

    func mergeWorker(of lead: UUID, _ arguments: [String: Any]) async -> MCPToolResult {
        guard let (tab, worker) = worker(arguments["id"], of: lead) else { return .error("Unknown agent id; see agent_list.") }
        guard let worktree = worker.worktree, let branch = worker.branch, let (_, project) = claudeTab(lead), let root = project.git.root else {
            return .error("This agent has no branch of its own to merge.")
        }
        if claudeTab(tab)?.session.agent?.state == .working { return .error("It is still working; wait for it with agent_wait.") }
        if (try? await Worktrees.hasUncommittedChanges(at: worktree)) == true {
            return .error("It has uncommitted changes; ask it to commit them (agent_send), then merge.")
        }
        let target = project.git.status.branch ?? "the checked-out branch"
        if let conflicts = await Worktrees.conflicts(merging: branch, root: root), !conflicts.isEmpty {
            return .error("""
                Merging \(branch) into \(target) would conflict in: \(conflicts.joined(separator: ", ")). Nothing was changed. \
                Ask the agent (agent_send) to run `git merge \(target)` in its worktree, resolve the conflicts and commit; \
                then agent_merge again.
                """)
        }
        do {
            try await Worktrees.merge(branch: branch, root: root)
        } catch {
            await project.git.refresh()
            return .error("Could not merge \(branch) (conflict?); the merge was undone and the project is as it was.\n\(error.localizedDescription)")
        }
        await retire(tab, worker, in: project, removingBranch: true, force: false)
        if let cardID = worker.cardID { project.board.move(cardID, to: .done) }
        return .text("Merged \(branch) into \(target); its worktree, branch and tab are gone.")
    }

    func stopWorker(of lead: UUID, _ arguments: [String: Any]) async -> MCPToolResult {
        guard let (tab, worker) = worker(arguments["id"], of: lead), let (_, project) = claudeTab(lead) else {
            return .error("Unknown agent id; see agent_list.")
        }
        let discard = arguments["discard"] as? Bool ?? false
        await retire(tab, worker, in: project, removingBranch: discard, force: true)
        if !discard, let branch = worker.branch {
            return .text("Stopped \(worker.name); its branch \(branch) and worktree stay for the user.")
        }
        return .text("Stopped \(worker.name)" + (worker.branch != nil ? "; its worktree and branch are deleted." : "."))
    }

    /// Closes a worker's tab, and with `removingBranch` its worktree and branch (`force`: unmerged too).
    private func retire(_ tab: UUID, _ worker: AgentWorker, in project: Project, removingBranch: Bool, force: Bool) async {
        agentWorkers[tab] = nil
        if let session = claudeTab(tab)?.session {
            session.terminate()
            removeTab(tab, from: project)
        }
        guard removingBranch, let worktree = worker.worktree, let branch = worker.branch else { return }
        if let card = worker.cardID.flatMap({ id in project.board.cards.first { $0.id == id } }), card.worktree != nil {
            await finishWorktree(of: card, in: project, closing: worktreeTabs(of: card, in: project), force: force)
        } else if let root = project.git.root {
            try? await Worktrees.remove(worktree, branch: branch, root: root, force: force)
            project.forgetRepository(at: worktree)
            await project.git.refresh()
        }
    }

    /// One line about a worker, and with `withReply` its last reply.
    func describe(_ worker: AgentWorker, tab: UUID, withReply: Bool) async -> String {
        let activity = claudeTab(tab)?.session.agent
        let state = switch activity?.state {
        case nil: "tab closed"
        case .starting: "starting"
        case .idle: "ready"
        case .working: "working" + (activity?.currentStep.map { ": \($0)" } ?? "")
        case .needsPermission: "waiting for a permission only the user can give" + (activity?.message.map { ": \($0)" } ?? "")
        case .finished: "finished"
        case .ended: "session ended"
        }
        var line = "[\(Self.shortID(tab))] \(worker.name) · \(worker.provider.displayName) · \(state)"
            + (worker.wasInterrupted ? " (its turn was cut off when Tezgah quit)" : "")
        if let worktree = worker.worktree, let branch = worker.branch, FileManager.default.fileExists(atPath: worktree.path) {
            let commits = (try? await Git.run(["rev-list", "--count", "\(worker.base ?? "HEAD")..HEAD"], in: worktree).text
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "?"
            let dirty = (try? await Worktrees.hasUncommittedChanges(at: worktree)) == true
            line += " · branch \(branch), \(commits) commit(s)" + (dirty ? ", uncommitted changes" : "") + " · \(worktree.path)"
        }
        if withReply, let reply = activity?.lastReply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            line += "\nLast reply:\n" + (reply.count > 3000 ? String(reply.prefix(3000)) + "…" : reply)
        }
        return line
    }
}
