import Foundation

/// Lays out queries one clause per line, keywords in upper case:
///
///     SELECT u.id,
///            u.name
///     FROM users u
///     LEFT JOIN orders o ON o.user_id = u.id
///     WHERE u.active
///       AND o.total > 10
///
/// Statements other than SELECT / INSERT / UPDATE / DELETE (DDL, PRAGMA…) only get their keywords upper-cased.
enum SQLFormatter {
    static func format(_ sql: String, dialect: DatabaseConfig.Kind) -> String {
        let text = sql as NSString
        let ranges = SQLText.statementRanges(in: sql)
        guard !ranges.isEmpty else { return sql }
        var parts: [String] = []
        for range in ranges {
            var formatted = formatStatement(text.substring(with: range), dialect: dialect)
            // Keep the semicolon if the statement had one.
            let after = NSMaxRange(range)
            let rest = text.substring(from: after).drop { $0.isWhitespace }
            if rest.hasPrefix(";") { formatted += ";" }
            parts.append(formatted)
        }
        return parts.joined(separator: "\n\n")
    }

    private static let keywords: Set<String> = SQLKeywords.reserved.union(SQLKeywords.clauses).union([
        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL", "BY", "ASC", "DESC", "LIMIT",
        "OFFSET", "RETURNING", "CONFLICT", "DO", "NOTHING", "NULLS", "RECURSIVE", "EXPLAIN", "ANALYZE", "IGNORE",
        "DUPLICATE", "INTERVAL", "FILTER", "ROWS", "RANGE", "PRECEDING", "FOLLOWING", "UNBOUNDED", "CURRENT",
        "ROW", "IF", "INDEX", "VIEW", "CASCADE", "RESTRICT", "ADD", "RENAME", "COLUMN", "TEMPORARY", "TEMP",
        "REPLACE", "PRAGMA", "KEY", "BEGIN", "COMMIT", "ROLLBACK", "TRUNCATE", "STRAIGHT_JOIN", "ALL", "SOME",
    ])
    private static let joinWords: Set<String> = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "JOIN", "STRAIGHT_JOIN"]

    private static func displayText(_ token: SQLToken, next: SQLToken?, functions: Set<String>) -> String {
        guard token.kind == .word else { return token.text }
        let upper = token.upper
        if keywords.contains(upper) || (next?.text == "(" && functions.contains(upper)) { return upper }
        return token.text
    }

    private static func formatStatement(_ statement: String, dialect: DatabaseConfig.Kind) -> String {
        let tokens = SQLLexer.tokens(in: statement, dialect: dialect)
        let functions = Set(SQLKeywords.functions(for: dialect))
        guard ["select", "with", "insert", "update", "delete", "replace", "values"].contains(SQLText.leadingKeyword(of: statement)) else {
            // Keep the author's layout; only upper-case keywords.
            let result = NSMutableString(string: statement)
            for (index, token) in tokens.enumerated().reversed() where token.kind == .word {
                result.replaceCharacters(in: token.range, with: displayText(token, next: tokens[safe: index + 1], functions: functions))
            }
            return result as String
        }

        struct Level {
            var isSubquery: Bool
            var base: Int
            var clause: String?
            var clauseDepth: Int
        }

        var out = ""
        var base = 0
        var clause: String?
        var clauseDepth = 0
        var stack: [Level] = []
        var previous: SQLToken?
        var breakBeforeNext = false
        var afterBetween = false
        var unaryNext = false

        /// Starts a new line; twice in a row only changes the indent.
        func lineBreak(_ spaces: Int) {
            while out.last == " " { out.removeLast() }
            guard !out.isEmpty else { return }
            if out.last == "\n" { out.removeLast() }
            out += "\n" + String(repeating: " ", count: max(spaces, 0))
        }
        func currentIndent() -> Int {
            let line = out.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            return line.prefix { $0 == " " }.count
        }
        /// Whether we are at the clause level (not inside a function call's or list's parentheses).
        func atClauseLevel() -> Bool {
            stack.last.map(\.isSubquery) ?? true
        }

        for (index, token) in tokens.enumerated() {
            let next = tokens[safe: index + 1]
            let text = displayText(token, next: next, functions: functions)
            let upper = token.kind == .word ? token.upper : ""

            if breakBeforeNext {
                lineBreak(base)
                breakBeforeNext = false
            }

            // Where a clause starts, begin a new line at the current indent.
            var startsClause = false
            if token.kind == .word, atClauseLevel() {
                let previousUpper = previous?.kind == .word ? previous!.upper : ""
                switch upper {
                case "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "RETURNING", "VALUES", "WINDOW",
                     "UNION", "INTERSECT", "EXCEPT", "INSERT", "WITH", "SET":
                    startsClause = !(upper == "FROM" && previousUpper == "DELETE")
                case "GROUP", "ORDER":
                    startsClause = next?.is("BY") ?? false
                case "UPDATE":
                    startsClause = !["DO", "FOR", "KEY"].contains(previousUpper)
                case "DELETE":
                    startsClause = previousUpper != "ON"
                case "ON":
                    startsClause = next?.is("CONFLICT") ?? false
                case _ where joinWords.contains(upper):
                    startsClause = !joinWords.contains(previousUpper) && previousUpper != "OUTER"
                default:
                    break
                }
            }
            if startsClause {
                if previous != nil, previous?.text != "(" {
                    lineBreak(base)
                } else if let last = out.last, last != " ", last != "\n", last != "(" {
                    out += " "
                }
                clause = upper == "GROUP" || upper == "ORDER" ? "\(upper) BY" : joinWords.contains(upper) ? "JOIN" : upper
                clauseDepth = stack.count
                out += text
                previous = token
                continue
            }

            if token.is("BETWEEN") { afterBetween = true }
            if (token.is("AND") || token.is("OR")), stack.count == clauseDepth,
               ["WHERE", "HAVING", "JOIN", "ON"].contains(clause ?? "") {
                if token.is("AND"), afterBetween {
                    afterBetween = false
                } else {
                    lineBreak(base + 2)
                    out += text
                    previous = token
                    continue
                }
            }

            switch (token.kind, token.text) {
            case (.punctuation, ","):
                out += ","
                if stack.count == clauseDepth, clause == "SELECT" {
                    lineBreak(base + 7)
                } else if stack.count == clauseDepth, clause == "SET" {
                    lineBreak(base + 4)
                } else if stack.count == clauseDepth, clause == "VALUES" {
                    lineBreak(base + 2)
                } else {
                    out += " "
                }
            case (.punctuation, "("):
                let isSubquery = next?.is("SELECT") == true || next?.is("WITH") == true
                if needsSpace(before: token, previous: previous, tokens: tokens, index: index),
                   let last = out.last, last != " ", last != "\n" { out += " " }
                out += "("
                stack.append(Level(isSubquery: isSubquery, base: base, clause: clause, clauseDepth: clauseDepth))
                if isSubquery {
                    base = currentIndent() + 2
                    lineBreak(base)
                }
            case (.punctuation, ")"):
                if let level = stack.popLast() {
                    if level.isSubquery { lineBreak(level.base) }
                    base = level.base
                    clause = level.clause
                    clauseDepth = level.clauseDepth
                }
                while out.last == " " { out.removeLast() }
                out += ")"
            case (.punctuation, "."), (.operator, "::"):
                while out.last == " " { out.removeLast() }
                out += token.text
            case (.punctuation, ";"):
                break
            case (.comment, _):
                if !out.isEmpty, out.last != "\n", out.last != " " { out += " " }
                out += token.text
                if token.text.hasPrefix("--") || token.text.hasPrefix("#") { breakBeforeNext = true }
            default:
                if needsSpace(before: token, previous: previous, tokens: tokens, index: index), !unaryNext,
                   let last = out.last, last != " ", last != "\n" { out += " " }
                unaryNext = false
                out += text
                // A sign right after an operator, comma or opening paren belongs to the number: -1, (+2).
                if token.kind == .operator, token.text == "-" || token.text == "+",
                   previous == nil || previous?.kind == .operator || previous?.text == "(" || previous?.text == ","
                    || (previous?.kind == .word && keywords.contains(previous!.upper)) {
                    unaryNext = true
                }
            }
            previous = token
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    private static func needsSpace(before token: SQLToken, previous: SQLToken?, tokens: [SQLToken], index: Int) -> Bool {
        guard let previous else { return false }
        if previous.text == "(" || previous.text == "." || previous.text == "::" { return false }
        if token.text == "(" {
            // count(…), my_function(…) — but IN (…), VALUES (…), INSERT INTO t (…) keep the space.
            if previous.kind == .word, !keywords.contains(previous.upper) {
                let beforeName = tokens[safe: index - 2]
                return beforeName?.is("INTO") == true || beforeName?.text == "." && tokens[safe: index - 4]?.is("INTO") == true
            }
            if previous.kind == .quotedIdentifier {
                return tokens[safe: index - 2]?.is("INTO") == true
            }
            if previous.text == ")" { return true }
        }
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
