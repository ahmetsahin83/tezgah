import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct LeadToolsTests {
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.txt": "a\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(snapshotURL: base.appendingPathComponent("workspace.json"), agentsDirectory: base.appendingPathComponent("agents"), restoresTabs: false)
        store.addFolder(root)
        let project = try #require(store.activeProject)
        await project.git.refresh()
        return (store, project, base)
    }

    /// An agent tab whose agent is `cat`, so prompts sent to it go nowhere harmful.
    private func agentTab(_ provider: AgentProvider, in project: Project, directory: URL? = nil) -> TerminalSession {
        let session = TerminalSession(directory: directory ?? project.url, title: provider.displayName, command: "cat",
                                      agent: provider == .claude ? ClaudeActivity() : AgentActivity(provider: provider))
        project.tabs.append(.terminal(session))
        return session
    }

    @Test func spawnRefusesBadRequestsAndNestedLeads() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let lead = agentTab(.claude, in: project)
        defer { lead.terminate() }

        #expect(await store.spawnWorker(for: lead.id, [:]).isError) // no prompt
        #expect(await store.spawnWorker(for: lead.id, ["prompt": "x", "agent": "gemini"]).isError)

        let worker = agentTab(.codex, in: project)
        defer { worker.terminate() }
        store.agentWorkers[worker.id] = AgentWorker(lead: lead.id, name: "w", provider: .codex, sentAt: .now)
        #expect(await store.spawnWorker(for: worker.id, ["prompt": "alt iş"]).isError) // workers don't lead
    }

    @Test func aTurnCountsOnlyOnceItEndsAfterTheLastMessage() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let tab = agentTab(.codex, in: project)
        defer { tab.terminate() }
        let activity = try #require(tab.agent)
        var worker = AgentWorker(lead: UUID(), name: "w", provider: .codex, sentAt: .now)

        activity.uiAppeared()
        #expect(!store.isDone(worker, tab: tab.id)) // ready, but the task hasn't been answered
        activity.handle(["hook_event_name": "UserPromptSubmit"])
        #expect(!store.isDone(worker, tab: tab.id))
        activity.handle(["hook_event_name": "Stop", "last_assistant_message": "Bitti"])
        #expect(store.isDone(worker, tab: tab.id))

        worker.sentAt = .now.addingTimeInterval(1) // a new message after that turn
        #expect(!store.isDone(worker, tab: tab.id))
        activity.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        #expect(store.isDone(worker, tab: tab.id)) // only the user can go on from here
        #expect(store.isDone(worker, tab: UUID())) // tab closed
    }

    @Test func sendingWaitsForTheAgentToBeFree() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let lead = agentTab(.claude, in: project)
        let worker = agentTab(.codex, in: project)
        defer { lead.terminate(); worker.terminate() }
        let sentAt = Date.distantPast
        store.agentWorkers[worker.id] = AgentWorker(lead: lead.id, name: "w", provider: .codex, sentAt: sentAt)
        let id = String(worker.id.uuidString.prefix(8))

        worker.agent?.handle(["hook_event_name": "UserPromptSubmit"])
        #expect(store.sendToWorker(of: lead.id, ["id": id, "message": "testi ekle"]).isError) // working
        worker.agent?.handle(["hook_event_name": "Stop"])
        #expect(!store.sendToWorker(of: lead.id, ["id": id, "message": "testi ekle"]).isError)
        #expect(store.agentWorkers[worker.id]!.sentAt > sentAt)
        #expect(store.sendToWorker(of: UUID(), ["id": id, "message": "x"]).isError) // someone else's agent
    }

    @Test func mergingTakesCommittedWorkAndCleansUp() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }
        let root = project.url
        let lead = agentTab(.claude, in: project)
        defer { lead.terminate() }
        let created = try await Worktrees.create(named: "Ekle", projectURL: root, root: root)
        let worker = agentTab(.codex, in: project, directory: created.url)
        let start = try await Git.run(["rev-parse", "HEAD"], in: created.url).text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.agentWorkers[worker.id] = AgentWorker(lead: lead.id, name: "ekle", provider: .codex, worktree: created.url, branch: created.branch, base: start, sentAt: .now)
        let id = String(worker.id.uuidString.prefix(8))

        try Data("b\n".utf8).write(to: created.url.appendingPathComponent("b.txt"))
        #expect(await store.mergeWorker(of: lead.id, ["id": id]).isError) // uncommitted
        let listed = await store.describe(store.agentWorkers[worker.id]!, tab: worker.id, withReply: false)
        #expect(listed.contains("branch tezgah/ekle, 0 commit(s), uncommitted changes"))

        _ = try await Git.run(["add", "-A"], in: created.url)
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "b"], in: created.url)
        let merged = await store.mergeWorker(of: lead.id, ["id": id])
        #expect(!merged.isError)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: created.url.path))
        #expect(store.agentWorkers[worker.id] == nil)
        #expect(!project.tabs.contains { $0.id == worker.id })
    }

    @Test func agentsMayWaitLongForEachOther() {
        let codex = CodexMonitor(hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        #expect(codex.overrides(mcpURL: "http://x").contains("mcp_servers.tezgah.tool_timeout_sec=1800.0"))
        let claude = ClaudeMonitor(directory: URL(fileURLWithPath: "/tmp/c"), hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        #expect(claude.environment["MCP_TOOL_TIMEOUT"] == "1800000")
    }
}
