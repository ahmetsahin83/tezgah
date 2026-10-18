import Foundation
import Testing
@testable import Tezgah

func makeRepository(_ files: [String: String]) async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-features-\(UUID().uuidString)/repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    _ = try await Git.run(["init", "-q"], in: root)
    _ = try await Git.run(["add", "-A"], in: root)
    _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "x"], in: root)
    return root
}

private func write(_ text: String, to path: String, in root: URL) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path))
}

@Suite struct ProjectCommandTests {
    @Test func makeTargetsSkipVariablesAndSpecialTargets() {
        let makefile = """
        APP := Tezgah
        CONFIG ?= release
        .PHONY: build app run
        # comment: not a target
        build:
        \tswift build
        app: build
        \tcp x y
        %.o: %.c
        run install: app
        """
        #expect(ProjectCommandDetector.makeTargets(in: makefile) == ["build", "app", "run", "install"])
    }

    @Test func makeTargetDescriptionsComeFromComments() {
        let makefile = """
        # Builds the app
        # in release mode
        build:
        \tswift build

        test: build ## Runs the tests
        \tswift test
        out/app.o: app.c
        clean:
        """
        #expect(ProjectCommandDetector.makeTargets(in: makefile) == ["build", "test", "clean"])
        #expect(ProjectCommandDetector.makeTargetDetails(in: makefile) == [
            "build": "Builds the app in release mode",
            "test": "Runs the tests",
        ])
    }

    @Test func packageScriptsKeepFileOrderAndPickRunner() {
        let json = #"{ "name": "x", "scripts": { "dev": "vite", "build": "vite build", "test": "vitest" } }"#
        #expect(ProjectCommandDetector.packageScripts(in: json) == ["dev", "build", "test"])
        #expect(ProjectCommandDetector.packageRunner(lockFiles: []) == "npm run")
        #expect(ProjectCommandDetector.packageRunner(lockFiles: ["pnpm-lock.yaml"]) == "pnpm")
        #expect(ProjectCommandDetector.packageRunner(lockFiles: ["bun.lock", "yarn.lock"]) == "bun run")
    }

    @Test func justRecipesSkipSettingsAndPrivateRecipes() {
        let justfile = """
        set shell := ["zsh", "-c"]
        version := "1"
        build target="debug":
            cargo build
        _helper:
            echo hi
        test: build
        """
        #expect(ProjectCommandDetector.justRecipes(in: justfile) == ["build", "test"])
    }

    @Test func detectsCommandsFromBuildFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("run:\n\techo\n", to: "Makefile", in: folder)
        try write(#"{"scripts":{"dev":"vite"}}"#, to: "package.json", in: folder)
        try write("", to: "yarn.lock", in: folder)
        try write("// swift-tools-version: 6.0", to: "Package.swift", in: folder)

        let commands = ProjectCommandDetector.detect(in: folder).map(\.command)
        #expect(commands == ["make run", "yarn dev", "swift build", "swift test", "swift run"])
    }
}

@Suite struct LineChangesTests {
    @Test func unchangedTextHasNoMarks() {
        #expect(LineChanges.compute(base: "a\nb\nc\n", current: "a\nb\nc\n").isEmpty)
    }

    @Test func addedModifiedAndDeletedLines() {
        let base = "one\ntwo\nthree\nfour\nfive\n"
        let current = "one\nTWO\nthree\nnew a\nnew b\nfour\n"
        let changes = LineChanges.compute(base: base, current: current)
        #expect(changes.modified == IndexSet([1]))
        #expect(changes.added == IndexSet([3, 4]))
        // "five" is gone: the mark sits above the line that now follows "four" (the final empty line).
        #expect(changes.deletedAbove == IndexSet([6]))
    }

    @Test func deletionAtTheStart() {
        let changes = LineChanges.compute(base: "x\ny\nz", current: "y\nz")
        #expect(changes.deletedAbove == IndexSet([0]))
        #expect(changes.added.isEmpty && changes.modified.isEmpty)
    }

    @Test func replacingMoreLinesThanWereRemovedCountsTheRestAsAdded() {
        let changes = LineChanges.compute(base: "a\nb\nc", current: "a\nB1\nB2\nB3\nc")
        #expect(changes.modified == IndexSet([1]))
        #expect(changes.added == IndexSet([2, 3]))
    }
}

@Suite struct TextSearchTests {
    @Test func findsMatchesWithGitGrepAndRespectsGitignore() async throws {
        let root = try await makeRepository([
            "Sources/app.swift": "let greeting = \"Hello\"\nprint(greeting)\n",
            "README.md": "Say hello to Tezgah\n",
            ".gitignore": "build/\n",
        ])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try write("hello from a build artifact\n", to: "build/out.txt", in: root)
        try write("hello, untracked\n", to: "notes.txt", in: root)

        var options = TextSearch.Options()
        options.query = "hello"
        let output = try await TextSearch.run(options, in: root)
        let paths = Set(output.files.map(\.path))
        #expect(paths == ["Sources/app.swift", "README.md", "notes.txt"])

        let readme = try #require(output.files.first { $0.path == "README.md" })
        #expect(readme.matches.first?.line == 1)
        #expect(readme.matches.first?.ranges == [NSRange(location: 4, length: 5)])

        options.isCaseSensitive = true
        options.include = "*.swift"
        let swiftOnly = try await TextSearch.run(options, in: root)
        #expect(swiftOnly.files.isEmpty) // "Hello" has a capital H

        options.query = "Hello"
        let found = try await TextSearch.run(options, in: root)
        #expect(found.files.map(\.path) == ["Sources/app.swift"])
    }

    @Test func parsesEveryToolsOutputFormat() {
        var parser = TextSearch.OutputParser(highlighter: .init(TextSearch.Options(query: "foo")))
        // ripgrep / grep: "path NUL line:text", git grep: "path NUL line NUL text"; chunks may split lines.
        parser.consume(Data("./a.txt\u{0}3:a foo b\nb/c.txt\u{0}12\u{0}FOO".utf8))
        parser.consume(Data(" again\n".utf8))
        parser.finish()
        let output = parser.output
        #expect(output.files.map(\.path) == ["a.txt", "b/c.txt"])
        #expect(output.files[0].matches[0].line == 3)
        #expect(output.files[0].matches[0].ranges == [NSRange(location: 2, length: 3)])
        #expect(output.files[1].matches[0].line == 12)
        #expect(output.files[1].matches[0].text == "FOO again")
        #expect(output.matchCount == 2)
    }

    @Test func wholeWordAndRegexHighlighting() {
        let whole = TextSearch.Highlighter(TextSearch.Options(query: "id", isWholeWord: true))
        #expect(whole.ranges(in: "id = idle(id)") == [NSRange(location: 0, length: 2), NSRange(location: 10, length: 2)])
        let regex = TextSearch.Highlighter(TextSearch.Options(query: "v[0-9]+", isCaseSensitive: true, isRegex: true))
        #expect(regex.ranges(in: "v12 V3 v4") == [NSRange(location: 0, length: 3), NSRange(location: 7, length: 2)])
    }
}

@MainActor
@Suite struct SessionDiffTests {
    @Test func snapshotDiffShowsOnlyChangesSinceTheSnapshotAndLeavesTheIndexAlone() async throws {
        let root = try await makeRepository(["a.txt": "one\n", "b.txt": "b\n"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // Already changed before the session started: must not show up.
        try write("one\ntwo\n", to: "a.txt", in: root)
        try write("draft\n", to: "untracked.txt", in: root)

        let git = GitRepository(projectURL: root)
        await git.refresh()
        let tree = try #require(await git.snapshotTree())

        // The "session": edits a tracked file, an untracked one, and creates a new file.
        try write("one\ntwo\nthree\n", to: "a.txt", in: root)
        try write("draft\nmore\n", to: "untracked.txt", in: root)
        try write("brand new\n", to: "new.txt", in: root)

        let diff = try #require(await git.diff(since: tree, paths: ["a.txt", "untracked.txt", "new.txt"], replacing: nil))
        #expect(diff.files.sorted() == ["a.txt", "new.txt", "untracked.txt"])
        #expect(diff.additions == 3)
        #expect(diff.deletions == 0)

        // Nothing got staged by taking snapshots.
        let staged = try await Git.run(["diff", "--cached", "--name-only"], in: root)
        #expect(staged.text.isEmpty)
    }
}

@Suite struct PaletteAndMarkdownTests {
    @MainActor @Test func paletteMatchesTitlesAndKeepsOrderForAnEmptyQuery() {
        let commands = ["Yeni Terminal", "Git: Push", "Git: Pull", "Projede Ara"].map { title in
            PaletteCommand(id: title, title: title) {}
        }
        #expect(QuickOpenModel.match("", in: commands).map(\.entry.path) == ["Yeni Terminal", "Git: Push", "Git: Pull", "Projede Ara"])
        #expect(QuickOpenModel.match("gpu", in: commands).map(\.entry.path).prefix(2) == ["Git: Push", "Git: Pull"])
        #expect(QuickOpenModel.match("ara", in: commands).first?.entry.path == "Projede Ara")
    }

    @MainActor @Test func quickOpenOffersAskingClaude() {
        let model = QuickOpenModel(project: Project(url: FileManager.default.temporaryDirectory))
        var asked: String?
        model.askClaude = { asked = $0 }

        // A sentence puts "Claude'a sor" first, so ↩ sends it.
        model.query = "tabloya kolon nasıl eklenir"
        model.search()
        #expect(model.selectedResult?.command?.id == "claude.ask")
        model.selectedResult?.command?.action()
        #expect(asked == "tabloya kolon nasıl eklenir")

        // Line jumps and commands are not questions.
        model.query = "main.go:42"
        model.search()
        #expect(!model.results.contains { $0.command?.id == "claude.ask" })
        model.query = "> git"
        model.search()
        #expect(!model.results.contains { $0.command?.id == "claude.ask" })
    }

    @Test func markdownRendersGitHubExtensionsAndDisarmsScripts() {
        let html = MarkdownRenderer.html("""
        # Title

        | a | b |
        |---|---|
        | 1 | 2 |

        - [x] done
        - [ ] todo

        ~~old~~ https://example.com

        <script>alert(1)</script>
        """)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<table>"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<del>old</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
        #expect(!html.contains("<script>"))
    }
}

@MainActor
@Suite struct WorkspaceTabTests {
    private func makeStore(snapshot: URL? = nil, restoresTabs: Bool = false) async throws -> (WorkspaceStore, Project, URL) {
        let root = try await makeRepository(["a.md": "# A\n", "b.txt": "b\n", "c.txt": "c\n"])
        let base = root.deletingLastPathComponent()
        let store = WorkspaceStore(
            snapshotURL: snapshot ?? base.appendingPathComponent("workspace.json"),
            agentsDirectory: base.appendingPathComponent("agents"),
            restoresTabs: restoresTabs
        )
        store.addFolder(root)
        return (store, try #require(store.activeProject), base)
    }

    @Test func splitShowsTwoTabsAndSelectingTheSideTabSwapsThem() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.openFile(project.url.appendingPathComponent("a.md"))
        store.openFile(project.url.appendingPathComponent("b.txt"))
        let a = project.tabs[0].id
        let b = project.tabs[1].id
        #expect(project.selectedTabID == b)

        store.toggleSplit()
        #expect(project.splitTabID == a)

        project.selectedTabID = a // clicking the side tab in the tab bar
        #expect(project.selectedTabID == a)
        #expect(project.splitTabID == b)

        // Closing the main tab hands the main pane to the side tab.
        store.closeTab(a, in: project)
        #expect(project.selectedTabID == b)
        #expect(project.splitTabID == nil)
    }

    @Test func openInSplitMovesTheSelectedTabAside() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.openFile(project.url.appendingPathComponent("b.txt"))
        store.openFile(project.url.appendingPathComponent("c.txt"))
        let c = try #require(project.selectedTabID)
        store.openInSplit(c, in: project)
        #expect(project.splitTabID == c)
        #expect(project.selectedTabID == project.tabs[0].id)
    }

    @Test func searchTabIsReusedAndPrefilled() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.showSearch()
        store.showSearch()
        #expect(project.tabs.filter { if case .search = $0 { true } else { false } }.count == 1)
        #expect(project.selectedTabID == project.searchModel?.id)
    }

    @Test func tabsAndCustomCommandsSurviveARestart() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.openFile(project.url.appendingPathComponent("a.md"))
        project.documents[0].markdownMode = .split
        store.openFile(project.url.appendingPathComponent("b.txt"))
        store.showSearch()
        project.searchModel?.options.query = "needle"
        store.openInSplit(project.documents[0].id, in: project)
        store.addCustomCommand(ProjectCommand(name: "Sunucu", command: "echo up", source: nil), to: project)
        let database = DatabaseConfig(name: "yerel", kind: .sqlite, path: "app.db")
        project.databases = [database]
        store.persist()

        let state = WorkspaceStore.state(of: project)
        #expect(state.tabs == [
            .editor(path: project.url.appendingPathComponent("a.md").path, markdownMode: "split"),
            .editor(path: project.url.appendingPathComponent("b.txt").path, markdownMode: nil),
            .search(query: "needle"),
        ])
        #expect(state.selectedTab == 2)
        #expect(state.splitTab == 0)

        let restarted = WorkspaceStore(
            snapshotURL: base.appendingPathComponent("workspace.json"),
            agentsDirectory: base.appendingPathComponent("agents-2"),
            restoresTabs: true
        )
        let reopened = try #require(restarted.activeProject)
        defer { reopened.stopWatching() }
        for _ in 0..<100 where reopened.tabs.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reopened.tabs.map(\.title) == ["a.md", "b.txt", "Ara: needle"])
        #expect(reopened.documents.first?.markdownMode == .split)
        #expect(reopened.selectedTabID == reopened.searchModel?.id)
        #expect(reopened.splitTabID == reopened.documents.first?.id)
        #expect(reopened.customCommands.map(\.command) == ["echo up"])
        #expect(reopened.databases == [database])
    }
}
