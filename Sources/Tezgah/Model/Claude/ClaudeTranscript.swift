import Foundation
import Observation

/// A JSON value that can cross threads and be compared, for tool inputs and results.
enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(_ any: Any?) {
        switch any {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            // JSONSerialization gives booleans as NSNumber too.
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]: self = .array(value.map { JSONValue($0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue($0) })
        default: self = .null
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}

/// One thing shown in the conversation view.
struct ClaudeTranscriptEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Something the user typed.
        case prompt(text: String, images: Int)
        /// A slash command such as /compact, with what it printed.
        case command(name: String, arguments: String, output: String?)
        /// A `!` shell command run from the prompt.
        case shell(command: String, output: String)
        /// Claude's reply text, Markdown.
        case reply(String)
        case tool(ClaudeToolCall)
        /// "Interrupted", "conversation compacted" and the like.
        case notice(String)
        /// How long the turn took.
        case turnEnd(seconds: Double)
    }

    let id: String
    var kind: Kind
    let date: Date?
}

struct ClaudeToolCall: Equatable, Sendable {
    struct Result: Equatable, Sendable {
        /// What the model saw, as text.
        var text: String
        var isError: Bool
        /// Claude Code's own structured result (e.g. Edit's patch), when present.
        var details: JSONValue?
    }

    let id: String
    let name: String
    let input: JSONValue
    var result: Result?
    /// Calls made by a sub-agent are folded into its Task / Agent call.
    var isSidechain = false
}

/// Turns Claude Code's session transcript (JSON Lines) into conversation entries.
///
/// The format is internal to Claude Code and not documented, so everything is read defensively:
/// records that don't look as expected are skipped rather than shown wrong.
struct ClaudeTranscriptParser: Sendable {
    /// Sub-agent transcripts are all sidechain; the main one skips stray sidechain records.
    var includesSidechain = false
    private(set) var entries: [ClaudeTranscriptEntry] = [] {
        didSet { revision &+= 1 }
    }
    /// A title the user gave (/rename) beats the generated one.
    var title: String? { customTitle ?? generatedTitle }
    private var customTitle: String? {
        didSet { revision &+= 1 }
    }
    private var generatedTitle: String? {
        didSet { revision &+= 1 }
    }
    /// Changes whenever something shown changes; most records (attachments, bookkeeping) change nothing.
    private(set) var revision = 0
    /// Background tasks (sub-agents, shells) Claude Code reported as done, by the tool call that started them.
    private(set) var finishedTasks: Set<String> = [] {
        didSet { revision &+= 1 }
    }
    private var toolIndex: [String: Int] = [:]

    mutating func consume(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        consume(object)
    }

    mutating func consume(_ record: [String: Any]) {
        let type = record["type"] as? String
        switch type {
        case "custom-title":
            if let title = record["customTitle"] as? String, !title.isEmpty { customTitle = title }
            return
        case "ai-title":
            if let title = record["aiTitle"] as? String, !title.isEmpty { generatedTitle = title }
            return
        default:
            break
        }
        // Sub-agent records live in their own files nowadays; older versions mixed them in.
        if record["isSidechain"] as? Bool == true, !includesSidechain { return }

        let uuid = record["uuid"] as? String ?? UUID().uuidString
        let date = Self.date(record["timestamp"])

        switch type {
        case "user":
            consumeUser(record, uuid: uuid, date: date)
        case "assistant":
            consumeAssistant(record, uuid: uuid, date: date)
        case "system":
            switch record["subtype"] as? String {
            case "turn_duration":
                if let ms = (record["durationMs"] as? NSNumber)?.doubleValue, ms >= 1000 {
                    append(.init(id: uuid, kind: .turnEnd(seconds: ms / 1000), date: date))
                }
            case "compact_boundary":
                append(.init(id: uuid, kind: .notice("Konuşma özetlendi, bağlam boşaltıldı"), date: date))
            default:
                break
            }
        default:
            break
        }
    }

    private mutating func consumeUser(_ record: [String: Any], uuid: String, date: Date?) {
        guard let message = record["message"] as? [String: Any] else { return }
        if record["isCompactSummary"] as? Bool == true { return }

        if let text = message["content"] as? String {
            if record["isMeta"] as? Bool == true { return }
            consumeUserText(text, uuid: uuid, date: date)
            return
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        var texts: [String] = []
        var images = 0
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let id = block["tool_use_id"] as? String, let index = toolIndex[id],
                      case .tool(var call) = entries[index].kind else { continue }
                call.result = .init(
                    text: Self.resultText(block["content"]),
                    isError: block["is_error"] as? Bool ?? false,
                    details: record["toolUseResult"].map { JSONValue($0) }
                )
                entries[index].kind = .tool(call)
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "image":
                images += 1
            default:
                break
            }
        }
        guard record["isMeta"] as? Bool != true else { return }
        let text = texts.filter { !Self.isInjected($0) }.joined(separator: "\n\n")
        if !text.isEmpty || images > 0 {
            if images == 0 {
                consumeUserText(text, uuid: uuid, date: date)
            } else {
                append(.init(id: uuid, kind: .prompt(text: Self.stripImageMarkers(text), images: images), date: date))
            }
        }
    }

    private mutating func consumeUserText(_ raw: String, uuid: String, date: Date?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text.hasPrefix("[Request interrupted by user") {
            append(.init(id: uuid, kind: .notice("Durduruldu"), date: date))
            return
        }
        if let name = Self.tag("command-name", in: text) {
            let arguments = Self.tag("command-args", in: text) ?? ""
            append(.init(id: uuid, kind: .command(name: name, arguments: arguments, output: nil), date: date))
            return
        }
        if let output = Self.tag("local-command-stdout", in: text) ?? Self.tag("local-command-stderr", in: text) {
            // Belongs to the command just before it.
            if let last = entries.indices.last, case .command(let name, let arguments, nil) = entries[last].kind {
                let cleaned = Self.stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines)
                entries[last].kind = .command(name: name, arguments: arguments, output: cleaned.isEmpty ? nil : cleaned)
            }
            return
        }
        if let command = Self.tag("bash-input", in: text) {
            append(.init(id: uuid, kind: .shell(command: command, output: ""), date: date))
            if text.contains("<bash-stdout>") { attachShellOutput(text) }
            return
        }
        if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") {
            attachShellOutput(text)
            return
        }
        if text.hasPrefix("<task-notification>") {
            if let call = Self.tag("tool-use-id", in: text) { finishedTasks.insert(call) }
            return
        }
        if Self.isInjected(text) { return }
        append(.init(id: uuid, kind: .prompt(text: text, images: 0), date: date))
    }

    private mutating func attachShellOutput(_ text: String) {
        guard let last = entries.indices.last, case .shell(let command, _) = entries[last].kind else { return }
        let output = [Self.tag("bash-stdout", in: text), Self.tag("bash-stderr", in: text)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        entries[last].kind = .shell(command: command, output: Self.stripANSI(output))
    }

    private mutating func consumeAssistant(_ record: [String: Any], uuid: String, date: Date?) {
        guard let message = record["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for (offset, block) in blocks.enumerated() {
            let id = blocks.count == 1 ? uuid : "\(uuid)#\(offset)"
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text != "(no content)" else { continue }
                append(.init(id: id, kind: .reply(text), date: date))
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                if let index = toolIndex[toolID] {
                    // Same call written again (streaming updates): keep the latest input.
                    if case .tool(var call) = entries[index].kind {
                        call = ClaudeToolCall(id: toolID, name: name, input: JSONValue(block["input"]), result: call.result)
                        entries[index].kind = .tool(call)
                    }
                    continue
                }
                toolIndex[toolID] = entries.count
                append(.init(id: toolID, kind: .tool(.init(id: toolID, name: name, input: JSONValue(block["input"]))), date: date))
            default:
                break // thinking blocks are not shown
            }
        }
    }

    private mutating func append(_ entry: ClaudeTranscriptEntry) {
        // Records are sometimes written twice (e.g. after a resume); keep the first.
        if entries.last?.id == entry.id { return }
        entries.append(entry)
    }

    // MARK: Helpers

    /// Text the harness adds to the user's turn, never typed by the user.
    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["<system-reminder>", "<task-notification>", "<local-command-caveat>", "<user-memory-input>", "Caveat: The messages below"]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": block["text"] as? String
            case "image": "[Görsel]"
            default: nil
            }
        }.joined(separator: "\n")
    }

    private static func stripImageMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { dateFormatter.date(from: $0) }
    }
}

/// Follows a Claude Code transcript file as it grows.
@MainActor
@Observable
final class ClaudeTranscript {
    let url: URL
    private(set) var entries: [ClaudeTranscriptEntry] = []
    private(set) var title: String?
    private(set) var todos = ClaudeTodoList()
    /// Steps of sub-agents, by the Agent / Task call that started them.
    private(set) var subagents: [String: [ClaudeTranscriptEntry]] = [:]
    /// Sub-agents started in the background that have not reported back yet.
    private(set) var runningAgents: Set<String> = []
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

    func start() {
        guard watcher == nil else { return }
        // FSEvents reports the folder; the file name filter is cheap enough to skip.
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
                self.entries = update.entries
                self.title = update.title
                if update.todos != self.todos { self.todos = update.todos }
                if update.subagents != self.subagents { self.subagents = update.subagents }
                if update.runningAgents != self.runningAgents { self.runningAgents = update.runningAgents }
                self.version += 1
            }
            self.isLoaded = true
            self.pending = nil
            if self.needsAnotherRead {
                self.needsAnotherRead = false
                self.refresh()
            }
        }
    }

    private actor Reader {
        struct Update: Sendable {
            let entries: [ClaudeTranscriptEntry]
            let title: String?
            let todos: ClaudeTodoList
            let subagents: [String: [ClaudeTranscriptEntry]]
            let runningAgents: Set<String>
        }

        let url: URL
        private var main: TailedFile
        /// Sub-agent transcripts by file path, and the Agent call each belongs to.
        private var agents: [String: TailedFile] = [:]
        private var agentCalls: [String: String] = [:]
        /// Agent calls that run in the background: their tool result comes back before they finish.
        private var backgroundCalls: Set<String> = []

        init(url: URL) {
            self.url = url
            main = TailedFile(url: url, includesSidechain: false)
        }

        /// Sub-agents write next to the session: <session>/subagents/agent-<id>.jsonl, with a
        /// .meta.json naming the tool call that started them.
        private var agentsFolder: URL {
            url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        }

        func readNew() -> Update? {
            var changed = main.read()

            let files = (try? FileManager.default.contentsOfDirectory(at: agentsFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let path = file.path
                if agentCalls[path] == nil {
                    let meta = file.deletingPathExtension().appendingPathExtension("meta.json")
                    guard let data = try? Data(contentsOf: meta),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let toolUseID = object["toolUseId"] as? String else { continue }
                    agentCalls[path] = toolUseID
                    if object["requestShape"] as? String == "background" { backgroundCalls.insert(toolUseID) }
                    agents[path] = TailedFile(url: file, includesSidechain: true)
                }
                if agents[path]?.read() == true { changed = true }
            }

            guard changed else { return nil }
            var subagents: [String: [ClaudeTranscriptEntry]] = [:]
            for (path, file) in agents {
                if let call = agentCalls[path] { subagents[call] = file.parser.entries }
            }
            return Update(
                entries: main.parser.entries, title: main.parser.title, todos: .from(main.parser.entries),
                subagents: subagents, runningAgents: backgroundCalls.subtracting(main.parser.finishedTasks)
            )
        }
    }
}

/// A JSON Lines file read a bit more each time it grows.
private struct TailedFile {
    let url: URL
    private(set) var parser: ClaudeTranscriptParser
    private var offset: UInt64 = 0
    private var partial = Data()
    private let includesSidechain: Bool

    init(url: URL, includesSidechain: Bool) {
        self.url = url
        self.includesSidechain = includesSidechain
        parser = ClaudeTranscriptParser(includesSidechain: includesSidechain)
    }

    /// Reads what was appended; true if that changed anything shown.
    mutating func read() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return false }
        if end < offset {
            // Rewritten from scratch: start over.
            offset = 0
            partial = Data()
            parser = ClaudeTranscriptParser(includesSidechain: includesSidechain)
        }
        guard end > offset else { return false }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(end - offset)), !data.isEmpty else { return false }
        offset += UInt64(data.count)

        var buffer = partial + data
        let revision = parser.revision
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty {
                parser.consume(line: Data(line))
            }
        }
        partial = Data(buffer)
        return parser.revision != revision
    }
}

/// Claude's own task list for the session, rebuilt from its todo tool calls.
///
/// Older Claude Code versions send the whole list with TodoWrite; newer ones create and update
/// tasks one by one (TaskCreate / TaskUpdate). Both are followed.
struct ClaudeTodoList: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
        let id: String
        var title: String
        /// "Running the tests" while in progress, when Claude gives one.
        var activeTitle: String?
        var status: Status
    }

    var items: [Item] = []
    /// Index of the entry that last changed the list.
    var lastUpdate = -1

    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var current: Item? { items.first { $0.status == .inProgress } }
    var isFinished: Bool { !items.isEmpty && completedCount == items.count }
    /// Worth pinning above the conversation: work in progress, or just finished in the current turn.
    var isPinned = false

    static func from(_ entries: [ClaudeTranscriptEntry]) -> ClaudeTodoList {
        var list = ClaudeTodoList()
        for (index, entry) in entries.enumerated() {
            guard case .tool(let call) = entry.kind else { continue }
            let input = call.input
            switch call.name {
            case "TodoWrite":
                list.items = (input["todos"]?.array ?? []).enumerated().map { offset, todo in
                    Item(
                        id: todo["id"]?.string ?? "\(offset)",
                        title: todo["content"]?.string ?? todo["subject"]?.string ?? "",
                        activeTitle: todo["activeForm"]?.string,
                        status: Item.Status(rawValue: todo["status"]?.string ?? "") ?? .pending
                    )
                }
                list.lastUpdate = index
            case "TaskCreate":
                // The id comes back in the result ("Task #3 created…"); fall back to the order.
                let resultID = call.result?.details?["task"]?["id"]?.string
                    ?? call.result?.text.firstMatch(of: #/#(\d+)/#).map { String($0.1) }
                let id = resultID ?? "\(list.items.count + 1)"
                list.items.append(Item(
                    id: id,
                    title: input["subject"]?.string ?? input["content"]?.string ?? input["description"]?.string ?? "",
                    activeTitle: input["activeForm"]?.string,
                    status: Item.Status(rawValue: input["status"]?.string ?? "") ?? .pending
                ))
                list.lastUpdate = index
            case "TaskUpdate":
                guard let id = input["taskId"]?.string ?? input["id"]?.string ?? input["task_id"]?.string,
                      let position = list.items.firstIndex(where: { $0.id == id }) else { continue }
                if input["status"]?.string == "deleted" {
                    list.items.remove(at: position)
                } else {
                    if let status = input["status"]?.string.flatMap(Item.Status.init(rawValue:)) { list.items[position].status = status }
                    if let title = input["subject"]?.string { list.items[position].title = title }
                    if let active = input["activeForm"]?.string { list.items[position].activeTitle = active }
                }
                list.lastUpdate = index
            default:
                break
            }
        }
        let promptAfterwards = entries.dropFirst(list.lastUpdate + 1).contains {
            if case .prompt = $0.kind { true } else { false }
        }
        // A new prompt moves on; the list comes back when Claude updates it again.
        list.isPinned = !list.items.isEmpty && !promptAfterwards
        return list
    }
}
