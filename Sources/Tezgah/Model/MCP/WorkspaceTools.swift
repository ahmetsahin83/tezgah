import AppKit

/// Tools over what Tezgah already holds: the project's databases, its terminals, and the editor.
extension WorkspaceStore {
    func registerWorkspaceTools() {
        func object(_ properties: [String: [String: any Sendable]], required: [String] = []) -> [String: any Sendable] {
            ["type": "object", "properties": properties, "required": required]
        }

        // MARK: Databases

        workspaceTool("db_connections", "Database connections saved in Tezgah for this project (Postgres, MySQL/MariaDB, SQLite). Passwords stay in Tezgah.",
                      object([:])) { _, project, _ in
            guard !project.databases.isEmpty else { return .text("No database connections in this project. The user can add one from Tezgah's database menu.") }
            return .text(project.databases.map { config in
                let open = project.databaseSessions.first { $0.config.id == config.id }
                let state = open?.state == .connected ? " (connected)" : ""
                return "- \(config.name): \(config.kind.title) · \(config.summary)\(state)"
            }.joined(separator: "\n"))
        }

        workspaceTool("db_schema", "Tables of a connection with their columns, types, primary keys and foreign keys. Give `table` for just one.",
                      object(["connection": ["type": "string", "description": "Name from db_connections; may be left out if there is only one"],
                              "table": ["type": "string"]])) { store, project, arguments in
            guard let session = store.databaseSession(arguments["connection"], project: project) else {
                return .error(Self.connectionHelp(project))
            }
            if let error = await session.ensureConnected() { return .error(error) }
            if session.schema.tables.isEmpty { await session.reloadSchema() }
            let schema = session.schema
            var tables = schema.tables
            if let wanted = (arguments["table"] as? String)?.lowercased() {
                tables = tables.filter { $0.name.lowercased() == wanted || $0.id.lowercased() == wanted }
                guard !tables.isEmpty else { return .error("No table named \(wanted).") }
            }
            let showSchema = Set(schema.tables.map(\.schema)).count > 1
            var lines: [String] = []
            for table in tables.prefix(150) {
                let columns = schema.columns(of: table).map { column -> String in
                    var text = "\(column.name) \(column.type)"
                    if column.isPrimaryKey { text += " PK" }
                    if !column.isNullable { text += " NOT NULL" }
                    if let key = schema.foreignKeys.first(where: { $0.table == table.name && $0.columns.contains(column.name) }) {
                        text += " → \(key.referencedTable)"
                    }
                    return text
                }
                lines.append("\(table.isView ? "view" : "table") \(showSchema ? table.id : table.name): " + columns.joined(separator: ", "))
            }
            if tables.count > 150 { lines.append("… \(tables.count - 150) more tables") }
            return .text(lines.isEmpty ? "No tables." : lines.joined(separator: "\n"))
        }

        workspaceTool("db_query", "Run SQL on a connection. Every query goes to the connection's history in Tezgah, under your name. Reading (SELECT, WITH, EXPLAIN, SHOW…) runs right away; anything that changes data or schema asks the user first.",
                      object(["connection": ["type": "string"], "sql": ["type": "string"],
                              "max_rows": ["type": "integer", "description": "Rows to return per result, default 50, at most 500"]], required: ["sql"])) { store, project, arguments in
            guard let sql = arguments["sql"] as? String, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error("sql is required") }
            guard let session = store.databaseSession(arguments["connection"], project: project) else {
                return .error(Self.connectionHelp(project))
            }
            let tab = arguments["__tab"] as? UUID
            let statements = SQLText.statementRanges(in: sql).map { (sql as NSString).substring(with: $0) }
            let writes = statements.filter { !Self.readOnlyKeywords.contains(SQLText.leadingKeyword(of: $0)) }
            if !writes.isEmpty, !(await Self.confirmWrite(writes, connection: session.config, agent: tab.map(store.agentName), telegram: store.telegram)) {
                if let tab { store.logQuery(sql, from: tab, outcome: "veritabanını değiştirmek istedi; reddedildi", in: project) }
                return .error("The user declined to run this. Do not retry it unless they ask.")
            }
            let (results, runError) = await session.runAndWait(sql, agent: tab.map(store.agentName))
            if let tab {
                let outcome = runError ?? Self.summary(of: results ?? [], statements: statements)
                store.logQuery(sql, from: tab, outcome: (writes.isEmpty ? "sorgu çalıştırdı · " : "veritabanını değiştirdi (onayınla) · ") + outcome, in: project)
            }
            if let runError { return .error(runError) }
            let limit = min(max((arguments["max_rows"] as? NSNumber)?.intValue ?? 50, 1), 500)
            return .text(Self.describe(results ?? [], limit: limit))
        }

        // MARK: Terminals

        workspaceTool("terminal_run", "Run a shell command in a Tezgah terminal, beside the conversation, in this session's folder. Waits up to `wait_seconds` (default 30) for it to finish and returns its output; long-running things (dev servers, watchers) keep running — read them later with terminal_read. Give `name` for a terminal of its own, e.g. \"dev server\".",
                      object(["command": ["type": "string"], "name": ["type": "string"],
                              "wait_seconds": ["type": "number"]], required: ["command"])) { store, project, arguments in
            guard let command = arguments["command"] as? String, !command.isEmpty else { return .error("command is required") }
            guard let tab = arguments["__tab"] as? UUID, let (claude, _) = store.claudeTab(tab) else { return .error("This Claude session is not in Tezgah anymore.") }
            let name = arguments["name"] as? String
            // A named terminal that is still busy can't take a new command.
            if let name, let busy = project.terminals.first(where: { $0.runsClaudeCommands && $0.title == name && $0.foregroundProcessName != nil }) {
                return .error("Terminal “\(name)” is still running \(busy.foregroundProcessName ?? "something"). Stop it with terminal_stop or use another name.")
            }
            let session = store.runInTerminal(command, directory: claude.directory, in: project, name: name)
            let before = session.view.bufferLines().count
            let wait = min(max((arguments["wait_seconds"] as? NSNumber)?.doubleValue ?? 30, 0), 600)
            try? await Task.sleep(for: .milliseconds(400))
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline, session.foregroundProcessName != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let running = session.foregroundProcessName
            let lines = Self.newLines(session, since: before)
            let status = running.map { "Still running (\($0)) in terminal “\(session.title)” [\(Self.shortID(session))]." } ?? "Finished in terminal “\(session.title)” [\(Self.shortID(session))]."
            return .text(status + "\n\n" + (lines.isEmpty ? "(no output)" : lines))
        }

        workspaceTool("terminal_list", "This project's terminals: title, id, and what runs in each.", object([:])) { _, project, _ in
            let terminals = project.terminals.filter { $0.agent == nil }
            guard !terminals.isEmpty else { return .text("No terminals open.") }
            return .text(terminals.map { "[\(Self.shortID($0))] \($0.title) — \($0.foregroundProcessName.map { "running \($0)" } ?? "idle")" }.joined(separator: "\n"))
        }

        workspaceTool("terminal_read", "The last lines of a terminal (default: the one Claude used last). Useful for a dev server's logs or a build the user started.",
                      object(["terminal": ["type": "string", "description": "Id or title from terminal_list"],
                              "lines": ["type": "integer", "description": "Default 80, at most 400"]])) { _, project, arguments in
            guard let session = Self.terminal(arguments["terminal"], in: project) else { return .error("No such terminal. Call terminal_list.") }
            let count = min(max((arguments["lines"] as? NSNumber)?.intValue ?? 80, 1), 400)
            let lines = session.view.bufferLines().suffix(count).joined(separator: "\n")
            return .text("[\(Self.shortID(session))] \(session.title) — \(session.foregroundProcessName.map { "running \($0)" } ?? "idle")\n\n\(lines)")
        }

        workspaceTool("terminal_stop", "Stop what runs in a terminal (Ctrl-C).",
                      object(["terminal": ["type": "string"]], required: ["terminal"])) { _, project, arguments in
            guard let session = Self.terminal(arguments["terminal"], in: project) else { return .error("No such terminal. Call terminal_list.") }
            session.interrupt()
            try? await Task.sleep(for: .milliseconds(500))
            return .text(session.foregroundProcessName.map { "Sent Ctrl-C; \($0) is still running." } ?? "Stopped.")
        }

        // MARK: Editor

        workspaceTool("editor_context", "What the user is looking at in Tezgah's editor: the current file, cursor line, and selected text with its lines. Use it when they say \"this\", \"here\" or \"the selection\".",
                      object([:])) { _, project, _ in
            var lines: [String] = []
            if let document = project.currentEditor {
                lines.append("Current file: \(document.url.path)" + (document.isDirty ? " (unsaved changes)" : ""))
                if let context = document.cursorContext {
                    lines.append("Cursor: line \(context.line), column \(context.column)")
                    if let selection = context.selection, let range = context.selectionLines {
                        let shown = selection.count > 20_000 ? String(selection.prefix(20_000)) + "\n…" : selection
                        lines.append("Selection (lines \(range.lowerBound)–\(range.upperBound)):\n```\n\(shown)\n```")
                    } else {
                        lines.append("Nothing selected.")
                    }
                }
            } else {
                lines.append("No file open in the editor.")
            }
            let others = project.documents.filter { $0.id != project.currentEditor?.id }
            if !others.isEmpty {
                lines.append("Other open files: " + others.map { project.relativePath(of: $0.url) + ($0.isDirty ? " •" : "") }.joined(separator: ", "))
            }
            return .text(lines.joined(separator: "\n"))
        }
    }

    // MARK: Helpers

    private func workspaceTool(
        _ name: String, _ description: String, _ schema: [String: any Sendable],
        run: @escaping @MainActor (WorkspaceStore, Project, [String: Any]) async -> MCPToolResult
    ) {
        mcpServer.register(MCPTool(name: name, description: description, inputSchema: schema) { [weak self] arguments, tab in
            guard let self, let (_, project) = self.claudeTab(tab) else { return .error("This Claude session is not in Tezgah anymore.") }
            var arguments = arguments
            arguments["__tab"] = tab
            return await run(self, project, arguments)
        })
    }

    /// The connection by name (or the only one), on the agents' own session.
    func databaseSession(_ name: Any?, project: Project) -> DatabaseSession? {
        let wanted = (name as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        let config: DatabaseConfig?
        if let wanted, !wanted.isEmpty {
            config = project.databases.first { $0.name.lowercased() == wanted }
                ?? project.databases.first { $0.name.lowercased().contains(wanted) || $0.summary.lowercased().contains(wanted) }
        } else {
            config = project.databases.count == 1 ? project.databases.first : nil
        }
        guard let config else { return nil }
        return agentDatabase(config, in: project)
    }

    /// Who an agent tab is: its role in an orchestra run, a lead's agent, or a session of its own.
    func agentName(_ tab: UUID) -> String {
        if let run = orchestraRun(of: tab) {
            let card = projects.lazy.compactMap { project in project.board.cards.first { $0.id == run.cardID } }.first
            return (agentRole(tab, in: run) ?? "Orkestra") + (card.map { " — \($0.title)" } ?? "")
        }
        if let worker = agentWorkers[tab] { return "Ajan “\(worker.name)” · \(worker.provider.displayName)" }
        guard let (session, _) = claudeTab(tab) else { return "Ajan" }
        return "\(session.agent?.provider.displayName ?? session.title) oturumu"
    }

    /// The tab's role in the run, with its agent and model.
    func agentRole(_ tab: UUID, in run: OrchestraRun) -> String? {
        if tab == run.plannerTab { return "Planlayıcı · \(run.team.planner.title)" }
        if tab == run.developerTab { return "Geliştirici · \(run.team.developer.title)" }
        if tab == run.judgeTab { return "Karar verici · \(run.team.judge.title)" }
        if let member = run.reviewers[tab] { return "Gözden geçiren · \(member.title)" }
        return nil
    }

    /// An orchestra agent's query goes into its card's story.
    func logQuery(_ sql: String, from tab: UUID, outcome: String, in project: Project) {
        guard let run = orchestraRun(of: tab) else { return }
        let lines = sql.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(8).joined(separator: "\n") + (lines.count > 8 ? "\n…" : "")
        logRun(run.cardID, in: project, .query, "\(agentRole(tab, in: run) ?? "Ajan") \(outcome)", detail: shown)
    }

    private static func connectionHelp(_ project: Project) -> String {
        if project.databases.isEmpty { return "No database connections in this project." }
        return "Say which connection: " + project.databases.map(\.name).joined(separator: ", ")
    }

    private static let readOnlyKeywords: Set<String> = ["select", "with", "explain", "show", "describe", "desc", "values", "table", "pragma"]

    /// Asks before an agent changes data or schema, showing exactly what will run and who asks;
    /// on the phone too when Telegram is paired, and whichever answers first counts.
    static func confirmWrite(_ statements: [String], connection: DatabaseConfig, agent: String?, telegram: TelegramBot? = nil) async -> Bool {
        let shown = statements.prefix(6).map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }.joined(separator: "\n\n")
        let title = "\(agent ?? "Bir ajan") veritabanını değiştirmek istiyor"
        let message = "Bağlantı: \(connection.name) (\(connection.summary))\n\n\(shown)"
            + (statements.count > 6 ? "\n\n… ve \(statements.count - 6) komut daha" : "")
        let id = UUID()
        telegram?.askApproval(id: id, text: title + "\n\n" + message) { approved in
            ConfirmSheet.answer(id, confirm: approved)
        }
        let approved = await ConfirmSheet.ask(
            title: title, message: message, confirm: "Çalıştır", cancel: "Reddet",
            destructive: statements.contains(where: SQLText.isDestructive), id: id
        )
        telegram?.approvalSettled(id: id, approved: approved)
        return approved
    }

    /// "12 satır", "3 satır değişti", "tamam", "hata: …" for each statement, for the card's story.
    /// Schema statements have no row count worth telling.
    static func summary(of results: [DatabaseSession.ResultItem], statements: [String]) -> String {
        guard !results.isEmpty else { return "sonuç yok" }
        let schemaKeywords: Set<String> = ["create", "drop", "alter", "rename", "truncate", "comment", "grant", "revoke"]
        return results.enumerated().map { index, item in
            if let error = item.error { return "hata: " + (error.split(separator: "\n").first.map(String.init) ?? error) }
            guard let result = item.result else { return "tamam" }
            if result.returnsRows { return "\(result.rows.count)\(result.isTruncated ? "+" : "") satır" }
            let keyword = index < statements.count ? SQLText.leadingKeyword(of: statements[index]) : ""
            guard !schemaKeywords.contains(keyword), let affected = result.affectedRows else { return "tamam" }
            return "\(affected) satır değişti"
        }.joined(separator: ", ")
    }

    private static func describe(_ results: [DatabaseSession.ResultItem], limit: Int) -> String {
        results.map { item in
            if let error = item.error { return "✗ \(item.title)\n  \(error)" }
            guard let result = item.result else { return "✓ \(item.title)" }
            guard result.returnsRows else { return "✓ \(item.title) — \(result.affectedRows.map { "\($0) rows affected" } ?? "done")" }
            var lines = ["✓ \(item.title) — \(result.rows.count)\(result.isTruncated ? "+" : "") rows", result.columns.joined(separator: " | ")]
            for row in result.rows.prefix(limit) {
                lines.append(row.map { value in
                    guard let value else { return "NULL" }
                    return value.count > 200 ? String(value.prefix(200)) + "…" : value.replacingOccurrences(of: "\n", with: "⏎")
                }.joined(separator: " | "))
            }
            if result.rows.count > limit { lines.append("… \(result.rows.count - limit) more rows (raise max_rows or narrow the query)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func shortID(_ session: TerminalSession) -> String {
        String(session.id.uuidString.prefix(6)).lowercased()
    }

    private static func terminal(_ reference: Any?, in project: Project) -> TerminalSession? {
        let terminals = project.terminals.filter { $0.agent == nil }
        guard let text = (reference as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")), !text.isEmpty else {
            return terminals.last { $0.runsClaudeCommands } ?? terminals.last
        }
        return terminals.first { shortID($0) == text.lowercased() || $0.id.uuidString.lowercased().hasPrefix(text.lowercased()) }
            ?? terminals.first { $0.title.caseInsensitiveCompare(text) == .orderedSame }
    }

    /// Output that appeared after `count` lines, capped to the last 200.
    private static func newLines(_ session: TerminalSession, since count: Int) -> String {
        let lines = session.view.bufferLines()
        let fresh = lines.count > count ? Array(lines[count...]) : Array(lines.suffix(40))
        return fresh.suffix(200).joined(separator: "\n")
    }
}
