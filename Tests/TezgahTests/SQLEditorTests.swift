import Foundation
import Testing
@testable import Tezgah

/// A shop schema: users ← orders ← order_items → products.
private let shop = DatabaseSchema(
    tables: [
        SchemaTable(schema: "public", name: "users", isView: false),
        SchemaTable(schema: "public", name: "orders", isView: false),
        SchemaTable(schema: "public", name: "order_items", isView: false),
        SchemaTable(schema: "public", name: "products", isView: false),
        SchemaTable(schema: "audit", name: "events", isView: false),
    ],
    columns: [
        SchemaColumn(schema: "public", table: "users", name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
        SchemaColumn(schema: "public", table: "users", name: "email", type: "text"),
        SchemaColumn(schema: "public", table: "users", name: "created_at", type: "timestamptz"),
        SchemaColumn(schema: "public", table: "orders", name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
        SchemaColumn(schema: "public", table: "orders", name: "user_id", type: "integer"),
        SchemaColumn(schema: "public", table: "orders", name: "total", type: "numeric"),
        SchemaColumn(schema: "public", table: "order_items", name: "order_id", type: "integer"),
        SchemaColumn(schema: "public", table: "order_items", name: "product_id", type: "integer"),
        SchemaColumn(schema: "public", table: "products", name: "id", type: "integer", isPrimaryKey: true),
        SchemaColumn(schema: "public", table: "products", name: "Name", type: "text"),
        SchemaColumn(schema: "audit", table: "events", name: "kind", type: "text"),
    ],
    foreignKeys: [
        ForeignKey(name: "orders_user_id_fkey", schema: "public", table: "orders", columns: ["user_id"],
                   referencedSchema: "public", referencedTable: "users", referencedColumns: ["id"]),
        ForeignKey(name: "items_order", schema: "public", table: "order_items", columns: ["order_id"],
                   referencedSchema: "public", referencedTable: "orders", referencedColumns: ["id"]),
        ForeignKey(name: "items_product", schema: "public", table: "order_items", columns: ["product_id"],
                   referencedSchema: "public", referencedTable: "products", referencedColumns: ["id"]),
    ]
)

/// Completions at the `|` in `text`, filtered by what is typed there.
private func complete(_ text: String, dialect: DatabaseConfig.Kind = .postgres, schema: DatabaseSchema = shop) -> [SQLCompletionItem]? {
    let cursor = (text as NSString).range(of: "|").location
    let source = text.replacingOccurrences(of: "|", with: "")
    guard let context = SQLCompletion.context(in: source, cursor: cursor, dialect: dialect) else { return nil }
    return SQLCompletion.filter(SQLCompletion.items(for: context, schema: schema, dialect: dialect), prefix: context.prefix)
}

private func labels(_ text: String, dialect: DatabaseConfig.Kind = .postgres) -> [String] {
    complete(text, dialect: dialect)?.map(\.label) ?? []
}

@Suite struct SQLLexerTests {
    @Test func tokensKnowQuotesPerDialect() {
        let pg = SQLLexer.tokens(in: #"SELECT "Na""me", 'it''s', $q$x;y$q$, 1.5e3 -- c"#, dialect: .postgres)
        #expect(pg.map(\.kind) == [.word, .quotedIdentifier, .punctuation, .string, .punctuation, .string, .punctuation, .number, .comment])
        #expect(pg[1].identifier == #"Na"me"#)

        let my = SQLLexer.tokens(in: #"SELECT `a b`, "str" # note"#, dialect: .mysql)
        #expect(my.map(\.kind) == [.word, .quotedIdentifier, .punctuation, .string, .comment])
        #expect(my[1].identifier == "a b")

        let lite = SQLLexer.tokens(in: "SELECT [x y] FROM t WHERE a <> b", dialect: .sqlite)
        #expect(lite[1].identifier == "x y")
        #expect(lite.contains { $0.text == "<>" && $0.kind == .operator })
    }

    @Test func unclosedStringsRunToTheEnd() {
        let tokens = SQLLexer.tokens(in: "SELECT 'abc", dialect: .postgres)
        #expect(tokens.last?.kind == .string)
        #expect(tokens.last?.isUnterminated == true)
    }
}

@Suite struct SQLCompletionTests {
    @Test func tablesAfterFromAndJoin() {
        #expect(labels("SELECT * FROM us|").first == "users")
        #expect(labels("SELECT * FROM |").contains("orders"))
        // Tables in another schema are inserted qualified.
        let events = complete("SELECT * FROM ev|")?.first
        #expect(events?.insertText == "audit.events")
        #expect(labels("UPDATE or|").first == "orders")
        #expect(labels("INSERT INTO pro|").first == "products")
        #expect(labels("SELECT * FROM users, |").contains("orders"))
    }

    @Test func columnsOfTheTablesInTheStatement() {
        let items = labels("SELECT | FROM users")
        #expect(Array(items.prefix(3)) == ["id", "email", "created_at"])
        #expect(!items.contains("total"))
        #expect(labels("SELECT id FROM users WHERE em|").first == "email")
        #expect(labels("SELECT id FROM users WHERE id = 1 AND cr|").first == "created_at")
        #expect(labels("UPDATE users SET em|").first == "email")
    }

    @Test func ambiguousColumnsAreQualified() throws {
        let item = try #require(complete("SELECT i| FROM users u JOIN orders o ON o.user_id = u.id")?.first { $0.label == "id" })
        #expect(item.insertText == "u.id")
        let unique = try #require(complete("SELECT tot| FROM users u JOIN orders o ON o.user_id = u.id")?.first)
        #expect(unique.insertText == "total")
    }

    @Test func membersAfterAliasOrTableDot() {
        #expect(labels("SELECT o.| FROM orders o") == ["id", "user_id", "total"])
        #expect(labels("SELECT orders.us| FROM orders") == ["user_id"])
        #expect(labels("SELECT * FROM users u WHERE u.e|").first == "email")
        // A schema name lists its tables.
        #expect(labels("SELECT * FROM audit.|") == ["events"])
    }

    @Test func insertColumnList() {
        #expect(labels("INSERT INTO orders (|") == ["id", "user_id", "total"])
        #expect(labels("INSERT INTO orders (id, |") == ["id", "user_id", "total"])
    }

    @Test func joinsAlongForeignKeys() {
        let joins = complete("SELECT * FROM orders o JOIN |")?.filter { $0.kind == .join }.map(\.insertText) ?? []
        #expect(joins.contains("users ON users.id = o.user_id"))
        #expect(joins.contains("order_items ON order_items.order_id = o.id"))
        #expect(complete("SELECT * FROM orders o JOIN |")?.first?.kind == .join)
    }

    @Test func expandsStar() throws {
        let item = try #require(complete("SELECT *| FROM orders")?.first)
        #expect(item.kind == .snippet)
        #expect(item.insertText == "id, user_id, total")
        #expect(item.replaceRange == NSRange(location: 7, length: 1))
    }

    @Test func quotesNamesThatNeedIt() throws {
        let item = try #require(complete("SELECT na| FROM products")?.first)
        #expect(item.label == "Name")
        #expect(item.insertText == #""Name""#)
        let mysql = try #require(complete("SELECT na| FROM products", dialect: .mysql)?.first)
        #expect(mysql.insertText == "Name")
    }

    @Test func keywordsFollowTheTypedCase() throws {
        #expect(complete("sel|")?.first?.insertText == "select")
        #expect(complete("SEL|")?.first?.insertText == "SELECT")
        let function = try #require(complete("SELECT coun| FROM users")?.first { $0.kind == .function })
        #expect(function.insertText == "count()")
        #expect(function.cursorBackOffset == 1)
    }

    @Test func fuzzyMatching() {
        #expect(labels("SELECT * FROM orit|").first == "order_items")
        #expect(labels("SELECT at| FROM users").first == "created_at") // a later word of the name
        #expect(labels("SELECT crat| FROM users").first == "created_at") // letters in order
    }

    @Test func silentInStringsCommentsAndNumbers() {
        #expect(complete("SELECT 'us|'") == nil)
        #expect(complete("SELECT 1 -- fr|") == nil)
        #expect(complete("SELECT * FROM users LIMIT 1|") == nil)
    }

    @Test func onlyTheStatementAtTheCursorCounts() {
        let items = labels("SELECT * FROM orders;\nSELECT | FROM users")
        #expect(items.contains("email"))
        #expect(!items.contains("total"))
    }

    @Test func commonTableExpressions() {
        #expect(labels("WITH recent AS (SELECT * FROM orders) SELECT * FROM rec|").first == "recent")
    }
}

@Suite struct SQLFormatterTests {
    @Test func oneClausePerLine() {
        let formatted = SQLFormatter.format(
            "select u.id, u.email, count(o.id) from users u left join orders o on o.user_id = u.id where u.id > 10 and o.total between 1 and 5 group by u.id order by 3 desc limit 10",
            dialect: .postgres
        )
        #expect(formatted == """
        SELECT u.id,
               u.email,
               COUNT(o.id)
        FROM users u
        LEFT JOIN orders o ON o.user_id = u.id
        WHERE u.id > 10
          AND o.total BETWEEN 1 AND 5
        GROUP BY u.id
        ORDER BY 3 DESC
        LIMIT 10
        """)
    }

    @Test func subqueriesAreIndented() {
        let formatted = SQLFormatter.format("SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE total > 5);", dialect: .postgres)
        #expect(formatted == """
        SELECT *
        FROM users
        WHERE id IN (
          SELECT user_id
          FROM orders
          WHERE total > 5
        );
        """)
    }

    @Test func insertAndUpdate() {
        #expect(SQLFormatter.format("insert into users (id, email) values (1, 'a'), (2, 'b')", dialect: .postgres) == """
        INSERT INTO users (id, email)
        VALUES (1, 'a'),
          (2, 'b')
        """)
        #expect(SQLFormatter.format("update users set email = 'x', created_at = now() where id = -1", dialect: .postgres) == """
        UPDATE users
        SET email = 'x',
            created_at = NOW()
        WHERE id = -1
        """)
    }

    @Test func leavesStringsCommentsAndDDLAlone() {
        #expect(SQLFormatter.format("select 'from x where' -- select from\nfrom t", dialect: .postgres) == """
        SELECT 'from x where' -- select from
        FROM t
        """)
        #expect(SQLFormatter.format("create table t (\n  id int primary key\n)", dialect: .postgres) == "CREATE TABLE t (\n  id int PRIMARY KEY\n)")
        #expect(SQLFormatter.format("select a::text, b.* from t union all select 1, 2", dialect: .postgres) == """
        SELECT a::text,
               b.*
        FROM t
        UNION ALL
        SELECT 1,
               2
        """)
    }
}

@Suite struct TableEditTests {
    private let table = SchemaTable(schema: "public", name: "users", isView: false)
    private let rows: [[String?]] = [["1", "a@x", nil], ["2", "it's", "x"]]

    @Test func buildsStatementsByPrimaryKey() {
        var edits = TableEdits()
        edits.set(row: 0, column: 1, value: "new@x", original: rows)
        edits.set(row: 0, column: 2, value: nil, original: rows) // unchanged: NULL stays NULL
        edits.set(row: 1, column: 2, value: nil, original: rows)
        edits.deletedRows.insert(1) // deleting wins over the edit
        edits.insertedRows.append([1: "c@x"])
        edits.insertedRows.append([:])
        #expect(edits.count == 4)

        let pg = TableEditSQL.statements(table: table, columns: ["id", "email", "note"], primaryKey: [0], rows: rows, edits: edits, dialect: .postgres)
        #expect(pg == [
            #"UPDATE "public"."users" SET "email" = 'new@x' WHERE "id" = '1'"#,
            #"DELETE FROM "public"."users" WHERE "id" = '2'"#,
            #"INSERT INTO "public"."users" ("email") VALUES ('c@x')"#,
            #"INSERT INTO "public"."users" DEFAULT VALUES"#,
        ])

        var quote = TableEdits()
        quote.set(row: 1, column: 1, value: #"back\slash 'q'"#, original: rows)
        let mysql = TableEditSQL.statements(table: table, columns: ["id", "email", "note"], primaryKey: [0], rows: rows, edits: quote, dialect: .mysql)
        #expect(mysql == [#"UPDATE `public`.`users` SET `email` = 'back\\slash ''q''' WHERE `id` = '2'"#])
    }

    @Test func settingTheOriginalValueUndoesTheChange() {
        var edits = TableEdits()
        edits.set(row: 0, column: 1, value: "changed", original: rows)
        edits.set(row: 0, column: 1, value: "a@x", original: rows)
        #expect(edits.isEmpty)
    }

    @Test func revertRemovesNewRows() {
        var edits = TableEdits()
        edits.insertedRows = [[0: "x"], [0: "y"]]
        edits.deletedRows = [0]
        edits.revert(rows: [0, 2], existingRows: 2)
        #expect(edits.deletedRows.isEmpty)
        #expect(edits.insertedRows == [[0: "y"]])
    }

    @Test func browseQueries() {
        var browse = TableBrowse(table: table, filter: "email LIKE '%@x'")
        browse.toggleSort("email")
        browse.offset = 200
        #expect(browse.sql(dialect: .postgres) == #"SELECT * FROM "public"."users" WHERE email LIKE '%@x' ORDER BY "email" LIMIT 100 OFFSET 200"#)
        #expect(browse.countSQL(dialect: .sqlite) == #"SELECT COUNT(*) FROM "users" WHERE email LIKE '%@x'"#)
        browse.toggleSort("email")
        #expect(browse.sortDescending)
        browse.toggleSort("email")
        #expect(browse.sortColumn == nil)
        #expect(browse.offset == 0)
        browse.totalCount = 250
        #expect(browse.hasNextPage(shownRows: 100))
        browse.offset = 200
        #expect(!browse.hasNextPage(shownRows: 50))
    }
}

@Suite struct QueryPlanTests {
    @Test func parsesPostgresJSON() throws {
        let json = """
        [{"Plan": {"Node Type": "Hash Join", "Join Type": "Inner", "Total Cost": 120.5, "Plan Rows": 40,
          "Hash Cond": "(o.user_id = u.id)",
          "Plans": [
            {"Node Type": "Seq Scan", "Relation Name": "orders", "Alias": "o", "Total Cost": 80, "Plan Rows": 1000,
             "Filter": "(total > 5)", "Actual Total Time": 0.5, "Actual Loops": 2, "Actual Rows": 10},
            {"Node Type": "Index Scan", "Index Name": "users_pkey", "Relation Name": "users", "Alias": "users", "Total Cost": 8}
          ]}, "Planning Time": 0.2, "Execution Time": 1.5}]
        """
        let plan = try #require(QueryPlanner.parse(QueryResult(columns: ["QUERY PLAN"], rows: [[json]]), dialect: .postgres))
        let rows = plan.flattened
        #expect(rows.map(\.node.title) == ["Hash Join (Inner)", "Seq Scan on orders o", "Index Scan using users_pkey on users"])
        #expect(rows.map(\.depth) == [0, 1, 1])
        #expect(rows[1].node.isFullScan)
        #expect(rows[1].node.actualTime == 1.0)
        #expect(rows[1].node.details.contains("Filter: (total > 5)"))
        #expect(plan.executionTime == 1.5)
        #expect(plan.maxCost == 120.5)
    }

    @Test func explainsSQLite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-plan-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try SQLiteClient(url: url)
        _ = try await client.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        let sql = QueryPlanner.explainSQL(for: "SELECT * FROM t WHERE name = 'x';", dialect: .sqlite, analyze: false)
        let plan = try #require(QueryPlanner.parse(try await client.execute(sql), dialect: .sqlite))
        #expect(plan.flattened.first?.node.isFullScan == true)
        let indexed = try #require(QueryPlanner.parse(try await client.execute(
            QueryPlanner.explainSQL(for: "SELECT * FROM t WHERE id = 1", dialect: .sqlite, analyze: false)), dialect: .sqlite))
        #expect(indexed.flattened.first?.node.isFullScan == false)
        await client.close()
    }

    @Test func parsesMySQLTable() throws {
        let result = QueryResult(
            columns: ["id", "select_type", "table", "type", "possible_keys", "key", "rows", "Extra"],
            rows: [["1", "SIMPLE", "orders", "ALL", nil, nil, "1000", "Using where"], ["1", "SIMPLE", "users", "eq_ref", "PRIMARY", "PRIMARY", "1", nil]]
        )
        let plan = try #require(QueryPlanner.parse(result, dialect: .mysql))
        #expect(plan.nodes.map(\.title) == ["orders — ALL", "users — eq_ref"])
        #expect(plan.nodes.map(\.isFullScan) == [true, false])
        #expect(plan.nodes[1].details.contains("Anahtar: PRIMARY"))
    }
}

@Suite struct DatabaseErrorPositionTests {
    @Test func mysqlNearText() {
        let sql = "SELECT 1;\nSELECT *\nFORM users"
        let message = "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'FORM users' at line 3 (1064)"
        #expect(MySQLClient.position(in: sql, message: message) == (sql as NSString).range(of: "FORM").location)
    }

    @Test func offsetsCountUTF16() {
        #expect(SQLText.utf16Offset(ofScalar: 2, in: "a😀b") == 3)
        #expect(SQLText.utf16Offset(ofUTF8: 5, in: "aöb c") == 4)
    }

    @Test func sqliteReportsWhere() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-err-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try SQLiteClient(url: url)
        let sql = "SELECT ğ, missing_column FROM sqlite_master"
        do {
            _ = try await client.execute(sql)
            Issue.record("expected an error")
        } catch let error as DatabaseError {
            #expect(error.position == 7) // the first unknown column, counted in UTF-16
        }
        await client.close()
    }
}

@Suite struct SQLiteSchemaTests {
    @Test func columnsAndForeignKeys() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-fk-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try SQLiteClient(url: url)
        _ = try await client.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL)")
        _ = try await client.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users, note TEXT)")
        let columns = try await client.allColumns()
        #expect(columns.map { "\($0.table).\($0.name)" } == ["orders.id", "orders.user_id", "orders.note", "users.id", "users.email"])
        #expect(columns.first { $0.name == "email" }?.isNullable == false)
        #expect(columns.filter(\.isPrimaryKey).count == 2)
        let keys = try await client.foreignKeys()
        #expect(keys.count == 1)
        #expect(keys.first?.columns == ["user_id"])
        #expect(keys.first?.referencedTable == "users")
        #expect(keys.first?.referencedColumns == ["id"]) // filled in from the primary key
        await client.close()
    }
}

@Suite struct QueryHistoryTests {
    @MainActor
    @Test func keepsNewestFirstWithoutRepeats() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let history = QueryHistory(directory: folder, connectionID: id)
        history.add(QueryHistoryEntry(sql: "SELECT 1", date: Date(), duration: 0.1, rowCount: 1))
        history.add(QueryHistoryEntry(sql: "SELECT 2", date: Date(), duration: 0.1, rowCount: 1))
        history.add(QueryHistoryEntry(sql: "SELECT 1", date: Date(), duration: 0.2, rowCount: 1))
        #expect(history.entries.map(\.sql) == ["SELECT 1", "SELECT 2"])
        #expect(history.search("2").map(\.sql) == ["SELECT 2"])

        // Saved in the background; a new instance reads it back.
        // Each add saves; wait for the last save rather than the first file to appear.
        var reloaded = QueryHistory(directory: folder, connectionID: id)
        for _ in 0..<200 {
            reloaded = QueryHistory(directory: folder, connectionID: id)
            reloaded.loadIfNeeded()
            if reloaded.entries.map(\.sql) == ["SELECT 1", "SELECT 2"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reloaded.entries.map(\.sql) == ["SELECT 1", "SELECT 2"])
    }
}

@Suite struct SSHTunnelTests {
    @Test func arguments() {
        let settings = SSHSettings(host: "bastion", port: 2222, user: "deploy", identityFile: "~/.ssh/id_test")
        let arguments = SSHTunnel.arguments(settings, localPort: 50000, host: "db.internal", port: 5432)
        #expect(arguments.starts(with: ["-N", "-L", "127.0.0.1:50000:db.internal:5432"]))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("2222"))
        #expect(arguments.contains((("~/.ssh/id_test") as NSString).expandingTildeInPath))
        #expect(arguments.last == "deploy@bastion")
    }

    @Test func failingTunnelsSayWhy() async throws {
        let settings = SSHSettings(host: "tezgah-no-such-host.invalid")
        await #expect(throws: DatabaseError.self) {
            _ = try await SSHTunnel.open(settings, to: "localhost", port: 5432)
        }
    }
}
