import Foundation

/// One entry in the completion list.
struct SQLCompletionItem: Equatable {
    enum Kind: Equatable {
        case join, column, table, view, alias, schema, function, keyword, snippet
    }

    var label: String
    var insertText: String
    var detail: String?
    var kind: Kind
    /// Lower comes first when two items match the typed text equally well.
    var priority = 0
    /// How far back from the end of `insertText` the cursor goes: 1 puts it inside `count()`.
    var cursorBackOffset = 0
    /// Text replaced instead of the typed prefix, e.g. the `*` that becomes a column list.
    var replaceRange: NSRange?
}

/// A table named in the statement, with its alias.
struct SQLTableReference: Equatable {
    var schema: String?
    var name: String
    var alias: String?

    /// What the statement calls it: the alias, or the table name.
    var visibleName: String { alias ?? name }
}

/// What the cursor is in the middle of typing, worked out from the statement around it.
struct SQLCompletionContext: Equatable {
    enum Expectation: Equatable {
        /// Start of a statement, or after a complete expression: keywords.
        case keyword
        /// After FROM, JOIN, INTO, UPDATE…
        case table
        /// In a select list, WHERE, ON, SET…
        case column
        /// INSERT INTO t ( | — that table's columns.
        case insertColumns(SQLTableReference)
        /// After `name.` — the columns of a table or alias, or the tables of a schema.
        case qualified([String])
    }

    /// Typed so far, without an opening quote.
    var prefix: String
    /// The text a completion replaces, including an opening quote.
    var prefixRange: NSRange
    var expectation: Expectation
    var references: [SQLTableReference] = []
    /// Names from WITH name AS (…).
    var commonTableExpressions: [String] = []
    var isAfterJoin = false
    /// A `*` in a select list right before the cursor, which can be expanded to columns.
    var starRange: NSRange?
}

enum SQLCompletion {
    // MARK: Context

    /// Nil inside strings, comments and numbers, where nothing should pop up.
    static func context(in text: String, cursor: Int, dialect: DatabaseConfig.Kind) -> SQLCompletionContext? {
        let tokens = SQLLexer.tokens(in: text, dialect: dialect)

        // The statement around the cursor: between the semicolons on either side.
        let start = tokens.last { $0.text == ";" && $0.kind == .punctuation && NSMaxRange($0.range) <= cursor }
            .map { NSMaxRange($0.range) } ?? 0
        let end = tokens.first { $0.text == ";" && $0.kind == .punctuation && $0.range.location >= cursor }?
            .range.location ?? (text as NSString).length
        let statement = tokens.filter { $0.range.location >= start && NSMaxRange($0.range) <= end }

        var prefixStart = cursor
        var prefix = ""
        if let token = statement.first(where: { $0.range.location < cursor && cursor <= NSMaxRange($0.range) }) {
            let isLineComment = token.text.hasPrefix("--") || token.text.hasPrefix("#")
            let insideClosed = cursor < NSMaxRange(token.range)
            switch token.kind {
            case .string:
                if insideClosed || token.isUnterminated { return nil }
            case .comment:
                if insideClosed || token.isUnterminated || isLineComment { return nil }
            case .number:
                return nil
            case .word:
                prefixStart = token.range.location
                prefix = (text as NSString).substring(with: NSRange(location: prefixStart, length: cursor - prefixStart))
            case .quotedIdentifier:
                if insideClosed || token.isUnterminated {
                    prefixStart = token.range.location
                    let typed = (text as NSString).substring(with: NSRange(location: prefixStart + 1, length: cursor - prefixStart - 1))
                    prefix = typed
                }
            default:
                break
            }
        }

        let before = statement.filter { NSMaxRange($0.range) <= prefixStart && $0.kind != .comment }
        let code = statement.filter { $0.kind != .comment }
        var context = SQLCompletionContext(
            prefix: prefix,
            prefixRange: NSRange(location: prefixStart, length: cursor - prefixStart),
            expectation: .keyword
        )
        (context.references, context.commonTableExpressions) = references(in: code, excludingAt: prefixStart)
        context.expectation = expectation(before: before, context: &context)
        return context
    }

    private static func expectation(before: [SQLToken], context: inout SQLCompletionContext) -> SQLCompletionContext.Expectation {
        guard let previous = before.last else { return .keyword }

        if previous.kind == .punctuation, previous.text == "." {
            var parts: [String] = []
            var index = before.count - 2
            while index >= 0, let name = before[index].identifier {
                parts.insert(name, at: 0)
                guard index >= 2, before[index - 1].text == ".", before[index - 1].kind == .punctuation else { break }
                index -= 2
            }
            return parts.isEmpty ? .keyword : .qualified(parts)
        }

        if previous.kind == .word, SQLKeywords.tableIntroducers.contains(previous.upper) {
            context.isAfterJoin = previous.upper == "JOIN"
            return .table
        }

        if previous.text == "(" || previous.text == ",", let target = insertTarget(before) {
            return .insertColumns(target)
        }

        if previous.text == "," {
            return enclosingClause(before.dropLast()) == "FROM" ? .table : .column
        }
        if previous.text == "(" {
            return .column
        }

        if previous.kind == .operator {
            if previous.text == "*", before.count >= 2,
               before[before.count - 2].is("SELECT") || before[before.count - 2].text == "," || before[before.count - 2].is("DISTINCT") {
                context.starRange = previous.range
                return .keyword
            }
            return .column
        }

        if previous.kind == .word, SQLKeywords.expressionIntroducers.contains(previous.upper) {
            return .column
        }
        return .keyword
    }

    /// The clause keyword the cursor's list belongs to (FROM, SELECT, BY…), at the cursor's paren depth.
    private static func enclosingClause(_ tokens: ArraySlice<SQLToken>) -> String? {
        var depth = 0
        for token in tokens.reversed() {
            if token.text == ")" { depth += 1 }
            if token.text == "(" {
                if depth == 0 { return nil }
                depth -= 1
            }
            if depth == 0, token.kind == .word, SQLKeywords.clauses.contains(token.upper) || token.is("BY") {
                return token.upper
            }
        }
        return nil
    }

    /// INSERT INTO table ( a, b, | — the table, when the cursor is inside that column list.
    private static func insertTarget(_ tokens: [SQLToken]) -> SQLTableReference? {
        var depth = 0
        var openIndex: Int?
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            if token.text == ")" { depth += 1 }
            if token.text == "(" {
                if depth == 0 {
                    openIndex = index
                    break
                }
                depth -= 1
            }
        }
        guard let openIndex, openIndex >= 2 else { return nil }
        var parts: [String] = []
        var index = openIndex - 1
        while index >= 0, let name = tokens[index].identifier, !tokens[index].is("INTO") {
            parts.insert(name, at: 0)
            guard index >= 2, tokens[index - 1].text == "." else {
                index -= 1
                break
            }
            index -= 2
        }
        guard index >= 0, tokens[index].is("INTO"), let name = parts.last else { return nil }
        return SQLTableReference(schema: parts.count > 1 ? parts[parts.count - 2] : nil, name: name)
    }

    /// Tables after FROM / JOIN / UPDATE / INTO (and commas in a FROM list), and WITH names.
    /// The word being typed at `excludingAt` is not a reference yet.
    static func references(in tokens: [SQLToken], excludingAt location: Int = -1) -> ([SQLTableReference], [String]) {
        var references: [SQLTableReference] = []
        var ctes: [String] = []
        let notAlias = SQLKeywords.reserved.union(["STRAIGHT_JOIN", "FORCE", "USE", "IGNORE", "TABLESAMPLE", "INDEXED"])

        func isWordAt(_ index: Int, _ text: String) -> Bool {
            index < tokens.count && tokens[index].is(text)
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let name = token.identifier, isWordAt(index + 1, "AS"), index + 2 < tokens.count, tokens[index + 2].text == "(",
               index > 0, tokens[index - 1].is("WITH") || tokens[index - 1].is("RECURSIVE") || tokens[index - 1].text == "," {
                ctes.append(name)
            }
            guard token.is("FROM") || token.is("JOIN") || token.is("UPDATE") || token.is("INTO") else {
                index += 1
                continue
            }
            let isFromList = token.is("FROM")
            var cursor = index + 1
            while true {
                // ONLY (Postgres), and DELETE FROM skipping nothing else.
                if isWordAt(cursor, "ONLY") { cursor += 1 }
                guard cursor < tokens.count, tokens[cursor].range.location != location,
                      let first = tokens[cursor].identifier, tokens[cursor].kind == .quotedIdentifier || !notAlias.contains(first.uppercased())
                else { break }
                var parts = [first]
                cursor += 1
                while cursor + 1 < tokens.count, tokens[cursor].text == ".", tokens[cursor].kind == .punctuation,
                      let part = tokens[cursor + 1].identifier, tokens[cursor + 1].range.location != location {
                    parts.append(part)
                    cursor += 2
                }
                var reference = SQLTableReference(schema: parts.count > 1 ? parts[parts.count - 2] : nil, name: parts.last!)
                if isWordAt(cursor, "AS") { cursor += 1 }
                if cursor < tokens.count, tokens[cursor].range.location != location, let alias = tokens[cursor].identifier,
                   tokens[cursor].kind == .quotedIdentifier || !notAlias.contains(alias.uppercased()) {
                    reference.alias = alias
                    cursor += 1
                }
                references.append(reference)
                guard isFromList, cursor < tokens.count, tokens[cursor].text == "," else { break }
                cursor += 1
            }
            index = max(cursor, index + 1)
        }
        return (references, ctes)
    }

    // MARK: Items

    /// Everything that fits the context, before filtering by the typed prefix.
    static func items(for context: SQLCompletionContext, schema: DatabaseSchema, dialect: DatabaseConfig.Kind) -> [SQLCompletionItem] {
        let resolved = context.references.compactMap { reference in
            schema.table(named: reference.name, schema: reference.schema).map { (reference, $0) }
        }
        var items: [SQLCompletionItem] = []

        switch context.expectation {
        case .keyword:
            if let star = context.starRange, !resolved.isEmpty {
                let qualify = resolved.count > 1
                let names = resolved.flatMap { reference, table in
                    schema.columns(of: table).map { (qualify ? dialect.identifier(reference.visibleName) + "." : "") + dialect.identifier($0.name) }
                }
                if !names.isEmpty {
                    items.append(SQLCompletionItem(
                        label: "* → \(names.count) kolon", insertText: names.joined(separator: ", "),
                        detail: "Yıldızı kolon listesine aç", kind: .snippet, priority: -1, replaceRange: star
                    ))
                }
            }
            items += keywordItems(dialect, priority: 1)

        case .table:
            if context.isAfterJoin {
                items += joinItems(resolved, schema: schema, dialect: dialect)
            }
            items += tableItems(schema, dialect: dialect, priority: 1)
            items += context.commonTableExpressions.map {
                SQLCompletionItem(label: $0, insertText: dialect.identifier($0), detail: "WITH", kind: .table, priority: 1)
            }
            if dialect != .sqlite, schema.schemas.count > 1 {
                items += schema.schemas.map {
                    SQLCompletionItem(label: $0, insertText: dialect.identifier($0), detail: "şema", kind: .schema, priority: 2)
                }
            }

        case .column:
            if resolved.isEmpty {
                // No FROM yet (SELECT | …): every column, labelled with its table.
                for table in schema.tables {
                    items += schema.columns(of: table).map {
                        SQLCompletionItem(label: $0.name, insertText: dialect.identifier($0.name),
                                          detail: "\(table.name) · \($0.type)", kind: .column, priority: 2)
                    }
                }
            } else {
                let counts = Dictionary(resolved.flatMap { schema.columns(of: $0.1).map { ($0.name.lowercased(), 1) } }, uniquingKeysWith: +)
                for (reference, table) in resolved {
                    for column in schema.columns(of: table) {
                        let ambiguous = (counts[column.name.lowercased()] ?? 0) > 1
                        let name = dialect.identifier(column.name)
                        items.append(SQLCompletionItem(
                            label: column.name,
                            insertText: ambiguous ? dialect.identifier(reference.visibleName) + "." + name : name,
                            detail: "\(column.type) · \(reference.visibleName)",
                            kind: .column
                        ))
                    }
                }
                items += context.references.map {
                    SQLCompletionItem(label: $0.visibleName, insertText: dialect.identifier($0.visibleName),
                                      detail: $0.alias == nil ? "tablo" : $0.name, kind: .alias, priority: 1)
                }
            }
            items += functionItems(dialect, priority: 3)
            items += keywordItems(dialect, priority: 4)

        case .insertColumns(let reference):
            if let table = schema.table(named: reference.name, schema: reference.schema) {
                items = schema.columns(of: table).map {
                    SQLCompletionItem(label: $0.name, insertText: dialect.identifier($0.name), detail: $0.type, kind: .column)
                }
            }

        case .qualified(let parts):
            let last = parts.last ?? ""
            let parentSchema = parts.count > 1 ? parts[parts.count - 2] : nil
            let byAlias = parentSchema == nil
                ? resolved.first { $0.0.visibleName.caseInsensitiveCompare(last) == .orderedSame }?.1
                : nil
            if let table = byAlias ?? schema.table(named: last, schema: parentSchema) {
                items = schema.columns(of: table).map {
                    SQLCompletionItem(label: $0.name, insertText: dialect.identifier($0.name), detail: $0.type, kind: .column)
                }
            } else if schema.schemas.contains(where: { $0.caseInsensitiveCompare(last) == .orderedSame }) {
                items = schema.tables.filter { $0.schema.caseInsensitiveCompare(last) == .orderedSame }.map {
                    SQLCompletionItem(label: $0.name, insertText: dialect.identifier($0.name),
                                      detail: $0.isView ? "görünüm" : "tablo", kind: $0.isView ? .view : .table)
                }
            }
        }
        return items
    }

    private static func keywordItems(_ dialect: DatabaseConfig.Kind, priority: Int) -> [SQLCompletionItem] {
        SQLKeywords.keywords(for: dialect).map {
            SQLCompletionItem(label: $0, insertText: $0, kind: .keyword, priority: priority)
        }
    }

    private static func functionItems(_ dialect: DatabaseConfig.Kind, priority: Int) -> [SQLCompletionItem] {
        SQLKeywords.functions(for: dialect).map {
            SQLCompletionItem(label: $0, insertText: $0 + "()", detail: "fonksiyon", kind: .function, priority: priority, cursorBackOffset: 1)
        }
    }

    private static func tableItems(_ schema: DatabaseSchema, dialect: DatabaseConfig.Kind, priority: Int) -> [SQLCompletionItem] {
        let defaultSchema = schema.tables.first?.schema
        return schema.tables.map { table in
            let qualify = dialect != .sqlite && table.schema != defaultSchema
            return SQLCompletionItem(
                label: table.name,
                insertText: (qualify ? dialect.identifier(table.schema) + "." : "") + dialect.identifier(table.name),
                detail: (table.isView ? "görünüm" : "tablo") + (dialect == .sqlite ? "" : " · \(table.schema)"),
                kind: table.isView ? .view : .table,
                priority: priority
            )
        }
    }

    /// `orders ON orders.user_id = u.id` for each foreign key between a table already in the
    /// statement and one that is not.
    private static func joinItems(_ resolved: [(SQLTableReference, SchemaTable)], schema: DatabaseSchema,
                                  dialect: DatabaseConfig.Kind) -> [SQLCompletionItem] {
        let present = Set(resolved.map(\.1.id))
        var items: [SQLCompletionItem] = []
        func condition(_ left: String, _ leftColumns: [String], _ right: String, _ rightColumns: [String]) -> String {
            zip(leftColumns, rightColumns).map { "\(left).\(dialect.identifier($0)) = \(right).\(dialect.identifier($1))" }
                .joined(separator: " AND ")
        }
        for (reference, table) in resolved {
            let mine = dialect.identifier(reference.visibleName)
            for key in schema.foreignKeys(from: table) {
                guard let other = schema.table(named: key.referencedTable, schema: key.referencedSchema), !present.contains(other.id) else { continue }
                let name = dialect.identifier(other.name)
                let text = "\(name) ON " + condition(name, key.referencedColumns, mine, key.columns)
                items.append(SQLCompletionItem(label: text, insertText: text, detail: "foreign key", kind: .join, priority: 0))
            }
            for key in schema.foreignKeys(to: table) {
                guard let other = schema.table(named: key.table, schema: key.schema), !present.contains(other.id) else { continue }
                let name = dialect.identifier(other.name)
                let text = "\(name) ON " + condition(name, key.columns, mine, key.referencedColumns)
                items.append(SQLCompletionItem(label: text, insertText: text, detail: "foreign key", kind: .join, priority: 0))
            }
        }
        return items
    }

    // MARK: Filtering

    /// Items that match what was typed, best first: prefix matches, then word starts
    /// (`created_at` for "at"), then anywhere, then letters in order ("usid" → user_id).
    /// Keywords follow the case of the typed text.
    static func filter(_ items: [SQLCompletionItem], prefix: String, limit: Int = 200) -> [SQLCompletionItem] {
        let needle = prefix.lowercased()
        let lowercaseTyping = !prefix.isEmpty && prefix == needle && prefix.contains(where: \.isLetter)
        var scored: [(score: Int, index: Int, item: SQLCompletionItem)] = []
        var seen: Set<String> = []
        for (index, item) in items.enumerated() {
            let score = needle.isEmpty ? 0 : matchScore(item.label.lowercased(), needle)
            guard let score else { continue }
            var item = item
            if lowercaseTyping, item.kind == .keyword || item.kind == .function {
                item.insertText = item.insertText.lowercased()
            }
            guard seen.insert("\(item.label)|\(item.insertText)|\(item.detail ?? "")").inserted else { continue }
            scored.append((score, index, item))
        }
        // Nothing typed: keep the schema's order (columns as defined). Otherwise shorter names first.
        let byLength = !needle.isEmpty
        scored.sort { lhs, rhs in
            (lhs.score, lhs.item.priority, byLength ? lhs.item.label.count : 0, lhs.index)
                < (rhs.score, rhs.item.priority, byLength ? rhs.item.label.count : 0, rhs.index)
        }
        return scored.prefix(limit).map(\.item)
    }

    private static func matchScore(_ label: String, _ needle: String) -> Int? {
        if label.hasPrefix(needle) { return 0 }
        let words = label.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "." })
        if words.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if label.contains(needle) { return 2 }
        var remaining = Substring(needle)
        for character in label where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 3 }
        }
        return nil
    }
}
