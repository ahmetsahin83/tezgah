import Foundation

/// What running one SQL statement produced.
struct QueryResult: Sendable, Equatable {
    var columns: [String] = []
    /// Values as display text; nil is SQL NULL.
    var rows: [[String?]] = []
    /// For INSERT / UPDATE / DELETE.
    var affectedRows: Int?
    /// More rows existed than `DatabaseLimits.maxRows`.
    var isTruncated = false

    var returnsRows: Bool { !columns.isEmpty }
}

enum DatabaseLimits {
    static let maxRows = 1000
    /// Longer values are cut in the grid; copying a cell gives the shortened text too.
    static let maxValueLength = 2000
}

struct DatabaseError: LocalizedError {
    let message: String
    /// Where in the statement the server says the problem is (UTF-16 offset), when it says.
    var position: Int?
    var errorDescription: String? { message }
}

/// A table or view in the schema browser.
struct SchemaTable: Hashable, Identifiable, Sendable {
    var schema: String
    var name: String
    var isView: Bool

    var id: String { "\(schema).\(name)" }
}

/// One open connection. Implementations serialize their own calls.
protocol DatabaseClient: Sendable {
    func execute(_ sql: String) async throws -> QueryResult
    func tables() async throws -> [SchemaTable]
    /// Columns of a table as a result set (name, type, nullable, default, key).
    func columns(of table: SchemaTable) async throws -> QueryResult
    func indexes(of table: SchemaTable) async throws -> QueryResult
    /// Every column of every table, in one query, for completion and the table editor.
    func allColumns() async throws -> [SchemaColumn]
    func foreignKeys() async throws -> [ForeignKey]
    /// `SELECT * … LIMIT n` in this database's dialect.
    func selectAllSQL(from table: SchemaTable, limit: Int) -> String
    /// Stops the statement that is running, if any. Safe to call while `execute` is waiting.
    func cancel() async
    func close() async
}

enum DatabaseConnector {
    static func connect(_ config: DatabaseConfig, password: String?, projectURL: URL) async throws -> any DatabaseClient {
        if config.kind != .sqlite, let ssh = config.ssh {
            let tunnel = try await SSHTunnel.open(ssh, to: config.host, port: config.effectivePort)
            var local = config
            local.host = "127.0.0.1"
            local.port = tunnel.localPort
            local.ssh = nil
            do {
                return TunneledClient(client: try await connect(local, password: password, projectURL: projectURL), tunnel: tunnel)
            } catch {
                tunnel.close()
                throw error
            }
        }
        switch config.kind {
        case .sqlite:
            return try SQLiteClient(url: config.fileURL(relativeTo: projectURL))
        case .postgres:
            return try await PostgresClient.connect(config, password: password)
        case .mysql:
            return try await MySQLClient.connect(config, password: password)
        }
    }
}

/// A client whose connection goes through an SSH tunnel; closing it closes the tunnel too.
struct TunneledClient: DatabaseClient {
    let client: any DatabaseClient
    let tunnel: SSHTunnel

    func execute(_ sql: String) async throws -> QueryResult { try await client.execute(sql) }
    func tables() async throws -> [SchemaTable] { try await client.tables() }
    func columns(of table: SchemaTable) async throws -> QueryResult { try await client.columns(of: table) }
    func indexes(of table: SchemaTable) async throws -> QueryResult { try await client.indexes(of: table) }
    func allColumns() async throws -> [SchemaColumn] { try await client.allColumns() }
    func foreignKeys() async throws -> [ForeignKey] { try await client.foreignKeys() }
    func selectAllSQL(from table: SchemaTable, limit: Int) -> String { client.selectAllSQL(from: table, limit: limit) }
    func cancel() async { await client.cancel() }
    func close() async {
        await client.close()
        tunnel.close()
    }
}

// MARK: SQL text

enum SQLText {
    /// Splits a script into statements on semicolons outside quotes, comments and Postgres
    /// dollar-quoted bodies. Returns UTF-16 ranges into `text`, trimmed, without empty statements.
    static func statementRanges(in text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var ranges: [NSRange] = []
        var start = 0
        var index = 0

        func unit(_ offset: Int) -> UInt16? {
            offset < units.count ? units[offset] : nil
        }
        func finish(at end: Int) {
            if let trimmed = trim(NSRange(location: start, length: end - start), in: units) {
                ranges.append(trimmed)
            }
        }

        while index < units.count {
            let c = units[index]
            switch c {
            case 0x27, 0x22, 0x60: // ' " `
                index += 1
                while index < units.count {
                    if units[index] == 0x5C, c != 0x22 { index += 2; continue } // backslash escapes (MySQL)
                    if units[index] == c {
                        if unit(index + 1) == c { index += 2; continue } // doubled quote
                        break
                    }
                    index += 1
                }
                index += 1
            case 0x2D where unit(index + 1) == 0x2D, // --
                 0x23: // # (MySQL comment)
                while index < units.count, units[index] != 0x0A { index += 1 }
            case 0x2F where unit(index + 1) == 0x2A: // /*
                index += 2
                while index < units.count, !(units[index] == 0x2A && unit(index + 1) == 0x2F) { index += 1 }
                index += 2
            case 0x24: // $tag$ … $tag$
                var end = index + 1
                while end < units.count, isTagUnit(units[end]) { end += 1 }
                if end < units.count, units[end] == 0x24, !(index > 0 && isTagUnit(units[index - 1])) {
                    let tag = Array(units[index...end])
                    var search = end + 1
                    var closed = false
                    while search + tag.count <= units.count {
                        if Array(units[search..<search + tag.count]) == tag {
                            index = search + tag.count
                            closed = true
                            break
                        }
                        search += 1
                    }
                    if !closed { index = units.count }
                } else {
                    index += 1
                }
            case 0x3B: // ;
                finish(at: index)
                index += 1
                start = index
            default:
                index += 1
            }
        }
        finish(at: min(index, units.count))
        return ranges
    }

    /// The statement the cursor is in (or right after), for "run current statement".
    static func statementRange(at location: Int, in text: String) -> NSRange? {
        let ranges = statementRanges(in: text)
        if let inside = ranges.first(where: { location >= $0.location && location <= NSMaxRange($0) }) {
            return inside
        }
        // Between statements: the one that ends before the cursor.
        return ranges.last { NSMaxRange($0) <= location } ?? ranges.first
    }

    /// The first keyword, skipping comments and parentheses: "select", "with", "update"…
    static func leadingKeyword(of statement: String) -> String {
        String(skippingComments(Substring(statement), alsoSkipping: "(").prefix { $0.isLetter }).lowercased()
    }

    private static func skippingComments(_ text: Substring, alsoSkipping extra: Character? = nil) -> Substring {
        var text = text
        while true {
            text = text.drop { $0.isWhitespace || $0 == extra }
            if text.hasPrefix("--") || text.hasPrefix("#") {
                text = text.drop { $0 != "\n" }
            } else if text.hasPrefix("/*") {
                guard let end = text.range(of: "*/") else { return "" }
                text = text[end.upperBound...]
            } else {
                return text
            }
        }
    }

    /// Whether a statement produces rows (as opposed to only a row count or nothing).
    static func returnsRows(_ statement: String) -> Bool {
        switch leadingKeyword(of: statement) {
        case "select", "with", "show", "describe", "desc", "explain", "values", "table", "pragma", "call", "fetch":
            return true
        default:
            return statement.range(of: #"\breturning\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Statements worth a second look before running: dropping or emptying tables, and
    /// UPDATE / DELETE without a WHERE clause.
    static func isDestructive(_ statement: String) -> Bool {
        switch leadingKeyword(of: statement) {
        case "drop", "truncate":
            return true
        case "delete", "update":
            return statement.range(of: #"\bwhere\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        default:
            return false
        }
    }

    /// 'it''s' — a string literal for building catalog queries.
    static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// "t" / "1" / "true" / "YES" from a catalog query, whatever the driver made of a boolean.
    static func flag(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return ["t", "true", "1", "yes", "y"].contains(value)
    }

    /// The UTF-16 offset of the `characterIndex`-th character (Unicode scalar), as Postgres counts them.
    static func utf16Offset(ofScalar characterIndex: Int, in text: String) -> Int {
        text.unicodeScalars.prefix(max(characterIndex, 0)).reduce(0) { $0 + UTF16.width($1) }
    }

    /// The UTF-16 offset of a UTF-8 byte offset, as SQLite reports them.
    static func utf16Offset(ofUTF8 byteOffset: Int, in text: String) -> Int {
        let bytes = Array(text.utf8.prefix(max(byteOffset, 0)))
        return String(decoding: bytes, as: UTF8.self).utf16.count
    }

    static func shorten(_ value: String) -> String {
        value.count > DatabaseLimits.maxValueLength ? String(value.prefix(DatabaseLimits.maxValueLength)) + "…" : value
    }

    private static func isTagUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F || unit >= 0x80
    }

    private static func trim(_ range: NSRange, in units: [UInt16]) -> NSRange? {
        var start = range.location
        var end = NSMaxRange(range)
        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
        while start < end, isSpace(units[start]) { start += 1 }
        while end > start, isSpace(units[end - 1]) { end -= 1 }
        guard end > start else { return nil }
        // A "statement" that is only comments would run as nothing; skip it.
        let text = String(decoding: units[start..<end], as: UTF16.self)
        guard !skippingComments(Substring(text)).isEmpty else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// A value shared with driver callbacks that run on other threads.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLockedValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}
