import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Observation

/// A database tab: one connection, its schema, a SQL editor and the results of the last run.
@MainActor
@Observable
final class DatabaseSession: Identifiable {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// One result pane: rows, a row count, a plan or an error, for one statement.
    struct ResultItem: Identifiable {
        let id = UUID()
        let title: String
        var result: QueryResult?
        var error: String?
        var duration: TimeInterval = 0
        var plan: QueryPlan?
        /// Rows of the table being browsed: editable, pageable, sortable.
        var isBrowse = false
        /// Where in the editor the error is, for "go to error".
        var errorLocation: Int?
    }

    enum RunScope {
        /// The selection, or the statement under the cursor.
        case current
        case all
    }

    /// A statement to run and, when it came from the editor, where it is there.
    struct Statement {
        var sql: String
        var range: NSRange?
        var title: String?
        /// Typed by the user (goes to history, opens transactions); not a catalog or browse query.
        var isUserStatement = true
        /// The agent that ran it, for the history.
        var agent: String?
    }

    let id = UUID()
    private(set) var config: DatabaseConfig
    let projectURL: URL
    private(set) var state = ConnectionState.disconnected
    private(set) var tables: [SchemaTable] = []
    /// Columns and foreign keys too, for completion, editing and links between tables.
    private(set) var schema = DatabaseSchema()
    var tableFilter = ""
    private(set) var results: [ResultItem] = []
    var selectedResultID: UUID?
    private(set) var isRunning = false
    private(set) var runStartedAt: Date?
    /// A transaction is open on the connection (manual commit mode, or a BEGIN the user ran).
    private(set) var inTransaction = false
    /// The table shown in the result grid, when browsing one.
    private(set) var browse: TableBrowse?
    private(set) var edits = TableEdits()
    let history: QueryHistory
    /// The session agents run their queries on: outside the tabs, always committing by itself.
    let isForAgents: Bool

    @ObservationIgnored private var client: (any DatabaseClient)?
    @ObservationIgnored private var initialSQL: String
    @ObservationIgnored private var _controller: TextViewController?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var textObserver: NSObjectProtocol?
    @ObservationIgnored private lazy var completionProvider = SQLCompletionProvider(session: self)

    /// `history` is shared by the connection's sessions (the tab's and the agents'); without one,
    /// the session keeps its own in `historyDirectory`.
    init(
        config: DatabaseConfig, projectURL: URL, sql: String = "", historyDirectory: URL? = nil, history: QueryHistory? = nil,
        forAgents: Bool = false
    ) {
        self.config = config
        self.projectURL = projectURL
        initialSQL = sql
        self.history = history ?? QueryHistory(directory: historyDirectory, connectionID: config.id)
        isForAgents = forAgents
    }

    var title: String { config.name }
    var dialect: DatabaseConfig.Kind { config.kind }
    /// An agent's statement never waits in a transaction for a commit nobody gives.
    var autoCommit: Bool { isForAgents || (config.autoCommit ?? true) }

    var selectedResult: ResultItem? {
        results.first { $0.id == selectedResultID } ?? results.last
    }

    var filteredTables: [SchemaTable] {
        let filter = tableFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var hasKeyboardFocus: Bool {
        guard let textView = _controller?.textView,
              let responder = textView.window?.firstResponder as? NSView else { return false }
        return responder === textView || responder.isDescendant(of: textView)
    }

    /// The SQL in the editor, for saving the tab.
    var sql: String { _controller?.text ?? initialSQL }

    // MARK: Connection

    func connectIfNeeded() {
        guard state == .disconnected else { return }
        connect()
    }

    func connect() {
        guard state != .connecting else { return }
        state = .connecting
        let config = config
        let projectURL = projectURL
        Task {
            await client?.close()
            client = nil
            inTransaction = false
            do {
                let password = await Task.detached { DatabasePasswords.password(for: config.id) }.value
                let client = try await DatabaseConnector.connect(config, password: password, projectURL: projectURL)
                self.client = client
                state = .connected
                await reloadSchema()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Takes edited settings (from the connection sheet) and reconnects.
    func update(_ config: DatabaseConfig) {
        self.config = config
        disconnect()
        connect()
    }

    func disconnect() {
        let client = client
        self.client = nil
        state = .disconnected
        tables = []
        schema = DatabaseSchema()
        inTransaction = false
        Task { await client?.close() }
    }

    func close() {
        disconnect()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        textObserver = nil
    }

    /// Asks before closing over an open transaction or unsaved grid edits. False means "keep the tab".
    func confirmClosing() -> Bool {
        if !edits.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Tablodaki \(edits.count) değişiklik kaydedilmedi"
            alert.informativeText = "Kapatırsan bu değişiklikler kaybolur."
            alert.addButton(withTitle: "Kaydetmeden Kapat")
            alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        guard inTransaction else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(config.name)” üzerinde açık bir işlem (transaction) var"
        alert.informativeText = "Commit edilmeyen değişiklikler bağlantı kapanınca geri alınır."
        alert.addButton(withTitle: "Commit Et ve Kapat")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Geri Al ve Kapat")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let client {
                Task { _ = try? await client.execute("COMMIT") }
            }
            inTransaction = false
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func reloadTables() async {
        await reloadSchema()
    }

    /// Tables first (the sidebar), then columns and foreign keys (completion, editing, links).
    func reloadSchema() async {
        guard let client else { return }
        do {
            tables = try await client.tables()
        } catch {
            append(ResultItem(title: "Şema", error: error.localizedDescription))
            return
        }
        let tables = tables
        async let columns = try? client.allColumns()
        async let keys = try? client.foreignKeys()
        schema = DatabaseSchema(tables: tables, columns: await columns ?? [], foreignKeys: await keys ?? [])
    }

    // MARK: Running SQL

    func run(_ scope: RunScope) {
        guard let controller = _controller else { return }
        let text = controller.text as NSString
        let selection = controller.cursorPositions.first?.range ?? NSRange(location: 0, length: 0)
        let ranges: [NSRange]
        switch scope {
        case .all:
            ranges = SQLText.statementRanges(in: text as String)
        case .current where selection.length > 0:
            let selected = text.substring(with: selection)
            ranges = SQLText.statementRanges(in: selected).map { NSRange(location: $0.location + selection.location, length: $0.length) }
        case .current:
            ranges = SQLText.statementRange(at: selection.location, in: text as String).map { [$0] } ?? []
        }
        run(ranges.map { Statement(sql: text.substring(with: $0), range: $0) })
    }

    /// Runs SQL for a tool and waits for the results, connecting first if needed. The caller
    /// asks the user before anything that writes; nil results mean nothing ran.
    /// Connects if needed and waits; returns an error message if it could not.
    func ensureConnected() async -> String? {
        guard state != .connected else { return nil }
        if state != .connecting { connect() }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if state == .connected { return nil }
            if case .failed(let message) = state { return "Could not connect: \(message)" }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return "Connecting timed out."
    }

    func runAndWait(_ sql: String, agent: String? = nil) async -> (results: [ResultItem]?, error: String?) {
        if let error = await ensureConnected() { return (nil, error) }
        guard !isRunning else { return (nil, "A query is already running in this connection.") }
        let statements = SQLText.statementRanges(in: sql).map { (sql as NSString).substring(with: $0) }
            .map { Statement(sql: $0, title: "Ajan · " + Self.title(for: $0), agent: agent) }
        guard !statements.isEmpty else { return (nil, "No SQL statement found.") }
        run(statements, confirmed: true)
        guard isRunning else { return (nil, "Nothing ran (unsaved table edits were kept).") }
        while isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        return (results, nil)
    }

    func run(_ statements: [Statement], confirmed: Bool = false) {
        guard !statements.isEmpty, !isRunning else { return }
        let risky = statements.map(\.sql).filter(SQLText.isDestructive)
        if !confirmed, !risky.isEmpty {
            Task {
                if await confirmDestructive(risky) { run(statements, confirmed: true) }
            }
            return
        }
        guard confirmDiscardingEdits() else { return }
        guard let client else {
            connect()
            return
        }
        clearErrorMark()
        browse = nil
        edits = TableEdits()
        start()
        Task {
            var changedSchema = false
            for statement in statements {
                let title = statement.title ?? Self.title(for: statement.sql)
                let keyword = SQLText.leadingKeyword(of: statement.sql)
                if statement.isUserStatement, !autoCommit, !inTransaction, !Self.isTransactionControl(keyword) {
                    do {
                        _ = try await client.execute(dialect.beginTransaction)
                        inTransaction = true
                    } catch {
                        append(ResultItem(title: dialect.beginTransaction, error: error.localizedDescription))
                        break
                    }
                }
                let start = Date()
                do {
                    let result = try await client.execute(statement.sql)
                    let duration = Date().timeIntervalSince(start)
                    append(ResultItem(title: title, result: result, duration: duration))
                    noteTransactionControl(keyword)
                    changedSchema = changedSchema || ["create", "drop", "alter", "rename"].contains(keyword)
                    if statement.isUserStatement {
                        history.add(QueryHistoryEntry(sql: statement.sql, date: start, duration: duration,
                                                      rowCount: result.returnsRows ? result.rows.count : result.affectedRows,
                                                      agent: statement.agent))
                    }
                } catch {
                    let duration = Date().timeIntervalSince(start)
                    let position = (error as? DatabaseError)?.position
                    let location = statement.range.flatMap { range in position.map { range.location + $0 } }
                    append(ResultItem(title: title, error: error.localizedDescription, duration: duration, errorLocation: location))
                    if let location { markError(at: location) }
                    if statement.isUserStatement {
                        history.add(QueryHistoryEntry(sql: statement.sql, date: start, duration: duration, error: error.localizedDescription,
                                                      agent: statement.agent))
                    }
                    break // later statements may depend on this one
                }
            }
            finish()
            if changedSchema { await reloadSchema() }
        }
    }

    private func start() {
        isRunning = true
        runStartedAt = Date()
        results = []
    }

    private func finish() {
        isRunning = false
        runStartedAt = nil
    }

    /// Stops the running statement (pg_cancel_backend, KILL QUERY, sqlite3_interrupt).
    func cancel() {
        guard isRunning, let client else { return }
        Task { await client.cancel() }
    }

    func commit() { runTransactionControl("COMMIT") }
    func rollback() { runTransactionControl("ROLLBACK") }

    private func runTransactionControl(_ sql: String) {
        run([Statement(sql: sql, title: sql, isUserStatement: false)])
    }

    /// Turning auto-commit back on asks what to do with an open transaction first.
    func setAutoCommit(_ enabled: Bool) {
        if enabled, inTransaction {
            let alert = NSAlert()
            alert.messageText = "Açık işlem ne olsun?"
            alert.informativeText = "Otomatik commit'e geçmeden önce açık işlemi commit et ya da geri al."
            alert.addButton(withTitle: "Commit Et")
            alert.addButton(withTitle: "Geri Al")
            alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn: commit()
            case .alertSecondButtonReturn: rollback()
            default: return
            }
        }
        config.autoCommit = enabled ? nil : false
    }

    private static func isTransactionControl(_ keyword: String) -> Bool {
        ["begin", "start", "commit", "rollback", "end", "savepoint", "release", "set", "show", "use", "pragma"].contains(keyword)
    }

    private func noteTransactionControl(_ keyword: String) {
        switch keyword {
        case "begin", "start": inTransaction = true
        case "commit", "rollback", "end": inTransaction = false
        default: break
        }
    }

    // MARK: Explain and format

    /// Shows the plan of the selection or the statement under the cursor. ANALYZE (Postgres) runs it.
    func explain(analyze: Bool = false) {
        guard let statement = currentStatement(), let client, !isRunning else { return }
        if analyze, !["select", "with", "values", "table"].contains(SQLText.leadingKeyword(of: statement.sql)) {
            results = [ResultItem(title: "EXPLAIN ANALYZE", error: "EXPLAIN ANALYZE sorguyu gerçekten çalıştırır; yalnızca SELECT için kullanılabilir.")]
            return
        }
        let sql = QueryPlanner.explainSQL(for: statement.sql, dialect: dialect, analyze: analyze)
        let title = (analyze ? "Plan (ANALYZE) · " : "Plan · ") + Self.title(for: statement.sql)
        clearErrorMark()
        browse = nil
        start()
        Task {
            let started = Date()
            do {
                let result = try await client.execute(sql)
                if let plan = QueryPlanner.parse(result, dialect: dialect) {
                    append(ResultItem(title: title, duration: Date().timeIntervalSince(started), plan: plan))
                } else {
                    append(ResultItem(title: title, result: result, duration: Date().timeIntervalSince(started)))
                }
            } catch {
                // EXPLAIN adds a prefix, so the server's position is off by its length.
                let prefix = (sql as NSString).length - (statement.sql.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).length
                let position = (error as? DatabaseError)?.position
                let location = statement.range.flatMap { range in position.map { range.location + max($0 - prefix, 0) } }
                append(ResultItem(title: title, error: error.localizedDescription, errorLocation: location))
                if let location { markError(at: location) }
            }
            finish()
        }
    }

    /// Reformats the selection, or the statement under the cursor.
    func formatSQL() {
        guard let controller = _controller, let statement = currentStatement(), let range = statement.range else { return }
        let formatted = SQLFormatter.format(statement.sql, dialect: dialect)
        guard formatted != statement.sql else { return }
        controller.textView.replaceCharacters(in: range, with: formatted)
        controller.setCursorPositions([CursorPosition(range: NSRange(location: range.location + (formatted as NSString).length, length: 0))])
    }

    private func currentStatement() -> Statement? {
        guard let controller = _controller else { return nil }
        let text = controller.text as NSString
        let selection = controller.cursorPositions.first?.range ?? NSRange(location: 0, length: 0)
        if selection.length > 0 {
            return Statement(sql: text.substring(with: selection), range: selection)
        }
        return SQLText.statementRange(at: selection.location, in: text as String).map { Statement(sql: text.substring(with: $0), range: $0) }
    }

    // MARK: Errors in the editor

    func goToError(_ item: ResultItem) {
        guard let location = item.errorLocation else { return }
        markError(at: location)
    }

    /// Underlines the word at the error and puts the cursor there.
    private func markError(at location: Int) {
        guard let controller = _controller else { return }
        let text = controller.text as NSString
        let location = min(max(location, 0), text.length)
        var end = location
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
            end += 1
        }
        if end == location, end < text.length { end += 1 }
        let range = NSRange(location: location, length: end - location)
        controller.textView.emphasisManager?.replaceEmphases([Emphasis(range: range, style: .underline(color: .systemRed))], for: "sql-error")
        controller.setCursorPositions([CursorPosition(range: NSRange(location: location, length: 0))], scrollToVisible: true)
        controller.view.window?.makeFirstResponder(controller.textView)
    }

    private func clearErrorMark() {
        _controller?.textView.emphasisManager?.removeEmphases(for: "sql-error")
    }

    // MARK: Browsing tables

    func showRows(of table: SchemaTable) {
        guard confirmDiscardingEdits() else { return }
        loadBrowse(TableBrowse(table: table))
    }

    /// Changes the page, filter or sort, after checking for unsaved edits.
    func updateBrowse(_ change: (inout TableBrowse) -> Void) {
        guard var browse, confirmDiscardingEdits() else { return }
        change(&browse)
        loadBrowse(browse)
    }

    private func loadBrowse(_ browse: TableBrowse) {
        guard let client, !isRunning else { return }
        var browse = browse
        let previousCount = self.browse.flatMap { $0.table == browse.table && $0.filter == browse.filter ? $0.totalCount : nil }
        browse.totalCount = previousCount
        clearErrorMark()
        edits = TableEdits()
        start()
        Task {
            let started = Date()
            do {
                let result = try await client.execute(browse.sql(dialect: dialect))
                self.browse = browse
                append(ResultItem(title: browse.table.name, result: result, duration: Date().timeIntervalSince(started), isBrowse: true))
            } catch {
                self.browse = nil
                append(ResultItem(title: browse.table.name, error: error.localizedDescription))
                finish()
                return
            }
            finish()
            guard previousCount == nil else { return }
            if let count = try? await client.execute(browse.countSQL(dialect: dialect)), let cell = count.rows.first?.first, let text = cell,
               let total = Int(text), self.browse?.table == browse.table, self.browse?.filter == browse.filter {
                self.browse?.totalCount = total
            }
        }
    }

    /// What the grid needs to know to allow editing the browsed table.
    var browseColumns: [SchemaColumn] {
        browse.map { schema.columns(of: $0.table) } ?? []
    }

    /// Indexes of the primary key columns in the browsed result; empty means read-only.
    var browsePrimaryKey: [Int] {
        guard let browse, !browse.table.isView, let result = selectedResult?.result else { return [] }
        let keys = schema.primaryKey(of: browse.table)
        let indexes = keys.compactMap { key in result.columns.firstIndex(of: key) }
        return indexes.count == keys.count ? indexes : []
    }

    func setCell(row: Int, column: Int, value: String?) {
        guard let rows = selectedResult?.result?.rows else { return }
        edits.set(row: row, column: column, value: value, original: rows)
    }

    func deleteRows(_ rows: [Int]) {
        guard let count = selectedResult?.result?.rows.count else { return }
        let newRows = rows.filter { $0 >= count }
        edits.revert(rows: newRows, existingRows: count)
        for row in rows where row < count { edits.deletedRows.insert(row) }
    }

    func addRow() {
        edits.insertedRows.append([:])
    }

    func revertRows(_ rows: [Int]) {
        guard let count = selectedResult?.result?.rows.count else { return }
        edits.revert(rows: rows, existingRows: count)
    }

    func discardEdits() {
        edits = TableEdits()
    }

    /// The statements saving the grid edits would run.
    func editStatements() -> [String] {
        guard let browse, let result = selectedResult?.result else { return [] }
        return TableEditSQL.statements(table: browse.table, columns: result.columns, primaryKey: browsePrimaryKey,
                                       rows: result.rows, edits: edits, dialect: dialect)
    }

    /// Writes the grid edits in one transaction (or into the open one), then reloads the page.
    func saveEdits() {
        let statements = editStatements()
        guard !statements.isEmpty, let client, let browse, !isRunning else { return }
        let ownTransaction = !inTransaction
        start()
        Task {
            do {
                if ownTransaction { _ = try await client.execute(dialect.beginTransaction) }
                for statement in statements {
                    let result = try await client.execute(statement)
                    if let affected = result.affectedRows, affected != 1, !statement.hasPrefix("INSERT") {
                        throw DatabaseError(message: "Beklenen 1 satır yerine \(affected) satır etkilendi:\n\(statement)")
                    }
                }
                if ownTransaction { _ = try await client.execute("COMMIT") }
                for statement in statements {
                    history.add(QueryHistoryEntry(sql: statement, date: Date(), duration: 0, rowCount: 1))
                }
                finish()
                edits = TableEdits()
                var reloaded = browse
                reloaded.totalCount = nil
                self.browse = nil
                loadBrowse(reloaded)
            } catch {
                if ownTransaction { _ = try? await client.execute("ROLLBACK") }
                finish()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Değişiklikler kaydedilemedi"
                alert.informativeText = error.localizedDescription + (ownTransaction ? "\n\nHiçbir değişiklik yazılmadı." : "")
                alert.runModal()
            }
        }
    }

    /// False when the user wants to keep unsaved grid edits.
    private func confirmDiscardingEdits() -> Bool {
        guard !edits.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Tablodaki \(edits.count) değişiklik kaydedilmedi"
        alert.addButton(withTitle: "Değişiklikleri At")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        edits = TableEdits()
        return true
    }

    // MARK: Foreign keys

    /// The single-column foreign key a column of the browsed table belongs to.
    func foreignKey(forColumn name: String) -> ForeignKey? {
        guard let browse else { return nil }
        return schema.foreignKeys(from: browse.table).first { $0.columns == [name] }
    }

    /// Keys elsewhere that point at this table, by referenced column.
    func incomingKeys() -> [ForeignKey] {
        guard let browse else { return [] }
        return schema.foreignKeys(to: browse.table).filter { $0.columns.count == 1 }
    }

    /// Opens the referenced table filtered to the row a value points at (or the rows pointing at it).
    func follow(_ key: ForeignKey, value: String, outgoing: Bool) {
        let tableName = outgoing ? key.referencedTable : key.table
        let schemaName = outgoing ? key.referencedSchema : key.schema
        let column = outgoing ? key.referencedColumns[0] : key.columns[0]
        guard let table = schema.table(named: tableName, schema: schemaName), confirmDiscardingEdits() else { return }
        loadBrowse(TableBrowse(table: table, filter: "\(dialect.quoted(column)) = \(dialect.literal(value))"))
    }

    func showStructure(of table: SchemaTable) {
        guard let client, !isRunning, confirmDiscardingEdits() else { return }
        browse = nil
        start()
        Task {
            for (title, load) in [("\(table.name) · kolonlar", client.columns(of:)), ("\(table.name) · indeksler", client.indexes(of:))] {
                do {
                    append(ResultItem(title: title, result: try await load(table)))
                } catch {
                    append(ResultItem(title: title, error: error.localizedDescription))
                }
            }
            let keys = schema.foreignKeys(from: table) + schema.foreignKeys(to: table)
            if !keys.isEmpty {
                var result = QueryResult(columns: ["Ad", "Kolonlar", "Başvurduğu"])
                result.rows = keys.map { [$0.name, "\($0.table)(\($0.columns.joined(separator: ", ")))",
                                          "\($0.referencedTable)(\($0.referencedColumns.joined(separator: ", ")))"] }
                append(ResultItem(title: "\(table.name) · foreign key", result: result))
            }
            selectedResultID = results.first?.id
            finish()
        }
    }

    /// Puts text into the editor at the cursor, e.g. a table name from the schema list.
    func insert(_ text: String) {
        guard let controller = _controller else { return }
        let range = controller.cursorPositions.first?.range ?? NSRange(location: (controller.text as NSString).length, length: 0)
        controller.textView.replaceCharacters(in: range, with: text)
        controller.view.window?.makeFirstResponder(controller.textView)
    }

    /// Puts a statement from the history into the editor, on its own lines at the cursor.
    func insertFromHistory(_ entry: QueryHistoryEntry) {
        guard let controller = _controller else { return }
        let text = controller.text as NSString
        let location = controller.cursorPositions.first?.range.location ?? text.length
        let atLineStart = location == 0 || text.character(at: location - 1) == 0x0A
        var sql = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sql.hasSuffix(";") { sql += ";" }
        insert((atLineStart ? "" : "\n") + sql + "\n")
    }

    private func append(_ item: ResultItem) {
        results.append(item)
        selectedResultID = item.id
    }

    private func confirmDestructive(_ statements: [String]) async -> Bool {
        await ConfirmSheet.ask(
            title: "Veri silebilecek bir komut çalıştırılacak",
            message: statements.prefix(5).map { "• " + Self.title(for: $0) }.joined(separator: "\n")
                + "\n\nBağlantı: \(config.name) (\(config.summary))",
            confirm: "Çalıştır"
        )
    }

    private static func title(for statement: String) -> String {
        let line = statement.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("--") } ?? statement
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    // MARK: Editor

    func controller(theme: EditorTheme) -> TextViewController {
        if let _controller { return _controller }
        var configuration = EditorDocument.configuration(theme: theme, indentOption: .spaces(count: 2))
        configuration.peripherals.codeSuggestionTriggerCharacters = completionProvider.completionTriggerCharacters()
        let controller = TextViewController(
            string: initialSQL,
            language: .sql,
            configuration: configuration,
            cursorPositions: []
        )
        controller.completionDelegate = completionProvider
        initialSQL = ""
        _controller = controller
        installKeyMonitor()
        // The error underline belongs to the text as it was; editing removes it.
        textObserver = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification, object: controller.textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearErrorMark() }
        }
        return controller
    }

    /// While the SQL editor has focus: ⌘↩ runs the current statement and ⇧⌘↩ the whole script
    /// (elsewhere ⌘↩ keeps meaning "commit" in the git panel), ⌥⌘L formats, ⌘. cancels.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), hasKeyboardFocus else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 36, 76: // return, keypad enter
                run(flags.contains(.shift) ? .all : .current)
                return nil
            case 37 where flags == [.command, .option]: // L
                formatSQL()
                return nil
            case 47 where flags == [.command]: // .
                cancel()
                return nil
            default:
                return event
            }
        }
    }
}
