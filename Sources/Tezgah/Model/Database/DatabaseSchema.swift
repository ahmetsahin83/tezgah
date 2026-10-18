import Foundation

/// A column of some table, for completion and the table editor.
struct SchemaColumn: Hashable, Sendable {
    var schema: String
    var table: String
    var name: String
    var type: String
    var isNullable = true
    var isPrimaryKey = false

    var tableID: String { "\(schema).\(table)" }
}

/// A foreign key, one entry per constraint (several columns for composite keys).
struct ForeignKey: Hashable, Sendable {
    var name: String
    var schema: String
    var table: String
    var columns: [String]
    var referencedSchema: String
    var referencedTable: String
    var referencedColumns: [String]

    var tableID: String { "\(schema).\(table)" }
    var referencedTableID: String { "\(referencedSchema).\(referencedTable)" }

    /// Rows of (name, schema, table, column, referenced schema, referenced table, referenced column),
    /// one per column, ordered by constraint and position, folded into one key per constraint.
    static func grouping(_ rows: [[String?]]) -> [ForeignKey] {
        var keys: [ForeignKey] = []
        for row in rows where row.count >= 7 {
            let name = row[0] ?? "", schema = row[1] ?? "", table = row[2] ?? ""
            if let last = keys.last, last.name == name, last.schema == schema, last.table == table {
                keys[keys.count - 1].columns.append(row[3] ?? "")
                keys[keys.count - 1].referencedColumns.append(row[6] ?? "")
            } else {
                keys.append(ForeignKey(name: name, schema: schema, table: table, columns: [row[3] ?? ""],
                                       referencedSchema: row[4] ?? "", referencedTable: row[5] ?? "",
                                       referencedColumns: [row[6] ?? ""]))
            }
        }
        return keys
    }
}

/// Everything known about a connection's tables: loaded once after connecting and after DDL.
struct DatabaseSchema: Sendable, Equatable {
    var tables: [SchemaTable] = []
    /// Keyed by `SchemaTable.id`, in column order.
    var columns: [String: [SchemaColumn]] = [:]
    var foreignKeys: [ForeignKey] = []

    init(tables: [SchemaTable] = [], columns: [SchemaColumn] = [], foreignKeys: [ForeignKey] = []) {
        self.tables = tables
        self.columns = Dictionary(grouping: columns, by: \.tableID)
        self.foreignKeys = foreignKeys
    }

    var schemas: [String] {
        var seen: Set<String> = []
        return tables.map(\.schema).filter { seen.insert($0).inserted }
    }

    func columns(of table: SchemaTable) -> [SchemaColumn] {
        columns[table.id] ?? []
    }

    func primaryKey(of table: SchemaTable) -> [String] {
        columns(of: table).filter(\.isPrimaryKey).map(\.name)
    }

    /// A table by name, ignoring case; without a schema the first schema listed wins
    /// (the server lists the default one, e.g. public, first).
    func table(named name: String, schema: String? = nil) -> SchemaTable? {
        let matches = tables.filter { table in
            table.name.caseInsensitiveCompare(name) == .orderedSame
                && (schema.map { table.schema.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
        // An exact-case match beats a case-insensitive one ("Users" vs "users" in Postgres).
        return matches.first { $0.name == name } ?? matches.first
    }

    /// Foreign keys going out of a table.
    func foreignKeys(from table: SchemaTable) -> [ForeignKey] {
        foreignKeys.filter { $0.tableID == table.id }
    }

    /// Foreign keys in other tables that point at this one.
    func foreignKeys(to table: SchemaTable) -> [ForeignKey] {
        foreignKeys.filter { $0.referencedTableID == table.id }
    }
}

// MARK: Identifiers and literals per dialect

extension DatabaseConfig.Kind {
    /// The name, quoted only when it has to be: mixed case in Postgres, spaces, keywords…
    func identifier(_ name: String) -> String {
        needsQuotes(name) ? quoted(name) : name
    }

    func quoted(_ name: String) -> String {
        switch self {
        case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    func needsQuotes(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return true }
        let isPlain = (first == "_" || CharacterSet.letters.contains(first))
            && name.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || CharacterSet.alphanumerics.contains($0) }
            && name.unicodeScalars.allSatisfy(\.isASCII)
        if !isPlain { return true }
        // Postgres folds unquoted names to lower case, so "userId" must stay quoted.
        if self == .postgres, name != name.lowercased() { return true }
        return SQLKeywords.reserved.contains(name.uppercased())
    }

    /// `schema.table` (just `table` for SQLite, which has one schema per file).
    func qualifiedName(_ table: SchemaTable) -> String {
        self == .sqlite ? quoted(table.name) : quoted(table.schema) + "." + quoted(table.name)
    }

    /// A string literal; MySQL also treats backslashes as escapes.
    func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        var escaped = value.replacingOccurrences(of: "'", with: "''")
        if self == .mysql { escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + escaped + "'"
    }

    var beginTransaction: String { self == .mysql ? "START TRANSACTION" : "BEGIN" }
}
