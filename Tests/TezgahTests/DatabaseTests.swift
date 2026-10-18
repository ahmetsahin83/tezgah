import Foundation
import Testing
@testable import Tezgah

@Suite struct SQLTextTests {
    private func statements(_ text: String) -> [String] {
        SQLText.statementRanges(in: text).map { (text as NSString).substring(with: $0) }
    }

    @Test func splitsOnSemicolonsOutsideQuotesAndComments() {
        let script = """
        SELECT 'a;b', "c;d", `e;f`; -- trailing; comment
        /* block; comment */ UPDATE t SET x = 'it''s;' WHERE id = 1;

        -- only a comment;
        INSERT INTO t VALUES (1)
        """
        #expect(statements(script) == [
            #"SELECT 'a;b', "c;d", `e;f`"#,
            "-- trailing; comment\n/* block; comment */ UPDATE t SET x = 'it''s;' WHERE id = 1",
            "-- only a comment;\nINSERT INTO t VALUES (1)",
        ])
    }

    @Test func keepsPostgresDollarQuotedBodiesTogether() {
        let script = """
        CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql;
        DO $$ BEGIN PERFORM 1; END $$;
        SELECT $1, price$ FROM t
        """
        let found = statements(script)
        #expect(found.count == 3)
        #expect(found[0].hasSuffix("LANGUAGE plpgsql"))
        #expect(found[1] == "DO $$ BEGIN PERFORM 1; END $$")
    }

    @Test func statementUnderTheCursor() {
        let text = "SELECT 1;\nSELECT 2;\n\nSELECT 3"
        let second = SQLText.statementRange(at: 12, in: text).map { (text as NSString).substring(with: $0) }
        #expect(second == "SELECT 2")
        // On the empty line after "SELECT 2;": the statement before it.
        let after = SQLText.statementRange(at: 20, in: text).map { (text as NSString).substring(with: $0) }
        #expect(after == "SELECT 2")
    }

    @Test func classifiesStatements() {
        #expect(SQLText.returnsRows("  -- hi\n(SELECT 1)"))
        #expect(SQLText.returnsRows("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(SQLText.returnsRows("INSERT INTO t VALUES (1) RETURNING id"))
        #expect(!SQLText.returnsRows("UPDATE t SET a = 1"))
        #expect(SQLText.isDestructive("DELETE FROM users"))
        #expect(!SQLText.isDestructive("DELETE FROM users WHERE id = 1"))
        #expect(SQLText.isDestructive("drop table x"))
        #expect(!SQLText.isDestructive("SELECT * FROM drops"))
    }
}

@Suite struct DatabaseConfigTests {
    @Test func parsesConnectionURLs() throws {
        let (pg, password) = try #require(DatabaseConfig.parse(url: "postgresql://app:s%40cret@db.local:6543/shop?sslmode=disable"))
        #expect(pg.kind == .postgres)
        #expect(pg.host == "db.local")
        #expect(pg.effectivePort == 6543)
        #expect(pg.user == "app")
        #expect(pg.database == "shop")
        #expect(pg.tls == .disable)
        #expect(password == "s@cret")

        let (my, _) = try #require(DatabaseConfig.parse(url: "\"mysql://root@127.0.0.1/blog\""))
        #expect(my.kind == .mysql)
        #expect(my.effectivePort == 3306)

        let (lite, _) = try #require(DatabaseConfig.parse(url: "sqlite:///tmp/app.db"))
        #expect(lite.kind == .sqlite)
        #expect(lite.path == "/tmp/app.db")

        #expect(DatabaseConfig.parse(url: "redis://localhost") == nil)
    }

    @Test func findsURLsInEnvFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
        # comment
        export DATABASE_URL="postgres://u:p@localhost:5432/main"
        CACHE_URL=redis://localhost
        ANALYTICS_DATABASE_URL=mysql://a@localhost/stats
        """.utf8).write(to: folder.appendingPathComponent(".env"))

        let found = DatabaseConfig.fromEnvironmentFiles(in: folder)
        #expect(found.map(\.config.kind) == [.postgres, .mysql])
        #expect(found[0].config.name == "main")
        #expect(found[0].password == "p")
        #expect(found[1].config.name == "ANALYTICS_DATABASE_URL")
    }
}

/// Runs the same checks against every engine. SQLite always runs; Postgres and MySQL run when
/// TEZGAH_TEST_POSTGRES_URL / TEZGAH_TEST_MYSQL_URL (and optionally TEZGAH_TEST_MARIADB_URL) point at a server.
@Suite struct DatabaseClientTests {
    private func checkEngine(_ client: any DatabaseClient, quote: (String) -> String) async throws {
        let table = quote("tezgah_test_\(UUID().uuidString.prefix(8).lowercased())")
        _ = try await client.execute("CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name VARCHAR(50), price DECIMAL(10,2), note TEXT)")
        do {
            let inserted = try await client.execute("INSERT INTO \(table) (id, name, price, note) VALUES (1, 'çay', 12.50, NULL), (2, 'simit', 7.25, 'sıcak')")
            #expect(inserted.affectedRows == 2)
            #expect(!inserted.returnsRows)

            let rows = try await client.execute("SELECT id, name, price, note FROM \(table) ORDER BY id")
            #expect(rows.columns == ["id", "name", "price", "note"])
            #expect(rows.rows.count == 2)
            #expect(rows.rows[0][0] == "1")
            #expect(rows.rows[0][1] == "çay")
            #expect(rows.rows[0][2] == "12.50" || rows.rows[0][2] == "12.5")
            #expect(rows.rows[0][3] == nil)

            let empty = try await client.execute("SELECT id, name FROM \(table) WHERE id > 100")
            #expect(empty.rows.isEmpty)

            let updated = try await client.execute("UPDATE \(table) SET price = price + 1 WHERE id = 2")
            #expect(updated.affectedRows == 1)

            let unquoted = table.trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            let tables = try await client.tables()
            let found = try #require(tables.first { $0.name == unquoted })
            let columns = try await client.columns(of: found)
            #expect(columns.rows.map { $0[0] } == ["id", "name", "price", "note"])
            #expect(columns.rows[0][4]?.contains("PRIMARY") == true)
            _ = try await client.indexes(of: found)

            let limited = try await client.execute(client.selectAllSQL(from: found, limit: 1))
            #expect(limited.rows.count == 1)

            // Large results stop at the row limit, and the connection stays usable afterwards.
            // 1800 rows; MySQL caps recursion at 1000 levels by default, hence the cross join.
            let many = try await client.execute("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 900)
                SELECT a.i FROM n a CROSS JOIN (SELECT 1 AS x UNION ALL SELECT 2) b
                """)
            #expect(many.rows.count == DatabaseLimits.maxRows)
            #expect(many.isTruncated)
            let after = try await client.execute("SELECT 7 AS seven")
            #expect(after.rows == [["7"]])

            await #expect(throws: DatabaseError.self) {
                try await client.execute("SELEC nonsense")
            }
            // The connection keeps working after an error.
            let again = try await client.execute("SELECT COUNT(*) AS n FROM \(table)")
            #expect(again.rows.first?.first == "2")

            // Columns for completion know the table.
            let bare = table.trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            let schemaColumns = try await client.allColumns().filter { $0.table == bare }
            #expect(schemaColumns.map { $0.name } == ["id", "name", "price", "note"])
            #expect(schemaColumns.first?.isPrimaryKey == true)

            // The error position points into the statement.
            do {
                _ = try await client.execute("SELECT * FROM \(table) WHERE nosuchcolumn = 1")
            } catch let error as DatabaseError {
                #expect(error.position.map { $0 > 0 } ?? true)
            }
        } catch {
            _ = try? await client.execute("DROP TABLE \(table)")
            throw error
        }
        _ = try await client.execute("DROP TABLE \(table)")
    }

    @Test func sqlite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = try SQLiteClient(url: url)
        try await checkEngine(client, quote: SQLiteClient.identifier)
        let blob = try await client.execute("SELECT x'89504E47' AS b, 1.5 AS f")
        #expect(blob.rows[0][0]?.hasPrefix("0x89504E47") == true)
        await client.close()
    }

    /// Foreign keys and cancelling, on servers (SQLite has its own tests).
    private func checkServerExtras(_ client: any DatabaseClient, quote: (String) -> String, sleep: String) async throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let parent = "tezgah_parent_\(suffix)", child = "tezgah_child_\(suffix)"
        _ = try await client.execute("CREATE TABLE \(quote(parent)) (id INTEGER PRIMARY KEY)")
        _ = try await client.execute("CREATE TABLE \(quote(child)) (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES \(quote(parent))(id))")
        do {
            let keys = try await client.foreignKeys().filter { $0.table == child }
            #expect(keys.count == 1)
            #expect(keys.first?.columns == ["parent_id"])
            #expect(keys.first?.referencedTable == parent)
            #expect(keys.first?.referencedColumns == ["id"])

            let started = Date()
            let slow = Task { try await client.execute(sleep) }
            try await Task.sleep(for: .milliseconds(300))
            await client.cancel()
            await #expect(throws: DatabaseError.self) { _ = try await slow.value }
            #expect(Date().timeIntervalSince(started) < 4)
            // Still usable afterwards.
            #expect(try await client.execute("SELECT 1 AS one").rows == [["1"]])
        } catch {
            _ = try? await client.execute("DROP TABLE \(quote(child))")
            _ = try? await client.execute("DROP TABLE \(quote(parent))")
            throw error
        }
        _ = try await client.execute("DROP TABLE \(quote(child))")
        _ = try await client.execute("DROP TABLE \(quote(parent))")
    }

    @Test func postgres() async throws {
        guard let url = ProcessInfo.processInfo.environment["TEZGAH_TEST_POSTGRES_URL"],
              let (config, password) = DatabaseConfig.parse(url: url) else { return }
        let client = try await PostgresClient.connect(config, password: password)
        do {
            try await checkPostgres(client)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    private func checkPostgres(_ client: PostgresClient) async throws {
        try await checkEngine(client, quote: SQLiteClient.identifier)
        try await checkServerExtras(client, quote: SQLiteClient.identifier, sleep: "SELECT pg_sleep(10)")

        let types = try await client.execute("""
            SELECT true AS b, 42::int2, 9000000000::int8, 1.5::float8, 3.14159::numeric(10,5),
                   '2024-02-29'::date, '2024-02-29 13:45:06.25'::timestamp, '12:30:00'::time,
                   '1 year 2 mons 3 days 04:05:06'::interval, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid,
                   '{"a": [1, 2]}'::jsonb, ARRAY[1, 2, NULL]::int[], ARRAY['x y', 'z']::text[], '\\xDEADBEEF'::bytea,
                   '192.168.1.5'::inet, '10.0.0.0/8'::cidr, 'infinity'::timestamp, NULL::text, B'1011'::bit(4),
                   '(1.5,2)'::point
            """)
        #expect(types.rows.first == [
            "true", "42", "9000000000", "1.5", "3.14159",
            "2024-02-29", "2024-02-29 13:45:06.25", "12:30:00",
            "1 year 2 mons 3 days 04:05:06", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
            #"{"a": [1, 2]}"#, "{1,2,NULL}", #"{"x y",z}"#, types.rows.first?[13],
            "192.168.1.5", "10.0.0.0/8", "infinity", nil, "1011",
            "(1.5,2)",
        ])
        #expect(types.rows.first?[13]?.hasPrefix("0xDEADBEEF (4") == true)
        let enumResult = try await client.execute("SELECT 'happy'::text::name AS n")
        #expect(enumResult.rows.first?.first == "happy")
    }

    @Test func mysql() async throws {
        for key in ["TEZGAH_TEST_MYSQL_URL", "TEZGAH_TEST_MARIADB_URL"] {
            guard let url = ProcessInfo.processInfo.environment[key],
                  let (config, password) = DatabaseConfig.parse(url: url) else { continue }
            let client = try await MySQLClient.connect(config, password: password)
            do {
                try await checkEngine(client, quote: MySQLClient.identifier)
                try await checkServerExtras(client, quote: MySQLClient.identifier, sleep: "SELECT SLEEP(10)")
                let types = try await client.execute("SELECT CAST('2024-02-29 13:45:06' AS DATETIME) AS d, 0x41 AS bin, JSON_OBJECT('a', 1) AS j")
                #expect(types.rows.first?[0] == "2024-02-29 13:45:06")
                #expect(types.rows.first?[2]?.contains("\"a\"") == true)
            } catch {
                await client.close() // MySQLNIO asserts in debug builds when a connection is dropped open
                throw error
            }
            await client.close()
        }
    }
}

@MainActor
@Suite struct DatabaseSessionTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func runsStatementsInOrderAndStopsAtTheFirstError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("app.db").path, contents: nil)

        let session = DatabaseSession(
            config: DatabaseConfig(name: "app", kind: .sqlite, path: "app.db"), // relative to the project
            projectURL: folder
        )
        session.connect()
        try await waitUntil { session.state == .connected }

        session.run(statements("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)", "INSERT INTO items (name) VALUES ('a'), ('b')", "SELECT * FROM items"))
        try await waitUntil { !session.isRunning && session.results.count == 3 }
        #expect(session.results[1].result?.affectedRows == 2)
        #expect(session.results[2].result?.rows == [["1", "a"], ["2", "b"]])
        #expect(session.selectedResult?.id == session.results[2].id)
        // CREATE TABLE refreshed the schema list.
        try await waitUntil { session.tables.map(\.name) == ["items"] }

        session.run(statements("SELECT * FROM missing", "SELECT 1"))
        try await waitUntil { !session.isRunning && session.results.count == 1 }
        #expect(session.results[0].error?.contains("missing") == true)

        session.showStructure(of: session.tables[0])
        try await waitUntil { !session.isRunning && session.results.count == 2 }
        #expect(session.results[0].result?.rows.map { $0[0] } == ["id", "name"])
        #expect(session.history.entries.first?.sql == "SELECT * FROM missing")
        #expect(session.history.entries.first?.error != nil)
        session.close()
    }

    private func statements(_ sql: String...) -> [DatabaseSession.Statement] {
        sql.map { DatabaseSession.Statement(sql: $0) }
    }

    @Test func browsesEditsAndSavesATable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("app.db").path, contents: nil)
        let session = DatabaseSession(config: DatabaseConfig(name: "app", kind: .sqlite, path: "app.db"), projectURL: folder)
        session.connect()
        try await waitUntil { session.state == .connected }
        session.run(statements(
            "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, team_id INTEGER REFERENCES teams)",
            "CREATE TABLE teams (id INTEGER PRIMARY KEY, title TEXT)",
            "INSERT INTO teams VALUES (7, 'core')",
            "INSERT INTO people (name, team_id) VALUES ('a', 7), ('b', 7), ('c', NULL)"
        ))
        // The schema and the table list load separately; wait for both.
        try await waitUntil { !session.isRunning && session.schema.foreignKeys.count == 1 && session.tables.contains { $0.name == "people" } }

        let people = try #require(session.tables.first { $0.name == "people" })
        session.showRows(of: people)
        try await waitUntil { !session.isRunning && session.browse?.totalCount == 3 }
        #expect(session.selectedResult?.isBrowse == true)
        #expect(session.browsePrimaryKey == [0])

        session.updateBrowse { $0.toggleSort("name"); $0.sortDescending = true }
        try await waitUntil { !session.isRunning && session.selectedResult?.result?.rows.first?[1] == "c" }
        session.updateBrowse { $0.filter = "team_id = 7"; $0.totalCount = nil }
        try await waitUntil { !session.isRunning && session.browse?.totalCount == 2 }

        // Edit row "b", delete row "a", add one.
        let rows = try #require(session.selectedResult?.result?.rows)
        let b = try #require(rows.firstIndex { $0[1] == "b" })
        let a = try #require(rows.firstIndex { $0[1] == "a" })
        session.setCell(row: b, column: 1, value: "bee")
        session.deleteRows([a])
        session.addRow()
        session.setCell(row: rows.count, column: 1, value: "new")
        #expect(session.edits.count == 3)
        session.saveEdits()
        try await waitUntil { !session.isRunning && session.edits.isEmpty && session.browse?.totalCount == 1 }
        #expect(session.selectedResult?.result?.rows.map { $0[1] } == ["bee"])

        // Following the foreign key opens teams filtered to the row.
        let key = try #require(session.foreignKey(forColumn: "team_id"))
        session.follow(key, value: "7", outgoing: true)
        try await waitUntil { !session.isRunning && session.browse?.table.name == "teams" }
        #expect(session.selectedResult?.result?.rows == [["7", "core"]])

        session.updateBrowse { $0.filter = ""; $0.totalCount = nil }
        try await waitUntil { !session.isRunning && session.browse?.filter == "" }
        session.run(statements("SELECT name FROM people ORDER BY name"))
        try await waitUntil { !session.isRunning && session.results.count == 1 }
        #expect(session.selectedResult?.result?.rows == [["bee"], ["c"], ["new"]])
        session.close()
    }

    @Test func manualCommitKeepsATransactionOpen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("app.db").path, contents: nil)
        var config = DatabaseConfig(name: "app", kind: .sqlite, path: "app.db")
        config.autoCommit = false
        let session = DatabaseSession(config: config, projectURL: folder)
        session.connect()
        try await waitUntil { session.state == .connected }

        session.run(statements("CREATE TABLE t (x INTEGER)", "INSERT INTO t VALUES (1)"))
        try await waitUntil { !session.isRunning && session.results.count == 2 }
        #expect(session.inTransaction)
        session.rollback()
        try await waitUntil { !session.isRunning && !session.inTransaction }
        session.run(statements("SELECT name FROM sqlite_master WHERE name = 't'"))
        try await waitUntil { !session.isRunning && session.results.count == 1 }
        #expect(session.selectedResult?.result?.rows.isEmpty == true) // the CREATE was rolled back too
        session.close()
    }

    @Test func cancelsALongQuery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("app.db").path, contents: nil)
        let session = DatabaseSession(config: DatabaseConfig(name: "app", kind: .sqlite, path: "app.db"), projectURL: folder)
        session.connect()
        try await waitUntil { session.state == .connected }
        session.run(statements("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT COUNT(*) FROM c"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.isRunning)
        session.cancel()
        try await waitUntil { !session.isRunning }
        #expect(session.selectedResult?.error != nil)
        session.close()
    }

    @Test func failedConnectionsSayWhy() async throws {
        let session = DatabaseSession(
            config: DatabaseConfig(name: "nope", kind: .sqlite, path: "/nonexistent/x.db"),
            projectURL: URL(fileURLWithPath: "/")
        )
        session.connect()
        try await waitUntil { if case .failed = session.state { true } else { false } }
        if case .failed(let message) = session.state {
            #expect(message.contains("/nonexistent/x.db"))
        }
    }
}
