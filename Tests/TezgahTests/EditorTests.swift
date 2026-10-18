import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import Foundation
import Testing
@testable import Tezgah

@Suite struct IndentDetectionTests {
    private func indent(_ text: String, file: String = "x.txt", language: CodeLanguage = .default) -> IndentOption {
        EditorDocument.detectIndent(in: text, fileName: file, language: language)
    }

    @Test func detectsTabs() {
        #expect(indent("func main() {\n\tfmt.Println(1)\n\tif x {\n\t\treturn\n\t}\n}\n") == .tab)
    }

    @Test func detectsTwoSpaces() {
        let dart = "class A {\n  void f() {\n    print(1);\n    if (x) {\n      return;\n    }\n  }\n}\n"
        #expect(indent(dart) == .spaces(count: 2))
    }

    @Test func detectsFourSpaces() {
        let swift = "struct A {\n    func f() {\n        print(1)\n    }\n}\n"
        #expect(indent(swift) == .spaces(count: 4))
    }

    @Test func ignoresAlignmentAndCommentContinuations() {
        var lines = ["/**", " * docs", " */", "func f(a: Int,", "       b: Int) {"]
        lines += Array(repeating: "    let x = 1", count: 20)
        lines.append("}")
        #expect(indent(lines.joined(separator: "\n")) == .spaces(count: 4))
    }

    @Test func fallsBackToLanguageConvention() {
        #expect(indent("package main\n", language: .go) == .tab)
        #expect(indent("{}", language: .json) == .spaces(count: 2))
        #expect(indent("print(1)", language: .python) == .spaces(count: 4))
        #expect(indent("all:", file: "Makefile") == .tab)
    }
}

@MainActor
@Suite struct EditorDocumentTests {
    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func detectsLanguageFromFile() throws {
        let cases: [(String, TreeSitterLanguage)] = [
            ("main.go", .go), ("app.dart", .dart), ("App.swift", .swift),
            ("page.tsx", .tsx), ("index.js", .javascript), ("data.json", .json),
            ("ci.yaml", .yaml), ("README.md", .markdown), ("go.mod", .goMod),
        ]
        for (name, expected) in cases {
            let url = try tempFile(name, "x\n")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(EditorDocument(url: url).language.id == expected, "\(name)")
        }
        let script = try tempFile("deploy", "#!/bin/bash\necho hi\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        #expect(EditorDocument(url: script).language.id == .bash)
    }

    @Test func editsAndSavesThroughTheEditor() throws {
        let url = try tempFile("main.go", "package main\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let document = EditorDocument(url: url)
        #expect(document.loadError == nil)
        let controller = document.controller(theme: EditorThemes.light)
        #expect(document.controller(theme: EditorThemes.dark) === controller) // reused, not recreated
        _ = controller.view
        #expect(controller.text == "package main\n")
        #expect(!document.isDirty)

        controller.textView.replaceCharacters(in: NSRange(location: 12, length: 0), with: " // ğüş")
        #expect(document.isDirty)
        try document.save()
        #expect(!document.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "package main // ğüş\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test func highlightsKeywords() async throws {
        let url = try tempFile("main.go", "package main\n\nfunc main() {\n\tprintln(\"hi\")\n}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = EditorDocument(url: url)
        let controller = document.controller(theme: EditorThemes.light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; otherwise close() over-releases
        window.contentViewController = controller
        defer { window.close() }

        // Tree-sitter highlighting runs asynchronously.
        let keywordColor = EditorThemes.light.keywords.color
        var color: NSColor?
        for _ in 0..<40 {
            color = controller.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            if color == keywordColor { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(color == keywordColor)
    }

    @Test func refusesBinaryFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: url)
        #expect(EditorDocument(url: url).loadError != nil)
    }
}
