import Foundation
import Testing
@testable import Tezgah

/// Screens captured from Claude Code 2.1.306 and Codex 0.163 at their usage limits.
private let claudeLimitScreen = """
⏺ Testleri çalıştırıyorum.

  ⎿  You've hit your session limit · resets 3pm (Europe/Istanbul)
     /rate-limit-options to continue after reset or /rewind to undo this turn's file edits

────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────
"""

private let claudeMenuScreen = """
  You've hit your session limit · resets 3pm (Europe/Istanbul)

  What do you want to do?

  ❯ 1. Wait here, then continue automatically at 3pm
    2. Upgrade your plan
    3. Stop and wait for limit to reset

  Enter to confirm · Esc to cancel
"""

private let codexLimitScreen = """
• Ran swift build

■ You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 3:05 PM.

› Ask Codex to do anything
"""

@MainActor
struct AgentUnattendedTests {
    private let istanbul = TimeZone(identifier: "Europe/Istanbul")!

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = istanbul
        return formatter.date(from: text)!
    }

    @Test func findsLimitMessagesOnly() {
        let lines = claudeLimitScreen.components(separatedBy: "\n")
        #expect(AgentLimit.limitLines(in: lines).count == 1)
        #expect(AgentLimit.limitLines(in: codexLimitScreen.components(separatedBy: "\n")).count == 1)
        #expect(AgentLimit.limitLines(in: ["You've used 90% of your session limit · resets 3pm"]).isEmpty)
        #expect(AgentLimit.limitLines(in: ["Usage limit reached · continuing automatically at 3pm · esc to cancel"]).count == 1)
        #expect(AgentLimit.continuesByItself("Usage limit reached · continuing automatically at 3pm · esc to cancel"))
        #expect(!AgentLimit.continuesByItself("You've hit your session limit · resets 3pm"))
    }

    @Test func readsResetTimes() {
        let now = date("2026-10-21T13:10:00+03:00")
        #expect(AgentLimit.resetTime(in: "You've hit your session limit · resets 3pm (Europe/Istanbul)", now: now)
                == date("2026-10-21T15:00:00+03:00"))
        // Already past today: tomorrow.
        #expect(AgentLimit.resetTime(in: "You've hit your session limit · resets 11:30am (Europe/Istanbul)", now: now)
                == date("2026-10-22T11:30:00+03:00"))
        #expect(AgentLimit.resetTime(in: "You've hit your weekly limit · resets Oct 24, 3pm (Europe/Istanbul)", now: now)
                == date("2026-10-24T15:00:00+03:00"))
        #expect(AgentLimit.resetTime(in: codexLimitScreen.components(separatedBy: "\n")[2], now: now, timeZone: istanbul)
                == date("2026-10-21T15:05:00+03:00"))
        #expect(AgentLimit.resetTime(in: "■ You've hit your usage limit. … or try again at Oct 22nd, 2026 3:05 PM.", now: now, timeZone: istanbul)
                == date("2026-10-22T15:05:00+03:00"))
        #expect(AgentLimit.resetTime(in: "You've hit your monthly spend limit", now: now) == nil)
    }

    @Test func choosesWaitingInClaudesMenu() {
        let menu = claudeMenuScreen.components(separatedBy: "\n")
        let choice = AgentLimit.menuChoice(in: menu)
        #expect(choice?.number == 1 && choice?.continuesByItself == true)

        let withoutAutomatic = menu.filter { !$0.contains("Wait here") }
        let stop = AgentLimit.menuChoice(in: withoutAutomatic)
        #expect(stop?.number == 3 && stop?.continuesByItself == false)

        #expect(AgentLimit.menuChoice(in: ["What do you want to do?", "1. Upgrade your plan"]) == nil)
        #expect(AgentLimit.menuChoice(in: claudeLimitScreen.components(separatedBy: "\n")) == nil)
    }

    @Test func trustsTheWorktreeAndItsMainCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("app")
        let worktree = main.appendingPathComponent(".tezgah/worktrees/kart")
        let sub = worktree.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/kart"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/kart\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(AgentTrust.folders(for: sub) == [sub.path, worktree.path, main.path])
        #expect(AgentTrust.folders(for: main) == [main.path])

        let config = root.appendingPathComponent(".claude.json")
        try #"{"numStartups": 3, "projects": {"\#(main.path)": {"hasTrustDialogAccepted": true, "allowedTools": []}}}"#
            .write(to: config, atomically: true, encoding: .utf8)
        AgentTrust.trustForClaude(sub, configURL: config)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let projects = try #require(written["projects"] as? [String: [String: Any]])
        #expect(written["numStartups"] as? Int == 3)
        for folder in [sub.path, worktree.path, main.path] {
            #expect(projects[folder]?["hasTrustDialogAccepted"] as? Bool == true)
        }
        #expect(projects[main.path]?["allowedTools"] != nil)

        // Nothing Claude Code made, nothing written.
        let missing = root.appendingPathComponent("none.json")
        AgentTrust.trustForClaude(sub, configURL: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func codexTrustsItsFoldersAndSkipsTheUpdateScreen() {
        let codex = CodexMonitor(hookURL: URL(fileURLWithPath: "/tmp/h.sh"))
        #expect(codex.overrides(mcpURL: nil).contains("check_for_update_on_startup=false"))
        let command = codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh", trustedFolders: ["/p/app", "/p/app/.tezgah/worktrees/k"])
        #expect(command.contains(#"-c 'projects={"/p/app"={trust_level="trusted"},"/p/app/.tezgah/worktrees/k"={trust_level="trusted"}}'"#))
        #expect(!codex.command(for: .new, codexPath: "/x", shell: "/bin/zsh").contains("projects="))
    }
}
