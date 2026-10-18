import Foundation

/// One piece of SQL text. Ranges are UTF-16 offsets into the lexed text, like NSRange elsewhere.
struct SQLToken: Equatable {
    enum Kind: Equatable {
        /// A keyword or an unquoted identifier.
        case word
        /// "name", `name` or [name].
        case quotedIdentifier
        case string
        case number
        case comment
        /// ( ) , ; .
        case punctuation
        case `operator`
    }

    var kind: Kind
    var range: NSRange
    var text: String

    /// Whether the token is the given keyword, ignoring case.
    func `is`(_ keyword: String) -> Bool {
        kind == .word && text.caseInsensitiveCompare(keyword) == .orderedSame
    }

    var upper: String { text.uppercased() }

    /// The identifier without its quotes, for words and quoted identifiers.
    var identifier: String? {
        switch kind {
        case .word:
            return text
        case .quotedIdentifier:
            guard text.count >= 2 else { return String(text.dropFirst()) }
            let close = text.last!
            let open = text.first!
            var inner = String(text.dropFirst())
            if close == (open == "[" ? "]" : open) { inner.removeLast() }
            return open == "[" ? inner : inner.replacingOccurrences(of: String(open) + String(open), with: String(open))
        default:
            return nil
        }
    }

    /// An identifier, string or comment the text ended inside of (no closing quote yet).
    var isUnterminated = false
}

/// Splits SQL into tokens, knowing each dialect's quotes and comments. Unclosed strings and
/// comments run to the end of the text, so callers can tell the cursor is inside one.
enum SQLLexer {
    static func tokens(in text: String, dialect: DatabaseConfig.Kind) -> [SQLToken] {
        let units = Array(text.utf16)
        var tokens: [SQLToken] = []
        var index = 0

        func unit(_ offset: Int) -> UInt16? {
            offset < units.count ? units[offset] : nil
        }
        func add(_ kind: SQLToken.Kind, from start: Int, unterminated: Bool = false) {
            let end = min(index, units.count)
            var token = SQLToken(kind: kind, range: NSRange(location: start, length: end - start),
                                 text: String(decoding: units[start..<end], as: UTF16.self))
            token.isUnterminated = unterminated
            tokens.append(token)
        }
        /// Reads up to the closing quote; a doubled quote is part of the text.
        func readQuoted(_ close: UInt16, backslashEscapes: Bool) -> Bool {
            index += 1
            while index < units.count {
                if backslashEscapes, units[index] == 0x5C {
                    index += 2
                    continue
                }
                if units[index] == close {
                    if unit(index + 1) == close, close != 0x5D {
                        index += 2
                        continue
                    }
                    index += 1
                    return true
                }
                index += 1
            }
            index = units.count
            return false
        }

        while index < units.count {
            let start = index
            let c = units[index]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x2D where unit(index + 1) == 0x2D, // --
                 0x23 where dialect == .mysql: // #
                while index < units.count, units[index] != 0x0A { index += 1 }
                add(.comment, from: start)
            case 0x2F where unit(index + 1) == 0x2A: // /*
                index += 2
                var closed = false
                while index < units.count {
                    if units[index] == 0x2A, unit(index + 1) == 0x2F {
                        index += 2
                        closed = true
                        break
                    }
                    index += 1
                }
                add(.comment, from: start, unterminated: !closed)
            case 0x27: // '
                let closed = readQuoted(0x27, backslashEscapes: dialect == .mysql)
                add(.string, from: start, unterminated: !closed)
            case 0x22: // "
                let closed = readQuoted(0x22, backslashEscapes: dialect == .mysql)
                // MySQL treats "…" as a string unless ANSI_QUOTES is on.
                add(dialect == .mysql ? .string : .quotedIdentifier, from: start, unterminated: !closed)
            case 0x60 where dialect != .postgres: // `
                let closed = readQuoted(0x60, backslashEscapes: false)
                add(.quotedIdentifier, from: start, unterminated: !closed)
            case 0x5B where dialect == .sqlite: // [name]
                let closed = readQuoted(0x5D, backslashEscapes: false)
                add(.quotedIdentifier, from: start, unterminated: !closed)
            case 0x24 where dialect == .postgres && dollarTagEnd(units, from: index) != nil:
                let tagEnd = dollarTagEnd(units, from: index)!
                let tag = Array(units[index...tagEnd])
                var search = tagEnd + 1
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
                add(.string, from: start, unterminated: !closed)
            case 0x28, 0x29, 0x2C, 0x3B: // ( ) , ;
                index += 1
                add(.punctuation, from: start)
            case 0x2E where !(unit(index + 1).map(isDigit) ?? false): // . but not the start of a number like .5
                index += 1
                add(.punctuation, from: start)
            case _ where isDigit(c) || (c == 0x2E && (unit(index + 1).map(isDigit) ?? false)):
                index += 1
                while index < units.count {
                    let u = units[index]
                    if isDigit(u) || u == 0x2E || u == 0x5F {
                        index += 1
                    } else if u == 0x65 || u == 0x45 { // exponent
                        index += 1
                        if let sign = unit(index), sign == 0x2B || sign == 0x2D { index += 1 }
                    } else if isWordUnit(u) {
                        index += 1 // 0x1F, 1abc: odd but keep it one token
                    } else {
                        break
                    }
                }
                add(.number, from: start)
            case _ where isWordStart(c):
                index += 1
                while index < units.count, isWordUnit(units[index]) { index += 1 }
                add(.word, from: start)
            default:
                index += 1
                // Two-character operators: :: <= >= <> != || -> ->> @> <@
                if let next = unit(index) {
                    let pair = String(decoding: [c, next], as: UTF16.self)
                    if ["::", "<=", ">=", "<>", "!=", "||", "->", "@>", "<@", ":="].contains(pair) {
                        index += 1
                        if pair == "->", unit(index) == 0x3E { index += 1 }
                    }
                }
                add(.operator, from: start)
            }
        }
        return tokens
    }

    /// The closing `$` of a `$tag$` opener at `start`, if there is one. `$1` parameters are not tags.
    private static func dollarTagEnd(_ units: [UInt16], from start: Int) -> Int? {
        if start > 0, isWordUnit(units[start - 1]) { return nil }
        var end = start + 1
        if end < units.count, isDigit(units[end]) { return nil }
        while end < units.count, isWordUnit(units[end]), units[end] != 0x24 { end += 1 }
        return end < units.count && units[end] == 0x24 ? end : nil
    }

    static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }

    static func isWordStart(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F || unit >= 0x80
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        isWordStart(unit) || isDigit(unit) || unit == 0x24
    }
}
