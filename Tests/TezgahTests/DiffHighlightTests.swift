import CodeEditSourceEditor
import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct DiffHighlightTests {
    private func highlighted(_ diff: String, headers: Bool = false) -> ParsedDiff {
        var parsed = ParsedDiff.parse(Data(diff.utf8), showFileHeaders: headers)
        parsed.highlights = DiffHighlighter.highlights(for: parsed, grammars: DiffHighlighter.grammars(for: parsed))
        return parsed
    }

    /// The capture covering `token` in the first line containing it, if any.
    private func capture(of token: String, in diff: ParsedDiff, kind: DiffLine.Kind) -> CaptureName? {
        guard let line = diff.lines.first(where: { $0.kind == kind && $0.text.contains(token) }),
              let range = line.text.range(of: token) else { return nil }
        let start = range.lowerBound.utf16Offset(in: line.text)
        return diff.highlights[line.id]?.first { $0.range.contains(start) }?.capture
    }

    @Test func colorsAddedDeletedAndContextLines() {
        let diff = highlighted("""
        diff --git a/main.go b/main.go
        --- a/main.go
        +++ b/main.go
        @@ -1,5 +1,5 @@
         package main
        -import "os"
        +import "fmt"

        -func old() {}
        +func main() { fmt.Println("hi") }

        """)
        #expect(diff.files == ["main.go"])
        #expect(capture(of: "func", in: diff, kind: .addition) == .keywordFunction || capture(of: "func", in: diff, kind: .addition) == .keyword)
        #expect(capture(of: "\"hi\"", in: diff, kind: .addition) == .string)
        #expect(capture(of: "\"os\"", in: diff, kind: .deletion) == .string)
        #expect(capture(of: "func", in: diff, kind: .deletion) != nil)
        #expect(capture(of: "package", in: diff, kind: .context) != nil)
    }

    @Test func eachFileUsesItsOwnGrammar() {
        let diff = highlighted("""
        diff --git a/App.swift b/App.swift
        --- a/App.swift
        +++ b/App.swift
        @@ -1 +1 @@
        -let x = 1
        +let x = "two"
        diff --git a/notes.txt b/notes.txt
        --- a/notes.txt
        +++ b/notes.txt
        @@ -1 +1 @@
        -let x = 1
        +let x = "two"

        """, headers: true)
        #expect(diff.files == ["App.swift", "notes.txt"])
        let swiftLines = diff.lines.filter { $0.fileIndex == 0 && $0.kind == .addition }
        let textLines = diff.lines.filter { $0.fileIndex == 1 && $0.kind == .addition }
        #expect(swiftLines.allSatisfy { diff.highlights[$0.id] != nil })
        #expect(textLines.allSatisfy { diff.highlights[$0.id] == nil })
    }

    @Test func spansStayInsideTheirLine() {
        let diff = highlighted("""
        diff --git a/a.ts b/a.ts
        --- a/a.ts
        +++ b/a.ts
        @@ -1,3 +1,3 @@
         const a = `multi
        -line ğüş`
        +line çok satır`;
         export default a

        """)
        for line in diff.lines {
            for span in diff.highlights[line.id] ?? [] {
                #expect(span.range.lowerBound >= 0 && span.range.upperBound <= line.text.utf16.count)
            }
        }
    }

    @Test func themeMappingMatchesTheEditor() {
        let theme = EditorThemes.dark
        #expect(EditorThemes.attribute(for: .keyword, in: theme) == theme.keywords)
        #expect(EditorThemes.attribute(for: .string, in: theme) == theme.strings)
        #expect(EditorThemes.attribute(for: .comment, in: theme) == theme.comments)
        #expect(EditorThemes.attribute(for: .number, in: theme) == theme.numbers)
    }

    @Test func gitPanelDiffsArriveHighlighted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-hl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: file)
        _ = try await Git.run(["init", "-q"], in: root)
        _ = try await Git.run(["add", "-A"], in: root)
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "x"], in: root)
        try Data("package main\n\nfunc main() {}\n".utf8).write(to: file)

        let git = GitRepository(projectURL: root)
        await git.refresh()
        let document = DiffDocument(repository: git, source: .change(path: "main.go", area: .unstaged))
        document.reload()
        let deadline = Date().addingTimeInterval(4)
        while document.diff == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let diff = try #require(document.diff)
        let added = try #require(diff.lines.first { $0.kind == .addition && $0.text.contains("func") })
        #expect(diff.highlights[added.id]?.isEmpty == false)
    }
}

@MainActor
@Suite struct DiffHighlightPerformanceTests {
    @Test func largeDiffHighlightsInReasonableTime() {
        var diff = "diff --git a/big.go b/big.go\n--- a/big.go\n+++ b/big.go\n@@ -1,0 +1,20000 @@\n"
        for index in 0..<20_000 {
            diff += "+func handler\(index)(w http.ResponseWriter) { fmt.Fprintf(w, \"ok %d\", \(index)) }\n"
        }
        let parsed = ParsedDiff.parse(Data(diff.utf8), showFileHeaders: false)
        let grammars = DiffHighlighter.grammars(for: parsed)
        let start = Date()
        let highlights = DiffHighlighter.highlights(for: parsed, grammars: grammars)
        let elapsed = Date().timeIntervalSince(start)
        print("20k-line diff highlight: \(Int(elapsed * 1000)) ms")
        #expect(highlights.count == 20_000)
        #expect(elapsed < 10, "took \(elapsed)s") // debug build; release is several times faster
    }
}
