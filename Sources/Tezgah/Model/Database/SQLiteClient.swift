import Foundation
import SQLite3

/// SQLite through the system library. Calls are serialized by the actor.
actor SQLiteClient: DatabaseClient {
    private var handle: OpaquePointer?
    /// The same handle, reachable while a statement runs: the actor is busy then, and
    /// sqlite3_interrupt is the one call that may come from another thread.
    private nonisolated let interruptHandle = LockedValue<OpaquePointer?>(nil)

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DatabaseError(message: "Dosya bulunamadı: \(url.path)")
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite açılamadı (\(status))"
            sqlite3_close(handle)
            throw DatabaseError(message: message)
        }
        // Wait a little instead of failing at once when another program holds a lock.
        sqlite3_busy_timeout(handle, 3000)
        self.handle = handle
        interruptHandle.withLockedValue { $0 = handle }
    }

    nonisolated func cancel() async {
        interruptHandle.withLockedValue { handle in
            if let handle { sqlite3_interrupt(handle) }
        }
    }

    func execute(_ sql: String) throws -> QueryResult {
        guard let handle else { throw DatabaseError(message: "Bağlantı kapalı.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let offset = Int(sqlite3_error_offset(handle))
            throw DatabaseError(message: String(cString: sqlite3_errmsg(handle)),
                                position: offset >= 0 ? SQLText.utf16Offset(ofUTF8: offset, in: sql) : nil)
        }
        defer { sqlite3_finalize(statement) }
        guard let statement else { return QueryResult() } // only whitespace or comments

        var result = QueryResult()
        let columnCount = Int(sqlite3_column_count(statement))
        result.columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                if step == SQLITE_INTERRUPT { throw DatabaseError(message: "Sorgu iptal edildi.") }
                throw DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
            }
            if result.rows.count >= DatabaseLimits.maxRows {
                result.isTruncated = true
                break
            }
            result.rows.append((0..<columnCount).map { Self.value(statement, Int32($0)) })
        }
        if columnCount == 0 {
            result.affectedRows = Int(sqlite3_changes(handle))
        }
        return result
    }

    func tables() throws -> [SchemaTable] {
        let result = try execute("""
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
            ORDER BY type DESC, name
            """)
        return result.rows.map { SchemaTable(schema: "main", name: $0[0] ?? "", isView: $0[1] == "view") }
    }

    func columns(of table: SchemaTable) throws -> QueryResult {
        let info = try execute("PRAGMA table_info(\(Self.identifier(table.name)))")
        var result = QueryResult(columns: ["Kolon", "Tip", "Boş olabilir", "Varsayılan", "Anahtar"])
        result.rows = info.rows.map { row in
            // cid, name, type, notnull, dflt_value, pk
            [row[1], row[2], row[3] == "1" ? "hayır" : "evet", row[4], (row[5] ?? "0") != "0" ? "PRIMARY" : nil]
        }
        return result
    }

    func indexes(of table: SchemaTable) throws -> QueryResult {
        try execute("""
            SELECT name AS "İndeks", COALESCE(sql, '(otomatik)') AS "Tanım" FROM sqlite_master
            WHERE type = 'index' AND tbl_name = \(SQLText.literal(table.name)) ORDER BY name
            """)
    }

    func allColumns() throws -> [SchemaColumn] {
        let result = try execute("""
            SELECT m.name, p.name, p.type, p."notnull", p.pk
            FROM sqlite_master m JOIN pragma_table_info(m.name) p
            WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite_%'
            ORDER BY m.name, p.cid
            """)
        return result.rows.map {
            SchemaColumn(schema: "main", table: $0[0] ?? "", name: $0[1] ?? "", type: $0[2] ?? "",
                         isNullable: $0[3] != "1", isPrimaryKey: ($0[4] ?? "0") != "0")
        }
    }

    func foreignKeys() throws -> [ForeignKey] {
        let result = try execute("""
            SELECT m.name, f.id, f."from", f."table", f."to"
            FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f
            WHERE m.type = 'table' ORDER BY m.name, f.id, f.seq
            """)
        // A missing "to" column means the referenced table's primary key.
        var primaryKeys: [String: [String]] = [:]
        func primaryKey(of table: String) throws -> [String] {
            if let known = primaryKeys[table] { return known }
            let info = try execute("PRAGMA table_info(\(Self.identifier(table)))")
            let names = info.rows.filter { ($0[5] ?? "0") != "0" }.sorted { Int($0[5] ?? "0") ?? 0 < Int($1[5] ?? "0") ?? 0 }.compactMap { $0[1] }
            primaryKeys[table] = names
            return names
        }
        var rows: [[String?]] = []
        var positionInKey: [String: Int] = [:]
        for row in result.rows {
            let table = row[0] ?? "", id = row[1] ?? "", target = row[3] ?? ""
            let key = "\(table)#\(id)"
            let position = positionInKey[key, default: 0]
            positionInKey[key] = position + 1
            let to = try row[4] ?? primaryKey(of: target)[safe: position] ?? ""
            rows.append([key, "main", table, row[2], "main", target, to])
        }
        return ForeignKey.grouping(rows)
    }

    nonisolated func selectAllSQL(from table: SchemaTable, limit: Int) -> String {
        "SELECT * FROM \(Self.identifier(table.name)) LIMIT \(limit);"
    }

    func close() {
        interruptHandle.withLockedValue { $0 = nil }
        sqlite3_close(handle)
        handle = nil
    }

    static func identifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func value(_ statement: OpaquePointer, _ column: Int32) -> String? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_blob(statement, column) else { return "‹boş blob›" }
            return DatabaseValueText.blob(Data(bytes: bytes, count: min(count, 64)), totalCount: count)
        default:
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return SQLText.shorten(String(cString: text))
        }
    }
}

enum DatabaseValueText {
    /// "0x89504E47… (12 KB)" — a peek at binary data.
    static func blob(_ prefix: Data, totalCount: Int) -> String {
        let hex = prefix.prefix(16).map { String(format: "%02X", $0) }.joined()
        let size = ByteCountFormatter.string(fromByteCount: Int64(totalCount), countStyle: .binary)
        return "0x\(hex)\(totalCount > 16 ? "…" : "") (\(size))"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
