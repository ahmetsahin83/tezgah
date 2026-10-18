import Foundation

struct DiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case fileHeader, hunkHeader, context, addition, deletion, info }

    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
    /// Index into `ParsedDiff.files` for code lines.
    var fileIndex: Int?
}

/// A unified diff (`git diff` / `git show` output) split into displayable lines.
struct ParsedDiff: Equatable, Sendable {
    static let maxBytes = 2 * 1024 * 1024

    let raw: String
    let lines: [DiffLine]
    /// Paths of the files in the diff, in order.
    let files: [String]
    let additions: Int
    let deletions: Int
    /// Length of the longest line in characters, for sizing the horizontal scroll area.
    let longestLine: Int
    /// Syntax colors per line id, filled in by `DiffHighlighter`.
    var highlights: [Int: [DiffSpan]] = [:]

    static func == (lhs: ParsedDiff, rhs: ParsedDiff) -> Bool { lhs.raw == rhs.raw }

    static func parse(_ data: Data, showFileHeaders: Bool) -> ParsedDiff {
        var truncated = false
        var data = data
        if data.count > maxBytes {
            data = data.prefix(maxBytes)
            truncated = true
        }
        let raw = String(decoding: data, as: UTF8.self)

        var lines: [DiffLine] = []
        var files: [String] = []
        var additions = 0
        var deletions = 0
        var longest = 0
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var combined = false

        func append(_ kind: DiffLine.Kind, _ text: String, old: Int? = nil, new: Int? = nil) {
            let text = text.replacingOccurrences(of: "\t", with: "    ")
            longest = max(longest, text.count)
            let isCode = kind == .context || kind == .addition || kind == .deletion
            lines.append(DiffLine(
                id: lines.count, kind: kind, oldNumber: old, newNumber: new, text: text,
                fileIndex: isCode && !files.isEmpty ? files.count - 1 : nil
            ))
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                inHunk = false
                let path = filePath(fromHeader: line)
                files.append(path)
                if showFileHeaders { append(.fileHeader, path) }
                continue
            }
            if line.hasPrefix("Binary files ") {
                append(.info, "İkili (binary) dosya değişti")
                continue
            }
            if line.hasPrefix("@@@") {
                // Combined diff of a merge conflict: two marker columns, only new line numbers.
                inHunk = true
                combined = true
                newLine = hunkStart(line, marker: "+") ?? 0
                append(.hunkHeader, line)
                continue
            }
            if line.hasPrefix("@@") {
                inHunk = true
                combined = false
                oldLine = hunkStart(line, marker: "-") ?? 0
                newLine = hunkStart(line, marker: "+") ?? 0
                append(.hunkHeader, line)
                continue
            }
            guard inHunk, !line.isEmpty else { continue }

            if line.hasPrefix("\\") {
                append(.info, "Dosya sonunda satır sonu yok")
                continue
            }

            if combined {
                let markers = line.prefix(2)
                let content = String(line.dropFirst(2))
                if markers.contains("+") {
                    append(.addition, content, new: newLine)
                    newLine += 1
                    additions += 1
                } else if markers.contains("-") {
                    append(.deletion, content)
                    deletions += 1
                } else {
                    append(.context, content, new: newLine)
                    newLine += 1
                }
                continue
            }

            let content = String(line.dropFirst())
            switch line.first {
            case "+":
                append(.addition, content, new: newLine)
                newLine += 1
                additions += 1
            case "-":
                append(.deletion, content, old: oldLine)
                oldLine += 1
                deletions += 1
            case " ":
                append(.context, content, old: oldLine, new: newLine)
                oldLine += 1
                newLine += 1
            default:
                // A new header line ends the hunk (e.g. the next file in `git show`).
                inHunk = false
            }
        }

        if truncated {
            append(.info, "Diff çok büyük, yalnızca ilk 2 MB gösteriliyor.")
        }
        return ParsedDiff(raw: raw, lines: lines, files: files, additions: additions, deletions: deletions, longestLine: longest)
    }

    /// "diff --git a/foo b/foo" → "foo"; "diff --cc foo" → "foo".
    private static func filePath(fromHeader line: String) -> String {
        if line.hasPrefix("diff --git "), let range = line.range(of: " b/", options: .backwards) {
            return String(line[range.upperBound...])
        }
        return line.split(separator: " ", maxSplits: 2).last.map(String.init) ?? line
    }

    /// Start line of the "-a,b" or "+c,d" range in a hunk header.
    private static func hunkStart(_ header: String, marker: Character) -> Int? {
        let token = header.split(separator: " ").first { $0.first == marker && $0.count > 1 }
        guard let token else { return nil }
        guard let start = token.dropFirst().split(separator: ",").first else { return nil }
        return Int(String(start))
    }
}
