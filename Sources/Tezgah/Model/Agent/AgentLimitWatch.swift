import Foundation
import SwiftTerm

/// What the screen watch remembers about one agent tab.
struct LimitWatch {
    /// Limit messages on screen at the last look; nil before the first.
    var linesSeen: Int?
    /// Since when the agent waits for its limit to reset, for the orchestra's step time.
    var waitStartedAt: Date?
    /// The last key sent to Claude Code's limit menu, so a slow redraw doesn't get it twice.
    var keySentAt: Date?
    /// The last "go on" prompt Tezgah sent; a limit right after it is the same wait, told once.
    var promptSentAt: Date?
}

/// Reading an agent's usage limit off its screen. Neither agent tells its hooks: Claude Code shows
/// "You've hit your session limit · resets 3pm (Europe/Istanbul)" (and on some plans a menu of
/// what to do), Codex "You've hit your usage limit. … or try again at 3:05 PM."
enum AgentLimit {
    /// Lines saying the agent is at its limit.
    static func limitLines(in lines: [String]) -> [String] {
        lines.filter { line in
            line.range(of: #"you['’]ve hit your [^·]*limit|usage limit reached"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Claude Code keeps going by itself after the reset ("continuing automatically at 3pm").
    static func continuesByItself(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("continuing automatically")
    }

    /// The option of Claude Code's "What do you want to do?" menu that waits for the reset: its own
    /// automatic continue when offered, else "Stop and wait". A nil number: the menu shows none.
    static func menuChoice(in lines: [String]) -> (number: Int?, continuesByItself: Bool)? {
        guard lines.contains(where: { $0.contains("What do you want to do?") }) else { return nil }
        for (label, byItself) in [("Wait here, then continue automatically", true), ("Stop and wait for limit to reset", false)] {
            guard let line = lines.first(where: { $0.contains(label) }) else { continue }
            let pattern = #"(\d+)\.\s+"# + NSRegularExpression.escapedPattern(for: label)
            let number = (try? NSRegularExpression(pattern: pattern))
                .flatMap { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) }
                .flatMap { Range($0.range(at: 1), in: line) }
                .flatMap { Int(line[$0]) }
            return (number, byItself)
        }
        return nil
    }

    /// When the limit resets, from "resets 3pm (Europe/Istanbul)", "resets Oct 24, 3:30pm",
    /// "try again at 3:05 PM" or "try again at Oct 22nd, 2026 3:05 PM". A time without a date is
    /// its next occurrence.
    static func resetTime(in line: String, now: Date = .now, timeZone: TimeZone = .current) -> Date? {
        guard let expression = try? NSRegularExpression(pattern: #"(?:resets|try again at)\s+(.+)$"#, options: .caseInsensitive),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        var text = String(line[range]).components(separatedBy: " · ")[0]
        var zone = timeZone
        if let open = text.range(of: "("), let close = text.range(of: ")", range: open.upperBound..<text.endIndex) {
            if let named = TimeZone(identifier: String(text[open.upperBound..<close.lowerBound])) { zone = named }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\bam\b"#, with: "AM", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\bpm\b"#, with: "PM", options: [.regularExpression, .caseInsensitive])

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formats = ["h:mma", "ha", "MMM d, h:mma", "MMM d, ha", "MMM d, yyyy h:mma", "MMM d, yyyy ha", "MMM d h:mma", "MMM d ha"]
        for format in formats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }
            let hasDate = format.contains("d"), hasYear = format.contains("y")
            let time = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
            let today = calendar.dateComponents([.year, .month, .day], from: now)
            var components = DateComponents()
            components.year = hasYear ? time.year : today.year
            components.month = hasDate ? time.month : today.month
            components.day = hasDate ? time.day : today.day
            components.hour = time.hour
            components.minute = time.minute
            guard var date = calendar.date(from: components) else { continue }
            if date < now.addingTimeInterval(-60), !hasYear {
                date = calendar.date(byAdding: hasDate ? .year : .day, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }
}

extension InputObservingTerminalView {
    /// The rows on screen now, without the scrollback.
    func visibleLines() -> [String] {
        // Clamped to the screen, so a range past its height is the whole of it.
        visibleRowsText(0..<10_000)
    }
}

/// Agents that hit their usage limit with nobody at the Mac: Tezgah waits for the reset, then
/// tells them to go on. Claude Code's limit menu is answered with waiting. Time spent waiting
/// doesn't count against an orchestra step.
extension WorkspaceStore {
    static let limitResumePrompt = "Kullanım limiti sıfırlandı. Yarıda kalan işe kaldığın yerden devam et."
    /// When no reset time can be read, the agent is tried again this often.
    static let limitRetryInterval: TimeInterval = 30 * 60

    func watchAgentLimits(now: Date = .now) {
        guard AppSettings.shared.agentsRunUnattended else { return }
        for project in projects {
            for session in project.terminals {
                guard session.isRunning, let agent = session.agent, agent.state != .ended, agent.state != .starting else { continue }
                watchLimit(of: session, agent: agent, in: project, now: now)
            }
        }
    }

    private func watchLimit(of session: TerminalSession, agent: AgentActivity, in project: Project, now: Date) {
        let lines = session.view.visibleLines()
        var watch = agent.limitWatch
        defer { agent.limitWatch = watch }

        if agent.provider == .claude, let choice = AgentLimit.menuChoice(in: lines) {
            guard now.timeIntervalSince(watch.keySentAt ?? .distantPast) > 5 else { return }
            // Without numbers, Esc: the menu's cancel is "Stop and wait".
            session.sendClaudeKey(choice.number.map { .option($0) } ?? .escape)
            watch.keySentAt = now
            beginLimitWait(&watch, line: AgentLimit.limitLines(in: lines).last, continuesByItself: choice.continuesByItself,
                           session: session, agent: agent, project: project, now: now)
            return
        }

        let found = AgentLimit.limitLines(in: lines)
        if let seen = watch.linesSeen, found.count > seen, agent.turnStartedAt != nil {
            // A new message; acted on once the agent is quiet, not while it still reports work.
            let quiet = agent.state != .working || now.timeIntervalSince(agent.lastEventAt ?? .distantPast) > 15
            if quiet, let line = found.last {
                watch.linesSeen = found.count
                beginLimitWait(&watch, line: line, continuesByItself: AgentLimit.continuesByItself(line),
                               session: session, agent: agent, project: project, now: now)
            }
        } else {
            watch.linesSeen = found.count
        }

        guard let waitStartedAt = watch.waitStartedAt else { return }
        if let resumeAt = agent.limitResumeAt, now >= resumeAt {
            agent.limitResumeAt = nil
            // Working again (Claude Code's own continue) or asking something: nothing to send.
            if agent.state != .working, agent.state != .needsPermission {
                session.submitPrompt(Self.limitResumePrompt)
                watch.promptSentAt = now
                announceLimitResume(session, project: project)
            }
        }
        if agent.limitResumeAt == nil {
            // Over, whether Tezgah went on or a prompt came some other way.
            orchestraRun(of: session.id)?.extendPhase(by: now.timeIntervalSince(waitStartedAt))
            watch.waitStartedAt = nil
        }
    }

    private func beginLimitWait(
        _ watch: inout LimitWatch, line: String?, continuesByItself: Bool,
        session: TerminalSession, agent: AgentActivity, project: Project, now: Date
    ) {
        let usageReset = (agent as? ClaudeActivity)?.usage.flatMap { usage in
            [usage.fiveHourLimit, usage.weeklyLimit].compactMap { $0 }.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt).max()
        }
        let reset = line.flatMap { AgentLimit.resetTime(in: $0, now: now) } ?? usageReset
        let resumeAt: Date
        if let reset, reset > now, reset < now.addingTimeInterval(8 * 24 * 3600) {
            // A little after the reset; later still when the agent means to go on by itself.
            resumeAt = reset.addingTimeInterval(continuesByItself ? 180 : 60)
        } else {
            resumeAt = now.addingTimeInterval(Self.limitRetryInterval)
        }
        agent.limitResumeAt = resumeAt
        guard watch.waitStartedAt == nil else { return }
        watch.waitStartedAt = now
        let isRetry = now.timeIntervalSince(watch.promptSentAt ?? .distantPast) < 5 * 60
        if !isRetry { announceLimit(session, project: project, line: line, resumeAt: resumeAt) }
    }

    /// Whether one of the run's agents is waiting for its limit to reset.
    func isWaitingForLimit(_ run: OrchestraRun, in project: Project) -> Bool {
        project.terminals.contains { run.contains($0.id) && $0.agent?.limitWatch.waitStartedAt != nil }
    }
}
