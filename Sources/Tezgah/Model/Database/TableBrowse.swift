import Foundation

/// Looking through one table's rows a page at a time, with an optional WHERE and ORDER BY.
struct TableBrowse: Equatable {
    var table: SchemaTable
    /// A WHERE condition as typed, e.g. `status = 'active' AND id > 10`.
    var filter = ""
    var sortColumn: String?
    var sortDescending = false
    var offset = 0
    var pageSize = 100
    /// Rows matching the filter; nil until counted.
    var totalCount: Int?

    func sql(dialect: DatabaseConfig.Kind) -> String {
        var sql = "SELECT * FROM \(dialect.qualifiedName(table))" + whereClause
        if let sortColumn {
            sql += " ORDER BY \(dialect.quoted(sortColumn))\(sortDescending ? " DESC" : "")"
        }
        sql += " LIMIT \(pageSize)"
        if offset > 0 { sql += " OFFSET \(offset)" }
        return sql
    }

    func countSQL(dialect: DatabaseConfig.Kind) -> String {
        "SELECT COUNT(*) FROM \(dialect.qualifiedName(table))" + whereClause
    }

    private var whereClause: String {
        let condition = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return condition.isEmpty ? "" : " WHERE \(condition)"
    }

    var hasPreviousPage: Bool { offset > 0 }

    func hasNextPage(shownRows: Int) -> Bool {
        if let totalCount { return offset + shownRows < totalCount }
        return shownRows >= pageSize
    }

    /// "1–100 / 2.345"
    func rangeText(shownRows: Int) -> String {
        let first = shownRows == 0 ? 0 : offset + 1
        let last = offset + shownRows
        let total = totalCount.map { $0.formatted() } ?? "…"
        return "\(first.formatted())–\(last.formatted()) / \(total)"
    }

    /// Header click: ascending, then descending, then unsorted.
    mutating func toggleSort(_ column: String) {
        if sortColumn != column {
            sortColumn = column
            sortDescending = false
        } else if !sortDescending {
            sortDescending = true
        } else {
            sortColumn = nil
            sortDescending = false
        }
        offset = 0
    }
}

/// Changes made in the grid that have not been written to the database yet.
struct TableEdits: Equatable {
    /// Row index → column index → new value (nil is NULL).
    var changes: [Int: [Int: String?]] = [:]
    var deletedRows: Set<Int> = []
    /// New rows: column index → value; columns left out get their default.
    var insertedRows: [[Int: String?]] = []

    var isEmpty: Bool { changes.isEmpty && deletedRows.isEmpty && insertedRows.isEmpty }

    var count: Int {
        changes.filter { !deletedRows.contains($0.key) }.count + deletedRows.count + insertedRows.count
    }

    /// Sets a cell of an existing row (`row < existingRows`) or of a new one.
    mutating func set(row: Int, column: Int, value: String?, original: [[String?]]) {
        if row >= original.count {
            let index = row - original.count
            guard insertedRows.indices.contains(index) else { return }
            insertedRows[index][column] = .some(value)
            return
        }
        if original[row][column] == value {
            changes[row]?[column] = nil
            if changes[row]?.isEmpty == true { changes[row] = nil }
        } else {
            changes[row, default: [:]][column] = .some(value)
        }
    }

    func value(row: Int, column: Int, original: [[String?]]) -> (value: String?, isChanged: Bool, isDefault: Bool) {
        if row >= original.count {
            let inserted = insertedRows[safe: row - original.count] ?? [:]
            if let value = inserted[column] { return (value, true, false) }
            return (nil, false, true)
        }
        if let change = changes[row]?[column] { return (change, true, false) }
        return (original[row][safe: column] ?? nil, false, false)
    }

    /// Undoes everything on these rows; new rows go away.
    mutating func revert(rows: [Int], existingRows: Int) {
        for row in rows where row < existingRows {
            changes[row] = nil
            deletedRows.remove(row)
        }
        let newRows = Set(rows.filter { $0 >= existingRows }.map { $0 - existingRows })
        insertedRows = insertedRows.enumerated().filter { !newRows.contains($0.offset) }.map(\.element)
    }
}

enum TableEditSQL {
    /// UPDATE / DELETE / INSERT statements for the edits, matching rows by primary key.
    static func statements(
        table: SchemaTable,
        columns: [String],
        primaryKey: [Int],
        rows: [[String?]],
        edits: TableEdits,
        dialect: DatabaseConfig.Kind
    ) -> [String] {
        let name = dialect.qualifiedName(table)
        func condition(_ row: [String?]) -> String {
            primaryKey.map { column in
                let value = row[column]
                return dialect.quoted(columns[column]) + (value == nil ? " IS NULL" : " = " + dialect.literal(value))
            }.joined(separator: " AND ")
        }

        var statements: [String] = []
        for row in edits.changes.keys.sorted() where !edits.deletedRows.contains(row) {
            guard let change = edits.changes[row], !change.isEmpty, rows.indices.contains(row) else { continue }
            let assignments = change.keys.sorted().map { column in
                dialect.quoted(columns[column]) + " = " + dialect.literal(change[column]!)
            }
            statements.append("UPDATE \(name) SET \(assignments.joined(separator: ", ")) WHERE \(condition(rows[row]))")
        }
        for row in edits.deletedRows.sorted() where rows.indices.contains(row) {
            statements.append("DELETE FROM \(name) WHERE \(condition(rows[row]))")
        }
        for inserted in edits.insertedRows {
            let set = inserted.keys.sorted()
            if set.isEmpty {
                statements.append(dialect == .mysql ? "INSERT INTO \(name) () VALUES ()" : "INSERT INTO \(name) DEFAULT VALUES")
            } else {
                let names = set.map { dialect.quoted(columns[$0]) }.joined(separator: ", ")
                let values = set.map { dialect.literal(inserted[$0]!) }.joined(separator: ", ")
                statements.append("INSERT INTO \(name) (\(names)) VALUES (\(values))")
            }
        }
        return statements
    }

    /// Whether a value shown in the grid is the real value, not a shortened one or a peek at binary data.
    static func isEditable(_ value: String?, type: String) -> Bool {
        let lowered = type.lowercased()
        if ["bytea", "blob", "binary", "varbinary"].contains(where: lowered.contains) { return false }
        guard let value else { return true }
        return value.count <= DatabaseLimits.maxValueLength
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
