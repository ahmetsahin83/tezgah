import AppKit
import CodeEditSourceEditor
import Foundation

/// Turns transcript entries into the HTML blocks of the conversation view.
///
/// Rendering happens in Swift so the page stays a thin shell: it only inserts, replaces and
/// orders blocks. Blocks are cached by their content, so a growing transcript re-renders only
/// what changed.
@MainActor
final class ClaudeConversationRenderer {
    struct Block: Equatable {
        let id: String
        let html: String
    }

    /// Context that changes how blocks look, apart from the entries themselves.
    struct Context: Equatable {
        /// The session is working, so a call without a result is still running.
        var isWorking: Bool
        /// The tool waiting for permission, if any.
        var pendingTool: String?
        /// Whether the session has a baseline to show its own diffs against.
        var canShowSessionDiff: Bool
    }

    /// Tools that look around or run commands; runs of them fold into one line, so the
    /// conversation reads as replies and edits rather than a log.
    static let quietTools: Set<String> = [
        "Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "NotebookRead", "ToolSearch", "Bash", "BashOutput",
        "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ToolSearch",
        "mcp__tezgah__browser_read", "mcp__tezgah__browser_console", "mcp__tezgah__browser_screenshot", "mcp__tezgah__browser_scroll",
    ]

    let root: URL
    private var cache: [String: (key: CacheKey, html: String)] = [:]

    private struct CacheKey: Equatable {
        let entries: [ClaudeTranscriptEntry]
        let context: Context
        let isLast: Bool
        /// Steps of the sub-agents started in this block.
        let subagents: [[ClaudeTranscriptEntry]]
        let runningAgents: [String]
    }

    /// Background sub-agents that have not reported back.
    private var runningAgents: Set<String> = []

    /// Sub-agent steps for the blocks being rendered, by Agent call id.
    private var subagents: [String: [ClaudeTranscriptEntry]] = [:]

    init(root: URL) {
        self.root = root
    }

    func blocks(
        for entries: [ClaudeTranscriptEntry],
        subagents: [String: [ClaudeTranscriptEntry]] = [:],
        runningAgents: Set<String> = [],
        context: Context
    ) -> [Block] {
        self.subagents = subagents
        self.runningAgents = runningAgents
        var groups: [[ClaudeTranscriptEntry]] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if case .tool(let call) = entry.kind, Self.quietTools.contains(call.name) {
                var run = [entry]
                var next = index + 1
                while next < entries.count, case .tool(let other) = entries[next].kind, Self.quietTools.contains(other.name) {
                    run.append(entries[next])
                    next += 1
                }
                if run.count >= 3 {
                    groups.append(run)
                } else {
                    groups += run.map { [$0] }
                }
                index = next
            } else {
                groups.append([entry])
                index += 1
            }
        }

        var seen = Set<String>()
        var blocks: [Block] = []
        for (offset, group) in groups.enumerated() {
            let id = group[0].id
            seen.insert(id)
            let isLast = offset == groups.count - 1
            let agentSteps = group.compactMap { entry -> [ClaudeTranscriptEntry]? in
                if case .tool(let call) = entry.kind { subagents[call.id] } else { nil }
            }
            let running = group.map(\.id).filter { runningAgents.contains($0) }
            let key = CacheKey(entries: group, context: context, isLast: isLast, subagents: agentSteps, runningAgents: running)
            if let cached = cache[id], cached.key == key {
                blocks.append(Block(id: id, html: cached.html))
                continue
            }
            let html = group.count > 1
                ? exploredHTML(group, context: context, isLast: isLast)
                : html(for: group[0], context: context, isLast: isLast)
            cache[id] = (key, html)
            blocks.append(Block(id: id, html: html))
        }
        cache = cache.filter { seen.contains($0.key) }
        return blocks
    }

    // MARK: Entries

    private func html(for entry: ClaudeTranscriptEntry, context: Context, isLast: Bool) -> String {
        let time = entry.date.map { #" title="\#(Self.timeFormatter.string(from: $0))""# } ?? ""
        switch entry.kind {
        case .prompt(let text, let images):
            var chips = ""
            if images > 0 {
                chips = #"<div class="chips">"# + (1...images).map { _ in #"<span class="chip">\#(Icon.image) Görsel</span>"# }.joined() + "</div>"
            }
            let long = text.split(separator: "\n", omittingEmptySubsequences: false).count > 14 || text.count > 1400
            let body = text.isEmpty ? "" : #"<div class="prompt-text\#(long ? " clamped" : "")">\#(linkify(escape(text)))</div>"#
            let more = long ? #"<button class="more" data-action="expand">Tamamını göster</button>"# : ""
            let actions = """
            <div class="msg-actions">\
            <button data-entry-action="copy" data-entry="\(escape(entry.id))" title="Kopyala">\(Icon.copy)</button>\
            <button data-entry-action="edit" data-entry="\(escape(entry.id))" title="Düzenle: composer'a koy">\(Icon.pencil)</button>\
            <button data-entry-action="resend" data-entry="\(escape(entry.id))" title="Tekrar gönder">\(Icon.redo)</button>\
            </div>
            """
            return #"<div class="prompt"\#(time)><div class="bubble">\#(chips)\#(body)\#(more)</div>\#(actions)</div>"#

        case .reply(let markdown):
            let actions = #"<div class="msg-actions"><button data-entry-action="copy" data-entry="\#(escape(entry.id))" title="Markdown olarak kopyala">\#(Icon.copy)</button></div>"#
            return #"<div class="reply"\#(time)>\#(renderMarkdown(markdown))\#(actions)</div>"#

        case .command(let name, let arguments, let output):
            let label = name.hasPrefix("/") ? name : "/" + name
            var html = #"<div class="command"\#(time)><span class="slash">\#(escape(label))</span>"#
            if !arguments.isEmpty { html += #" <span class="args">\#(escape(arguments))</span>"# }
            html += "</div>"
            if let output, !output.isEmpty {
                html += #"<pre class="command-output">\#(escape(Self.truncated(output, lines: 40)))</pre>"#
            }
            return html

        case .shell(let command, let output):
            var body = #"<div class="console"><pre class="command-line"><span class="prompt-sign">!</span> \#(highlightShell(command))</pre>"#
            if !output.isEmpty { body += #"<pre class="output">\#(escape(Self.truncated(output, lines: 200)))</pre>"# }
            body += "</div>"
            return toolHTML(
                id: entry.id, icon: Icon.terminal, verb: "Kabuk", target: #"<code>\#(escape(command))</code>"#,
                meta: runLink(command), body: body, open: !output.isEmpty && output.count < 600, status: .done, time: time
            )

        case .tool(let call):
            return toolHTML(for: call, context: context, isLast: isLast, time: time)

        case .notice(let text):
            return #"<div class="notice"\#(time)><span>\#(escape(text))</span></div>"#

        case .turnEnd(let seconds):
            return #"<div class="turn-end">\#(Icon.sparkle)<span>\#(Self.duration(seconds))</span></div>"#
        }
    }

    private func exploredHTML(_ group: [ClaudeTranscriptEntry], context: Context, isLast: Bool) -> String {
        var reads = 0, searches = 0, web = 0, commands = 0, tasks = 0, other = 0
        var running = false
        var rows = ""
        for entry in group {
            guard case .tool(let call) = entry.kind else { continue }
            switch call.name {
            case "Read", "NotebookRead": reads += 1
            case "Grep", "Glob", "LS", "ToolSearch": searches += 1
            case "WebSearch", "WebFetch": web += 1
            case "Bash", "BashOutput": commands += 1
            case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": tasks += 1
            default: other += 1
            }
            if call.result == nil, context.isWorking, isLast { running = true }
            rows += toolHTML(for: call, context: context, isLast: isLast && entry.id == group.last?.id, time: "")
        }
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) komut") }
        if reads > 0 { parts.append("\(reads) dosya okundu") }
        if searches > 0 { parts.append("\(searches) arama") }
        if web > 0 { parts.append("\(web) web isteği") }
        if tasks > 0 { parts.append("\(tasks) görev güncellemesi") }
        if other > 0 { parts.append("\(other) işlem") }
        let summary = parts.joined(separator: " · ")
        let spinner = running ? #"<span class="spinner"></span>"# : ""
        return """
        <details class="explored" data-key="\(escape(group[0].id))">\
        <summary>\(commands > reads + searches ? Icon.terminal : Icon.search)<span class="verb">\(group.count) adım</span><span class="target">\(summary)</span>\(spinner)<span class="chev">\(Icon.chevron)</span></summary>\
        <div class="explored-list">\(rows)</div></details>
        """
    }

    // MARK: Tools

    private enum Status {
        case running, waiting, done, failed, cancelled
    }

    private func toolHTML(for call: ClaudeToolCall, context: Context, isLast: Bool, time: String) -> String {
        let input = call.input
        let status: Status
        if let result = call.result {
            status = result.isError ? .failed : .done
        } else if context.pendingTool == call.name, isLast || context.isWorking {
            status = .waiting
        } else if context.isWorking {
            status = .running
        } else {
            status = .cancelled
        }
        let resultText = call.result?.text ?? ""

        switch call.name {
        case "Read", "NotebookRead":
            let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? ""
            var range = ""
            if let offset = input["offset"]?.number {
                let start = Int(offset)
                range = input["limit"]?.number.map { " · \(start)–\(start + Int($0) - 1)" } ?? " · \(start)…"
            }
            return toolHTML(id: call.id, icon: Icon.file, verb: "Okudu", target: fileLink(path) + escape(range), meta: "",
                            body: "", open: false, status: status, time: time)

        case "Write":
            let path = input["file_path"]?.string ?? ""
            let content = input["content"]?.string ?? ""
            let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
            let isNew = call.result?.details?["type"]?.string == "create"
            var body = ""
            if let patch = call.result?.details?["structuredPatch"]?.array, !patch.isEmpty, !isNew {
                body = patchHTML(patch, path: path)
            } else if !content.isEmpty {
                body = codeHTML(Self.truncated(content, lines: 80), fileName: path, numbered: true)
            }
            return toolHTML(id: call.id, icon: Icon.pencil, verb: isNew ? "Oluşturdu" : "Yazdı", target: fileLink(path),
                            meta: #"<span class="added">+\#(lineCount)</span>"# + diffLink(path, context: context),
                            body: body, open: status == .waiting, status: status, time: time)

        case "Edit", "MultiEdit":
            let path = input["file_path"]?.string ?? ""
            var body = ""
            var added = 0, removed = 0
            if let patch = call.result?.details?["structuredPatch"]?.array, !patch.isEmpty {
                body = patchHTML(patch, path: path)
                (added, removed) = Self.count(patch)
            } else {
                let edits: [(String, String)]
                if let list = input["edits"]?.array {
                    edits = list.map { ($0["old_string"]?.string ?? "", $0["new_string"]?.string ?? "") }
                } else {
                    edits = [(input["old_string"]?.string ?? "", input["new_string"]?.string ?? "")]
                }
                body = edits.map { pairHTML(old: $0.0, new: $0.1, path: path) }.joined()
                for (old, new) in edits {
                    removed += old.isEmpty ? 0 : old.split(separator: "\n", omittingEmptySubsequences: false).count
                    added += new.isEmpty ? 0 : new.split(separator: "\n", omittingEmptySubsequences: false).count
                }
            }
            let meta = #"<span class="added">+\#(added)</span><span class="removed">−\#(removed)</span>"# + diffLink(path, context: context)
            return toolHTML(id: call.id, icon: Icon.pencil, verb: "Düzenledi", target: fileLink(path), meta: meta,
                            body: body, open: status != .failed && added + removed <= 40, status: status, time: time,
                            extraClass: "edit", error: call.result?.isError == true ? resultText : nil)

        case "Bash", "BashOutput", "KillShell", "KillBash":
            let command = input["command"]?.string ?? input["bash_id"]?.string ?? input["shell_id"]?.string ?? ""
            let description = input["description"]?.string
            let target = description.map { escape($0) } ?? #"<code>\#(escape(Self.firstLine(command)))</code>"#
            var output = resultText
            if let details = call.result?.details, case .object = details {
                let stdout = details["stdout"]?.string ?? ""
                let stderr = details["stderr"]?.string ?? ""
                output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                if output.isEmpty, details["interrupted"]?.bool == true { output = "(durduruldu)" }
            }
            output = ClaudeTranscriptParser.stripANSI(output)
            var body = #"<div class="console"><pre class="command-line"><span class="prompt-sign">$</span> \#(highlightShell(command))</pre>"#
            if !output.isEmpty {
                body += #"<pre class="output">\#(linkify(escape(Self.truncated(output, lines: 200))))</pre>"#
            }
            body += "</div>"
            let background = input["run_in_background"]?.bool == true ? #"<span class="tag">arka planda</span>"# : ""
            let run = call.name == "Bash" ? runLink(command) : ""
            return toolHTML(id: call.id, icon: Icon.terminal, verb: call.name == "Bash" ? "Çalıştırdı" : call.name, target: target,
                            meta: background + run, body: body, open: status == .waiting || status == .failed,
                            status: status, time: time)

        case "Grep":
            let pattern = input["pattern"]?.string ?? ""
            var target = #"<code>\#(escape(pattern))</code>"#
            if let path = input["path"]?.string { target += #" <span class="dim">· \#(escape(relative(path)))</span>"# }
            if let glob = input["glob"]?.string ?? input["type"]?.string { target += #" <span class="dim">· \#(escape(glob))</span>"# }
            return toolHTML(id: call.id, icon: Icon.search, verb: "Aradı", target: target, meta: countMeta(resultText),
                            body: resultBody(resultText), open: false, status: status, time: time)

        case "Glob", "LS":
            let pattern = input["pattern"]?.string ?? input["path"]?.string ?? ""
            return toolHTML(id: call.id, icon: Icon.folder, verb: "Listeledi", target: #"<code>\#(escape(relative(pattern)))</code>"#,
                            meta: countMeta(resultText), body: resultBody(resultText), open: false, status: status, time: time)

        case "WebFetch":
            let url = input["url"]?.string ?? ""
            let host = URL(string: url)?.host() ?? url
            return toolHTML(id: call.id, icon: Icon.globe, verb: "Web'den aldı", target: #"<a href="\#(escape(url))">\#(escape(host))</a>"#,
                            meta: "", body: resultBody(resultText), open: false, status: status, time: time)

        case "WebSearch":
            return toolHTML(id: call.id, icon: Icon.globe, verb: "Web'de aradı", target: escape(input["query"]?.string ?? ""),
                            meta: "", body: resultBody(resultText), open: false, status: status, time: time)

        case "TodoWrite":
            // The full list lives in the bar above the conversation; here it is one quiet row.
            let todos = input["todos"]?.array ?? []
            let done = todos.filter { $0["status"]?.string == "completed" }.count
            return toolHTML(id: call.id, icon: Icon.list, verb: "Yapılacaklar", target: escape(Self.todoSummary(todos)),
                            meta: #"<span class="dim">\#(done)/\#(todos.count)</span>"#, body: todoHTML(todos, time: ""),
                            open: false, status: status == .running ? .done : status, time: time)

        case "TaskCreate":
            let title = input["subject"]?.string ?? input["content"]?.string ?? input["description"]?.string ?? ""
            return toolHTML(id: call.id, icon: Icon.list, verb: "Görev ekledi", target: escape(title), meta: "",
                            body: "", open: false, status: status == .running ? .done : status, time: time)

        case "TaskUpdate":
            let state = input["status"]?.string
            let verb = switch state {
            case "completed": "Görevi bitirdi"
            case "in_progress": "Göreve başladı"
            case "deleted": "Görevi sildi"
            default: "Görevi güncelledi"
            }
            let target = input["subject"]?.string ?? input["taskId"]?.string.map { "#\($0)" } ?? ""
            return toolHTML(id: call.id, icon: state == "completed" ? Icon.checkCircle : Icon.list, verb: verb, target: escape(target),
                            meta: "", body: "", open: false, status: status == .running ? .done : status, time: time)

        case "Task", "Agent":
            let description = input["description"]?.string ?? input["subagent_type"]?.string ?? "Alt görev"
            let steps = (subagents[call.id] ?? []).filter {
                // Its first prompt is the task itself, shown above.
                if case .prompt = $0.kind { false } else { true }
            }
            let isRunning = status == .running || runningAgents.contains(call.id)
            var body = ""
            if let prompt = input["prompt"]?.string {
                body += #"<div class="sub-label">Görev</div><div class="sub-prompt">\#(linkify(escape(Self.truncated(prompt, lines: 30))))</div>"#
            }
            if !steps.isEmpty {
                body += #"<div class="sub-label">Adımlar · \#(steps.filter { if case .tool = $0.kind { true } else { false } }.count)</div>"#
                body += #"<div class="sub-steps">\#(subagentStepsHTML(steps, isRunning: isRunning))</div>"#
            }
            // A background agent's tool result only says it started; its own last words are the report.
            let isBackground = runningAgents.contains(call.id) || call.result?.details?["status"]?.string == "async_launched"
                || resultText.localizedCaseInsensitiveContains("background")
            let report: String? = if isBackground {
                isRunning ? nil : steps.last.flatMap { if case .reply(let text) = $0.kind { text } else { nil } }
            } else {
                resultText.isEmpty ? nil : resultText
            }
            if let report {
                body += #"<div class="sub-label">Sonuç</div><div class="sub-result">\#(renderMarkdown(report))</div>"#
            }
            var target = escape(description)
            if isRunning, let step = Self.currentStep(of: steps) {
                target += #" <span class="dim">· \#(escape(step))</span>"#
            }
            let kind = input["subagent_type"]?.string.map { #"<span class="tag">\#(escape($0))</span>"# } ?? ""
            // Open while it works, so its steps can be watched; folded once done.
            let rowStatus: Status = isRunning ? .running : (status == .running ? .done : status)
            return toolHTML(id: call.id, icon: Icon.agent, verb: "Alt ajan", target: target, meta: kind,
                            body: body, open: isRunning, status: rowStatus, time: time, extraClass: "agent")

        case "AskUserQuestion":
            let questions = input["questions"]?.array ?? []
            let answers = call.result?.details?["answers"]
            var body = ""
            for question in questions {
                let text = question["question"]?.string ?? ""
                body += #"<div class="question"><div class="q">\#(escape(text))</div>"#
                let answer = answers?[text]?.string
                for option in question["options"]?.array ?? [] {
                    let label = option["label"]?.string ?? ""
                    let chosen = answer.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(label) } ?? false
                    body += #"<div class="option\#(chosen ? " chosen" : "")"><span class="dot"></span><span>\#(escape(label))</span>"#
                    if let description = option["description"]?.string { body += #"<span class="dim">\#(escape(description))</span>"# }
                    body += "</div>"
                }
                if let answer, !(question["options"]?.array ?? []).contains(where: { $0["label"]?.string == answer }) {
                    body += #"<div class="option chosen"><span class="dot"></span><span>\#(escape(answer))</span></div>"#
                }
                body += "</div>"
            }
            let first = questions.first?["question"]?.string ?? "Soru"
            return toolHTML(id: call.id, icon: Icon.question, verb: "Sordu", target: escape(first), meta: "",
                            body: body, open: true, status: status, time: time)

        case "ExitPlanMode":
            let plan = input["plan"]?.string ?? ""
            return #"<div class="plan"\#(time)><div class="plan-head">\#(Icon.list)<span>Plan</span>\#(statusHTML(status))</div><div class="plan-body">\#(renderMarkdown(plan))</div></div>"#

        case "Skill":
            let name = input["skill"]?.string ?? input["command"]?.string ?? ""
            return toolHTML(id: call.id, icon: Icon.sparkle, verb: "Skill", target: escape(name), meta: "",
                            body: resultBody(resultText), open: false, status: status, time: time)

        case let name where name.hasPrefix("mcp__tezgah__"):
            // Tezgah's own tools read as actions, not as an MCP server's names.
            let tool = String(name.dropFirst("mcp__tezgah__".count))
            let (icon, verb): (String, String) = switch tool {
            case "browser_open": (Icon.globe, "Sayfayı açtı")
            case "browser_screenshot": (Icon.image, "Ekran görüntüsü")
            case "browser_read": (Icon.globe, "Sayfayı okudu")
            case "browser_click": (Icon.globe, "Tıkladı")
            case "browser_type": (Icon.pencil, "Yazdı")
            case "browser_eval": (Icon.terminal, "JavaScript")
            case "browser_console": (Icon.terminal, "Konsol")
            case "browser_scroll": (Icon.globe, "Kaydırdı")
            case "browser_set_viewport": (Icon.globe, "Boyut")
            case "open_in_editor": (Icon.file, "Editörde açtı")
            case let other where other.hasPrefix("simulator_"): (Icon.tool, "Simülatör · " + other.dropFirst("simulator_".count).replacingOccurrences(of: "_", with: " "))
            case let other where other.hasPrefix("board_"): (Icon.list, "Pano · " + other.dropFirst("board_".count).replacingOccurrences(of: "_", with: " "))
            default: (Icon.tool, tool.replacingOccurrences(of: "_", with: " "))
            }
            let target = [input["url"]?.string, input["text"]?.string, input["selector"]?.string, input["path"]?.string, input["preset"]?.string,
                          input["title"]?.string, input["bundle_id"]?.string]
                .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
            let body = resultText.isEmpty || resultText == "[Görsel]" ? "" : resultBody(resultText)
            return toolHTML(id: call.id, icon: icon, verb: verb, target: escape(Self.firstLine(target)), meta: "",
                            body: body, open: false, status: status, time: time)

        default:
            var verb = call.name
            var target = ""
            if call.name.hasPrefix("mcp__") {
                let parts = call.name.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    verb = String(parts[1])
                    target = parts[2...].joined(separator: "_")
                }
            }
            if case .object(let object) = input {
                let summary = object.sorted { $0.key < $1.key }.compactMap { $0.value.string }.first(where: { !$0.isEmpty })
                if let summary { target += (target.isEmpty ? "" : " · ") + Self.firstLine(summary) }
            }
            var body = ""
            if case .object(let object) = input, !object.isEmpty {
                body += #"<pre class="output">\#(escape(Self.prettyJSON(input)))</pre>"#
            }
            if !resultText.isEmpty { body += resultBody(resultText) }
            return toolHTML(id: call.id, icon: Icon.tool, verb: verb, target: escape(target), meta: "",
                            body: body, open: false, status: status, time: time)
        }
    }

    /// A sub-agent's work, compact: its tool calls and short notes, the latest at the bottom.
    private func subagentStepsHTML(_ steps: [ClaudeTranscriptEntry], isRunning: Bool) -> String {
        let shown = steps.suffix(40)
        var html = steps.count > shown.count ? #"<div class="dim sub-more">… \#(steps.count - shown.count) adım daha</div>"# : ""
        let context = Context(isWorking: isRunning, pendingTool: nil, canShowSessionDiff: false)
        for (offset, step) in shown.enumerated() {
            let isLast = offset == shown.count - 1
            switch step.kind {
            case .tool(let call):
                html += toolHTML(for: call, context: context, isLast: isLast, time: "")
            case .reply(let text):
                html += #"<div class="sub-note">\#(escape(Self.truncated(text, lines: 4)))</div>"#
            default:
                break
            }
        }
        return html
    }

    /// "Okudu App.swift" for the step a sub-agent is on.
    private static func currentStep(of steps: [ClaudeTranscriptEntry]) -> String? {
        guard let last = steps.last(where: { if case .tool = $0.kind { true } else { false } }),
              case .tool(let call) = last.kind else { return nil }
        let input = call.input
        let detail = input["description"]?.string
            ?? input["file_path"]?.string.map { ($0 as NSString).lastPathComponent }
            ?? input["pattern"]?.string ?? input["command"]?.string.map(firstLine) ?? input["url"]?.string ?? ""
        return detail.isEmpty ? call.name : "\(call.name): \(detail)"
    }

    private func toolHTML(
        id: String, icon: String, verb: String, target: String, meta: String, body: String,
        open: Bool, status: Status, time: String, extraClass: String = "", error: String? = nil
    ) -> String {
        var classes = "tool"
        if !extraClass.isEmpty { classes += " " + extraClass }
        switch status {
        case .failed: classes += " failed"
        case .waiting: classes += " waiting"
        case .running: classes += " running"
        default: break
        }
        var content = body
        if let error, !error.isEmpty {
            content = #"<pre class="output error-text">\#(escape(Self.truncated(error, lines: 20)))</pre>"# + content
        }
        let hasBody = !content.isEmpty
        let summary = """
        <span class="icon">\(icon)</span><span class="verb">\(escape(verb))</span>\
        <span class="target">\(target)</span><span class="meta">\(meta)\(statusHTML(status))</span>\
        \(hasBody ? #"<span class="chev">\#(Icon.chevron)</span>"# : "")
        """
        if !hasBody {
            return #"<div class="\#(classes) flat"\#(time)><div class="row">\#(summary)</div></div>"#
        }
        return #"<details class="\#(classes)" data-key="\#(escape(id))"\#(open ? " open" : "")\#(time)><summary class="row">\#(summary)</summary><div class="tool-body">\#(content)</div></details>"#
    }

    private func statusHTML(_ status: Status) -> String {
        switch status {
        case .running: #"<span class="spinner"></span>"#
        case .waiting: #"<span class="pill warn">Onay bekliyor</span>"#
        case .failed: #"<span class="pill bad">Hata</span>"#
        case .cancelled: #"<span class="pill">Yanıtsız</span>"#
        case .done: ""
        }
    }

    private static func todoSummary(_ todos: [JSONValue]) -> String {
        if let active = todos.first(where: { $0["status"]?.string == "in_progress" }) {
            return active["activeForm"]?.string ?? active["content"]?.string ?? ""
        }
        return todos.allSatisfy({ $0["status"]?.string == "completed" }) ? "Hepsi tamamlandı" : "\(todos.count) madde"
    }

    private func todoHTML(_ todos: [JSONValue], time: String) -> String {
        guard !todos.isEmpty else { return "" }
        let done = todos.filter { $0["status"]?.string == "completed" }.count
        var html = #"<div class="todos"\#(time)><div class="todos-head">\#(Icon.list)<span>Yapılacaklar</span><span class="dim">\#(done)/\#(todos.count)</span></div>"#
        for todo in todos {
            let status = todo["status"]?.string ?? "pending"
            let text = status == "in_progress" ? (todo["activeForm"]?.string ?? todo["content"]?.string ?? "") : (todo["content"]?.string ?? "")
            let mark = switch status {
            case "completed": Icon.checkCircle
            case "in_progress": #"<span class="spinner small"></span>"#
            default: Icon.circle
            }
            html += #"<div class="todo \#(escape(status))"><span class="mark">\#(mark)</span><span>\#(escape(text))</span></div>"#
        }
        return html + "</div>"
    }

    private func countMeta(_ result: String) -> String {
        let lines = result.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, !result.hasPrefix("No ") else { return result.isEmpty ? "" : #"<span class="dim">sonuç yok</span>"# }
        return #"<span class="dim">\#(lines.count) sonuç</span>"#
    }

    private func resultBody(_ result: String) -> String {
        guard !result.isEmpty else { return "" }
        return #"<pre class="output">\#(linkify(escape(Self.truncated(result, lines: 120))))</pre>"#
    }

    // MARK: Diffs

    private func patchHTML(_ hunks: [JSONValue], path: String) -> String {
        let grammar = DiffHighlighter.grammar(forFileName: path)
        var rows = ""
        for (index, hunk) in hunks.enumerated() {
            var oldLine = Int(hunk["oldStart"]?.number ?? 1)
            var newLine = Int(hunk["newStart"]?.number ?? 1)
            let lines = (hunk["lines"]?.array ?? []).compactMap(\.string)
            if index > 0 { rows += #"<tr class="gap"><td colspan="3"></td></tr>"# }
            let oldSide = lines.filter { !$0.hasPrefix("+") }.map { String($0.dropFirst()) }
            let newSide = lines.filter { !$0.hasPrefix("-") }.map { String($0.dropFirst()) }
            let oldHTML = highlightedLines(oldSide, grammar: grammar)
            let newHTML = highlightedLines(newSide, grammar: grammar)
            var oldIndex = 0, newIndex = 0
            for line in lines {
                if line.hasPrefix("-") {
                    rows += #"<tr class="del"><td class="ln">\#(oldLine)</td><td class="ln"></td><td class="code">\#(oldHTML[oldIndex])</td></tr>"#
                    oldLine += 1; oldIndex += 1
                } else if line.hasPrefix("+") {
                    rows += #"<tr class="add"><td class="ln"></td><td class="ln">\#(newLine)</td><td class="code">\#(newHTML[newIndex])</td></tr>"#
                    newLine += 1; newIndex += 1
                } else {
                    rows += #"<tr><td class="ln">\#(oldLine)</td><td class="ln">\#(newLine)</td><td class="code">\#(newHTML[newIndex])</td></tr>"#
                    oldLine += 1; newLine += 1; oldIndex += 1; newIndex += 1
                }
            }
        }
        return #"<div class="diff"><table>\#(rows)</table></div>"#
    }

    /// An edit whose result is not in yet (or old transcripts without a patch): old and new text.
    private func pairHTML(old: String, new: String, path: String) -> String {
        let grammar = DiffHighlighter.grammar(forFileName: path)
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var rows = ""
        for line in highlightedLines(oldLines, grammar: grammar) {
            rows += #"<tr class="del"><td class="ln">−</td><td class="code">\#(line)</td></tr>"#
        }
        for line in highlightedLines(newLines, grammar: grammar) {
            rows += #"<tr class="add"><td class="ln">+</td><td class="code">\#(line)</td></tr>"#
        }
        return #"<div class="diff compact"><table>\#(rows)</table></div>"#
    }

    private static func count(_ hunks: [JSONValue]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for hunk in hunks {
            for line in (hunk["lines"]?.array ?? []).compactMap(\.string) {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    // MARK: Code

    private func codeHTML(_ code: String, fileName: String, numbered: Bool) -> String {
        let lines = highlightedLines(code.components(separatedBy: "\n"), grammar: DiffHighlighter.grammar(forFileName: fileName))
        if numbered {
            let rows = lines.enumerated().map { #"<tr><td class="ln">\#($0.offset + 1)</td><td class="code">\#($0.element)</td></tr>"# }.joined()
            return #"<div class="diff plain"><table>\#(rows)</table></div>"#
        }
        return lines.joined(separator: "\n")
    }

    /// Each line as HTML, colored as one piece of text so multi-line constructs come out right.
    private func highlightedLines(_ lines: [String], grammar: DiffHighlighter.Grammar?) -> [String] {
        guard let grammar, !lines.isEmpty, lines.count < 3000 else {
            return lines.map { $0.isEmpty ? " " : escape($0) }
        }
        let text = lines.joined(separator: "\n")
        let captures = DiffHighlighter.captureMap(for: text, grammar: grammar)
        guard !captures.isEmpty else { return lines.map { $0.isEmpty ? " " : escape($0) } }

        var result: [String] = []
        var offset = 0
        for line in lines {
            let units = Array(line.utf16)
            var html = ""
            var start = 0
            while start < units.count {
                let capture = captures[offset + start]
                var end = start + 1
                while end < units.count, captures[offset + end] == capture { end += 1 }
                let piece = escape(String(utf16CodeUnits: Array(units[start..<end]), count: end - start))
                if let capture {
                    html += #"<span class="\#(Self.cssClass(for: capture))">\#(piece)</span>"#
                } else {
                    html += piece
                }
                start = end
            }
            result.append(html.isEmpty ? " " : html)
            offset += units.count + 1
        }
        return result
    }

    private func highlightShell(_ command: String) -> String {
        highlightedLines(command.components(separatedBy: "\n"), grammar: DiffHighlighter.grammar(forFileName: "command.sh"))
            .joined(separator: "\n")
    }

    static func cssClass(for capture: CaptureName) -> String {
        switch capture {
        case .include, .constructor, .keyword, .boolean, .variableBuiltin,
             .keywordReturn, .keywordFunction, .repeat, .conditional, .tag: "k"
        case .comment: "c"
        case .variable, .property, .function, .method, .parameter: "v"
        case .number, .float: "n"
        case .string: "s"
        case .type: "t"
        case .typeAlternate: "a"
        }
    }

    // MARK: Markdown

    private func renderMarkdown(_ markdown: String) -> String {
        var html = MarkdownRenderer.html(markdown)
        // Fenced code: color it and add a copy button.
        html = Self.replace(#"<pre><code(?: class="language-([^"]+)")?>([\s\S]*?)</code></pre>"#, in: html) { groups in
            let language = groups[1]
            let code = Self.unescape(groups[2]).replacingOccurrences(of: "\n$", with: "", options: .regularExpression)
            let fileName = "code." + Self.fileExtension(forLanguage: language ?? "")
            let body = codeHTML(code, fileName: fileName, numbered: false)
            let label = language.map { #"<span class="lang">\#(escape($0))</span>"# } ?? ""
            let isShell = Self.shellLanguages.contains((language ?? "").lowercased())
            let run = isShell ? #"<button class="copy run" data-action="run">\#(Icon.play)Çalıştır</button>"# : ""
            return #"<div class="codeblock"><div class="codebar">\#(label)<span class="bar-actions">\#(run)<button class="copy" data-action="copy">Kopyala</button></span></div><pre><code>\#(body)</code></pre></div>"#
        }
        // Inline code that names a file in the project opens it.
        html = Self.replace(#"<code>([^<]{2,300})</code>"#, in: html) { groups in
            let text = groups[1] ?? ""
            guard let link = fileTarget(Self.unescape(text)) else { return groups[0] ?? "" }
            return #"<a class="file" href="\#(link)"><code>\#(text)</code></a>"#
        }
        return html
    }

    /// `Sources/App.swift`, `App.swift:42`, `/abs/path/file.txt:3:7` → a link, if the file exists.
    private func fileTarget(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.contains(".") || trimmed.contains("/") else { return nil }
        var pathPart = trimmed
        var line: Int?
        if let match = trimmed.firstMatch(of: #/^(.+?):(\d+)(?::\d+)?(?:-\d+)?$/#) {
            pathPart = String(match.1)
            line = Int(match.2)
        }
        let path = (pathPart as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return Self.openURL(url.path, line: line)
    }

    private func fileLink(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let name = (path as NSString).lastPathComponent
        let folder = (relative(path) as NSString).deletingLastPathComponent
        let folderHTML = folder.isEmpty || folder == "." ? "" : #"<span class="dim folder">\#(escape(folder))</span>"#
        return #"<a class="file" href="\#(Self.openURL(path, line: nil))" title="\#(escape(path))">\#(escape(name))</a>\#(folderHTML)"#
    }

    static let shellLanguages: Set<String> = ["bash", "sh", "shell", "zsh", "console", "shell-session"]

    /// Runs the command again in a terminal beside the conversation.
    private func runLink(_ command: String) -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return #"<a class="action run" href="tezgah-run://command?text=\#(Self.percent(command))" title="Terminalde çalıştır">\#(Icon.play)Çalıştır</a>"#
    }

    private func diffLink(_ path: String, context: Context) -> String {
        guard context.canShowSessionDiff, !path.isEmpty else { return "" }
        return #"<a class="action" href="tezgah-diff://open?path=\#(Self.percent(path))" title="Oturum başından beri bu dosyada olanlar">Diff</a>"#
    }

    /// Absolute paths inside the project become clickable in plain text (tool output, prompts).
    private func linkify(_ escapedText: String) -> String {
        let rootPath = root.path
        guard escapedText.contains(rootPath) else { return escapedText }
        return Self.replace(#"(\#(NSRegularExpression.escapedPattern(for: rootPath))/[^\s:&<>"'()]+)(?::(\d+))?"#, in: escapedText) { groups in
            let path = groups[1] ?? ""
            guard FileManager.default.fileExists(atPath: path) else { return groups[0] ?? "" }
            return #"<a class="file" href="\#(Self.openURL(path, line: groups[2].flatMap { Int($0) }))">\#(groups[0] ?? "")</a>"#
        }
    }

    private func relative(_ path: String) -> String {
        let rootPath = root.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    static func openURL(_ path: String, line: Int?) -> String {
        var url = "tezgah-open://file?path=" + percent(path)
        if let line { url += "&line=\(line)" }
        return url
    }

    // MARK: Text helpers

    private static func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "/._-~"))) ?? text
    }

    func escape(_ text: String) -> String {
        Self.escape(text)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func unescape(_ html: String?) -> String {
        (html ?? "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String?]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }

    static func truncated(_ text: String, lines limit: Int) -> String {
        var text = text
        if text.count > 40_000 { text = String(text.prefix(40_000)) + "\n…" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit else { return text }
        return lines.prefix(limit).joined(separator: "\n") + "\n… \(lines.count - limit) satır daha"
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    private static func prettyJSON(_ value: JSONValue) -> String {
        func any(_ value: JSONValue) -> Any {
            switch value {
            case .string(let string): string
            case .number(let number): number
            case .bool(let bool): bool
            case .array(let array): array.map(any)
            case .object(let object): object.mapValues(any)
            case .null: NSNull()
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: any(value), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return truncated(text, lines: 40)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) sn" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) dk" : "\(minutes) dk \(rest) sn"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func fileExtension(forLanguage language: String) -> String {
        let name = language.lowercased()
        let map = [
            "javascript": "js", "typescript": "ts", "python": "py", "py": "py", "ruby": "rb", "rust": "rs",
            "bash": "sh", "shell": "sh", "zsh": "sh", "sh": "sh", "console": "sh", "kotlin": "kt", "c++": "cpp",
            "objective-c": "m", "objc": "m", "markdown": "md", "yml": "yaml", "golang": "go", "csharp": "cs", "c#": "cs",
            "html": "html", "xml": "xml", "jsonc": "json", "dockerfile": "dockerfile", "makefile": "mk",
        ]
        return map[name] ?? name
    }
}

/// Small line icons drawn with the text color, 16×16.
enum Icon {
    private static func svg(_ paths: String) -> String {
        #"<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">\#(paths)</svg>"#
    }

    static let file = svg(#"<path d="M9 1.75H4.5A1.75 1.75 0 0 0 2.75 3.5v9A1.75 1.75 0 0 0 4.5 14.25h7a1.75 1.75 0 0 0 1.75-1.75V6z"/><path d="M9 1.75V6h4.25"/>"#)
    static let pencil = svg(#"<path d="M10.5 2.5l3 3L6 13H3v-3z"/><path d="M9 4l3 3"/>"#)
    static let terminal = svg(#"<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2"/><path d="M4.5 6.5l2 1.75-2 1.75M8.5 10.5h3"/>"#)
    static let search = svg(#"<circle cx="7" cy="7" r="4.25"/><path d="M10.25 10.25l3.5 3.5"/>"#)
    static let folder = svg(#"<path d="M1.75 4.5A1.75 1.75 0 0 1 3.5 2.75h2.6l1.5 1.75h4.9a1.75 1.75 0 0 1 1.75 1.75v5.25a1.75 1.75 0 0 1-1.75 1.75h-9a1.75 1.75 0 0 1-1.75-1.75z"/>"#)
    static let globe = svg(#"<circle cx="8" cy="8" r="6.25"/><path d="M1.75 8h12.5M8 1.75c1.75 1.9 2.6 4 2.6 6.25S9.75 12.35 8 14.25C6.25 12.35 5.4 10.25 5.4 8S6.25 3.65 8 1.75z"/>"#)
    static let agent = svg(#"<circle cx="8" cy="5.5" r="2.75"/><path d="M2.75 14c.6-2.6 2.7-4.25 5.25-4.25S12.65 11.4 13.25 14"/>"#)
    static let list = svg(#"<path d="M6 4h7.25M6 8h7.25M6 12h7.25"/><circle cx="3" cy="4" r=".6" fill="currentColor"/><circle cx="3" cy="8" r=".6" fill="currentColor"/><circle cx="3" cy="12" r=".6" fill="currentColor"/>"#)
    static let question = svg(#"<circle cx="8" cy="8" r="6.25"/><path d="M6.25 6.25a1.75 1.75 0 1 1 2.5 1.6c-.5.25-.75.6-.75 1.15v.25"/><circle cx="8" cy="11.25" r=".55" fill="currentColor"/>"#)
    static let tool = svg(#"<path d="M9.75 2.25a3.25 3.25 0 0 0-3 4.5L2.5 11a1.4 1.4 0 0 0 2 2l4.25-4.25a3.25 3.25 0 0 0 4.5-3l-2 .75-1.5-1.5.75-2a3.3 3.3 0 0 0-.75-.75z"/>"#)
    static let image = svg(#"<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2"/><circle cx="5.5" cy="6.25" r="1.1"/><path d="M14.25 10.5l-3.5-3.25-6.5 6"/>"#)
    static let play = #"<svg viewBox="0 0 16 16" width="9" height="9" fill="currentColor"><path d="M4.5 2.6v10.8a.6.6 0 0 0 .9.5l8.6-5.4a.6.6 0 0 0 0-1L5.4 2.1a.6.6 0 0 0-.9.5z"/></svg>"#
    static let copy = svg(#"<rect x="5.25" y="5.25" width="8.5" height="8.5" rx="1.75"/><path d="M10.75 5.25V3.5a1.25 1.25 0 0 0-1.25-1.25h-6A1.25 1.25 0 0 0 2.25 3.5v6a1.25 1.25 0 0 0 1.25 1.25h1.75"/>"#)
    static let redo = svg(#"<path d="M13.25 3.5v3.25H10"/><path d="M13 6.5A5.25 5.25 0 1 0 13.4 10"/>"#)
    static let chevron = svg(#"<path d="M6 4l4 4-4 4"/>"#)
    static let circle = svg(#"<circle cx="8" cy="8" r="5.5"/>"#)
    static let checkCircle = svg(#"<circle cx="8" cy="8" r="5.5"/><path d="M5.5 8.25l1.75 1.75 3.25-3.5"/>"#)
    static let sparkle = #"<svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><path d="M8 0.5c.35 3.9 1.6 5.15 5.5 5.5v.1c-3.9.35-5.15 1.6-5.5 5.5h-.1C7.55 7.7 6.3 6.45 2.4 6.1V6C6.3 5.65 7.55 4.4 7.9.5z" transform="translate(0 2)"/></svg>"#
}
