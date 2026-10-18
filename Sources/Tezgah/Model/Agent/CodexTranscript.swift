import Foundation
import Observation

/// Turns a Codex session's rollout file (JSON Lines under ~/.codex/sessions) into the same
/// conversation entries Claude's transcript gives, so one view shows both.
///
/// Codex records each thing it shows as an item, started and completed (`event_msg` lines
/// with `item_started` / `item_completed`): the user's prompt, its replies, the commands it
/// ran, its edits, its MCP calls. The format is Codex's own and not documented, so it is read
/// defensively and anything unknown is left out.
struct CodexTranscriptParser: Sendable {
    private(set) var entries: [ClaudeTranscriptEntry] = []
    /// The first prompt's first line, for the tab and the overview.
    private(set) var title: String?
    /// The session's folder, for files named relative to it.
    private var cwd: String?
    private var indexByID: [String: Int] = [:]
    private var turnStartedAt: Date?

    /// Takes one line; true if it changed what is shown.
    mutating func consume(_ line: Data) -> Bool {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return false }
        let date = Self.date(record["timestamp"])
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("session_meta", _):
            cwd = payload["cwd"] as? String
            return false
        case ("event_msg", "item_started"), ("event_msg", "item_completed"):
            guard let item = payload["item"] as? [String: Any] else { return false }
            return take(item, completed: payload["type"] as? String == "item_completed", date: date)
        case ("event_msg", "task_started"):
            turnStartedAt = date
            return false
        case ("event_msg", "task_complete"):
            guard let start = turnStartedAt, let end = date else { return false }
            turnStartedAt = nil
            append(ClaudeTranscriptEntry(id: "turn-\(payload["turn_id"] as? String ?? UUID().uuidString)",
                                         kind: .turnEnd(seconds: end.timeIntervalSince(start)), date: end))
            return true
        case ("event_msg", "turn_aborted"):
            turnStartedAt = nil
            append(ClaudeTranscriptEntry(id: "aborted-\(entries.count)", kind: .notice("Durduruldu"), date: date))
            return true
        default:
            return false
        }
    }

    private mutating func take(_ item: [String: Any], completed: Bool, date: Date?) -> Bool {
        guard let id = item["id"] as? String else { return false }
        switch item["type"] as? String {
        case "UserMessage":
            guard completed else { return false }
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let images = content.filter { ($0["type"] as? String)?.contains("image") == true }.count
            guard !text.isEmpty || images > 0 else { return false }
            if title == nil { title = Self.firstLine(text) }
            put(ClaudeTranscriptEntry(id: id, kind: .prompt(text: text, images: images), date: date))
        case "AgentMessage":
            guard completed else { return false }
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            put(ClaudeTranscriptEntry(id: id, kind: .reply(text), date: date))
        case "Plan":
            guard completed, let text = item["text"] as? String, !text.isEmpty else { return false }
            put(ClaudeTranscriptEntry(id: id, kind: .reply(text), date: date))
        case "CommandExecution":
            let output = item["aggregated_output"] as? String ?? ""
            let exitCode = (item["exit_code"] as? NSNumber)?.intValue
            let result = completed ? ClaudeToolCall.Result(text: output, isError: (exitCode ?? 0) != 0, details: nil) : nil
            put(tool(id, "Bash", ["command": .string(Self.command(item["command"]))], result: result, date: date))
        case "McpToolCall":
            let name = "mcp__\(item["server"] as? String ?? "")__\(item["tool"] as? String ?? "")"
            var result: ClaudeToolCall.Result?
            if completed {
                let value = item["result"] as? [String: Any]
                let text = (value?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                let failed = (value?["isError"] as? Bool) == true || item["status"] as? String == "failed"
                result = ClaudeToolCall.Result(text: text, isError: failed, details: nil)
            }
            put(tool(id, name, Self.object(item["arguments"]), result: result, date: date))
        case "WebSearch":
            put(tool(id, "WebSearch", ["query": .string(item["query"] as? String ?? "")],
                     result: completed ? ClaudeToolCall.Result(text: "", isError: false, details: nil) : nil, date: date))
        case "FileChange":
            guard completed, let changes = item["changes"] as? [String: Any] else { return false }
            let failed = ["failed", "declined"].contains(item["status"] as? String ?? "")
            for (path, change) in changes.sorted(by: { $0.key < $1.key }) {
                guard let change = change as? [String: Any] else { continue }
                put(fileEdit(id: "\(id):\(path)", path: absolute(path), change: change, failed: failed, date: date))
            }
        default:
            return false
        }
        return true
    }

    private func fileEdit(id: String, path: String, change: [String: Any], failed: Bool, date: Date?) -> ClaudeTranscriptEntry {
        let failure = failed ? "Uygulanamadı" : ""
        switch change["type"] as? String {
        case "add":
            return tool(id, "Write", ["file_path": .string(path), "content": .string(change["content"] as? String ?? "")],
                        result: ClaudeToolCall.Result(text: failure, isError: failed, details: .object(["type": .string("create")])), date: date)
        case "delete":
            return ClaudeTranscriptEntry(id: id, kind: .notice("Sildi: \((path as NSString).lastPathComponent)"), date: date)
        default:
            let patch = Self.structuredPatch(change["unified_diff"] as? String ?? "")
            return tool(id, "Edit", ["file_path": .string(path)],
                        result: ClaudeToolCall.Result(text: failure, isError: failed, details: .object(["structuredPatch": .array(patch)])), date: date)
        }
    }

    private func tool(_ id: String, _ name: String, _ input: [String: JSONValue], result: ClaudeToolCall.Result?, date: Date?) -> ClaudeTranscriptEntry {
        ClaudeTranscriptEntry(id: id, kind: .tool(ClaudeToolCall(id: id, name: name, input: .object(input), result: result)), date: date)
    }

    /// Adds an entry, or replaces the one with its id: a started item completing.
    private mutating func put(_ entry: ClaudeTranscriptEntry) {
        if let index = indexByID[entry.id] {
            entries[index] = entry
        } else {
            append(entry)
        }
    }

    private mutating func append(_ entry: ClaudeTranscriptEntry) {
        indexByID[entry.id] = entries.count
        entries.append(entry)
    }

    private func absolute(_ path: String) -> String {
        guard !path.hasPrefix("/"), let cwd else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    /// ["/bin/zsh", "-lc", "git status"] → "git status"
    static func command(_ value: Any?) -> String {
        guard let parts = value as? [String] else { return value as? String ?? "" }
        if parts.count >= 3, ["-lc", "-c"].contains(parts[1]) { return parts[2...].joined(separator: " ") }
        return parts.joined(separator: " ")
    }

    /// A unified diff as Claude Code's structured patch: hunks with their starting lines and
    /// lines marked " ", "+" or "-", which the conversation shows as a diff.
    static func structuredPatch(_ diff: String) -> [JSONValue] {
        var hunks: [JSONValue] = []
        var current: (old: Int, new: Int, lines: [JSONValue])?
        func flush() {
            if let hunk = current {
                hunks.append(.object(["oldStart": .number(Double(hunk.old)), "newStart": .number(Double(hunk.new)), "lines": .array(hunk.lines)]))
            }
        }
        for line in diff.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: #/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/#) {
                flush()
                current = (Int(match.1) ?? 1, Int(match.2) ?? 1, [])
            } else if current != nil, let first = line.first, " +-".contains(first) {
                current?.lines.append(.string(line))
            }
        }
        flush()
        return hunks
    }

    private static func object(_ value: Any?) -> [String: JSONValue] {
        if case .object(let object) = JSONValue(value) { return object }
        return [:]
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Follows a Codex rollout file as it grows.
@MainActor
@Observable
final class CodexTranscript {
    let url: URL
    private(set) var entries: [ClaudeTranscriptEntry] = []
    private(set) var title: String?
    /// Changes whenever `entries` does; cheap to compare.
    private(set) var version = 0
    private(set) var isLoaded = false

    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherRead = false

    init(url: URL) {
        self.url = url
        reader = Reader(url: url)
    }

    /// The rollout file of a session, by its id: rollout-<time>-<id>.jsonl, in folders by date.
    nonisolated static func rolloutFile(forSession id: String, in codexHome: URL) -> URL? {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in files where url.lastPathComponent.hasSuffix("\(id).jsonl") {
            return url
        }
        return nil
    }

    /// Codex's home folder (~/.codex unless CODEX_HOME says otherwise).
    nonisolated static func home(environment: [String: String]) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    func start() {
        guard watcher == nil else { return }
        watcher = FileWatcher(url: url.deletingLastPathComponent()) { [weak self] _ in
            self?.refresh()
        }
        watcher?.start(latency: 0.05)
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Reads whatever was appended since the last read.
    func refresh() {
        if pending != nil {
            needsAnotherRead = true
            return
        }
        pending = Task { [weak self, reader] in
            let update = await reader.readNew()
            guard let self else { return }
            if let update {
                entries = update.entries
                title = update.title
                version += 1
            }
            isLoaded = true
            pending = nil
            if needsAnotherRead {
                needsAnotherRead = false
                refresh()
            }
        }
    }

    private actor Reader {
        struct Update: Sendable {
            let entries: [ClaudeTranscriptEntry]
            let title: String?
        }

        let url: URL
        private var parser = CodexTranscriptParser()
        private var offset: UInt64 = 0
        private var partial = Data()

        init(url: URL) {
            self.url = url
        }

        /// What was appended, if it changed anything shown.
        func readNew() -> Update? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return nil }
            if end < offset {
                // Rewritten from scratch: start over.
                (offset, partial, parser) = (0, Data(), CodexTranscriptParser())
            }
            guard end > offset else { return nil }
            try? handle.seek(toOffset: offset)
            let data = partial + ((try? handle.readToEnd()) ?? Data())
            offset = end
            var changed = false
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                if parser.consume(data[start..<newline]) { changed = true }
                start = data.index(after: newline)
            }
            partial = Data(data[start...]) // a line still being written
            return changed ? Update(entries: parser.entries, title: parser.title) : nil
        }
    }
}
