import CodeEditLanguages
import CodeEditSourceEditor
import Foundation
import SwiftTreeSitter

/// A colored run inside one diff line.
struct DiffSpan: Equatable, Sendable {
    /// UTF-16 offsets within the line's text.
    let range: Range<Int>
    let capture: CaptureName
}

/// Syntax-colors diffs with the same tree-sitter grammars as the editor.
///
/// Each file's old side (context + deleted lines) and new side (context + added lines) are
/// parsed as text of their own, so no extra git calls are needed. Hunks are only fragments of a
/// file, but tree-sitter recovers well from the missing parts.
enum DiffHighlighter {
    /// A grammar for one file. Tree-sitter languages and compiled queries are immutable and
    /// documented as safe to share between threads; each highlight run uses its own parser.
    struct Grammar: @unchecked Sendable {
        let language: Language
        let query: Query
    }

    /// Looks up grammars by file extension. Main actor only: the shared query cache is not thread-safe.
    @MainActor
    static func grammars(for diff: ParsedDiff) -> [Int: Grammar] {
        var grammars: [Int: Grammar] = [:]
        for (index, path) in diff.files.enumerated() {
            let codeLanguage = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
            guard codeLanguage.id != .plainText,
                  let language = codeLanguage.language,
                  let query = TreeSitterModel.shared.query(for: codeLanguage.id) else { continue }
            grammars[index] = Grammar(language: language, query: query)
        }
        return grammars
    }

    /// The grammar for a file name, by extension; nil for plain text.
    @MainActor
    static func grammar(forFileName name: String) -> Grammar? {
        let codeLanguage = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: name))
        guard codeLanguage.id != .plainText,
              let language = codeLanguage.language,
              let query = TreeSitterModel.shared.query(for: codeLanguage.id) else { return nil }
        return Grammar(language: language, query: query)
    }

    static func highlights(for diff: ParsedDiff, grammars: [Int: Grammar]) -> [Int: [DiffSpan]] {
        var result: [Int: [DiffSpan]] = [:]
        let linesByFile = Dictionary(grouping: diff.lines.filter { $0.fileIndex != nil }) { $0.fileIndex! }

        for (fileIndex, grammar) in grammars {
            guard let lines = linesByFile[fileIndex] else { continue }
            // Deleted lines are colored from the old side; added and context lines from the new side.
            let oldSide = lines.filter { $0.kind == .context || $0.kind == .deletion }
            let newSide = lines.filter { $0.kind == .context || $0.kind == .addition }
            result.merge(spans(for: oldSide, keeping: [.deletion], grammar: grammar)) { $1 }
            result.merge(spans(for: newSide, keeping: [.context, .addition], grammar: grammar)) { $1 }
        }
        return result
    }

    private static func spans(for lines: [DiffLine], keeping kinds: Set<DiffLine.Kind>, grammar: Grammar) -> [Int: [DiffSpan]] {
        guard lines.contains(where: { kinds.contains($0.kind) }) else { return [:] }

        var text = ""
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            text += line.text
            text += "\n"
            offset += line.text.utf16.count + 1
        }

        let captures = captureMap(for: text, grammar: grammar)
        guard !captures.isEmpty else { return [:] }

        var result: [Int: [DiffSpan]] = [:]
        for (line, start) in zip(lines, starts) where kinds.contains(line.kind) {
            var spans: [DiffSpan] = []
            var runStart = 0
            let length = line.text.utf16.count
            while runStart < length {
                let capture = captures[start + runStart]
                var runEnd = runStart + 1
                while runEnd < length, captures[start + runEnd] == capture { runEnd += 1 }
                if let capture {
                    spans.append(DiffSpan(range: runStart..<runEnd, capture: capture))
                }
                runStart = runEnd
            }
            if !spans.isEmpty { result[line.id] = spans }
        }
        return result
    }

    /// The capture for every UTF-16 unit of `text`, resolved the way the editor does it:
    /// for identical ranges the lower-indexed (more specific) pattern wins, later ranges paint over earlier ones.
    static func captureMap(for text: String, grammar: Grammar) -> [CaptureName?] {
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil,
              let tree = parser.parse(text) else { return [] }

        let length = text.utf16.count
        var map = [CaptureName?](repeating: nil, count: length)
        var levels: [NSRange: Int] = [:]
        let captures = grammar.query.execute(in: tree)
            .resolve(with: .init(string: text))
            .flatMap(\.captures)
            .reversed()

        for capture in captures {
            let range = capture.range
            if let level = levels[range], level <= capture.index { continue }
            guard let name = CaptureName.fromString(capture.name) else { continue }
            levels[range] = capture.index
            let lower = max(0, range.location)
            let upper = min(length, range.location + range.length)
            guard lower < upper else { continue }
            for index in lower..<upper { map[index] = name }
        }
        return map
    }
}
