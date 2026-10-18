import AppKit
import Foundation
import Testing
@testable import Tezgah

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
private func eventually(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@MainActor
@Suite struct FileWatcherTests {
    @Test func reportsChangedFoldersRelativeToRoot() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)

        var seen = Set<String>()
        let watcher = FileWatcher(url: root) { seen.formUnion($0.folders) }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300)) // let the stream settle

        try write("x", to: root.appendingPathComponent("sub/deep/file.txt"))
        try write("x", to: root.appendingPathComponent("top.txt"))
        #expect(await eventually { seen.contains("sub/deep") && seen.contains("") })
    }
}

@MainActor
@Suite struct LiveTreeTests {
    @Test func treeFollowsTheFileSystem() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("x", to: root.appendingPathComponent("src/a.swift"))

        let project = Project(url: root)
        defer { project.stopWatching() }
        let src = try #require(project.root.loadedNode(at: "src"))
        src.isExpanded = true
        src.loadChildrenIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        try write("x", to: root.appendingPathComponent("new.txt"))
        try write("x", to: root.appendingPathComponent("src/b.swift"))
        #expect(await eventually { project.root.children?.contains { $0.name == "new.txt" } == true })
        #expect(await eventually { src.children?.map(\.name) == ["a.swift", "b.swift"] })

        try FileManager.default.removeItem(at: root.appendingPathComponent("src/a.swift"))
        #expect(await eventually { src.children?.map(\.name) == ["b.swift"] })
        // The expanded folder object survives, so it stays expanded.
        #expect(project.root.loadedNode(at: "src") === src)
    }

    @Test func gitStatusFollowsTerminalCommits() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", to: root.appendingPathComponent("a.txt"))
        let identity = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        _ = try await Git.run(["init", "-q"], in: root)
        _ = try await Git.run(["add", "-A"], in: root)
        _ = try await Git.run(identity + ["commit", "-q", "-m", "first"], in: root)

        let project = Project(url: root)
        defer { project.stopWatching() }
        await project.git.refresh()
        #expect(project.git.status.isClean)
        try await Task.sleep(for: .milliseconds(300))

        // Edit and commit "from a terminal": no explicit refresh calls from here on.
        try write("two\n", to: root.appendingPathComponent("a.txt"))
        #expect(await eventually { project.git.status.unstaged.map(\.path) == ["a.txt"] })
        _ = try await Git.run(["add", "-A"], in: root)
        _ = try await Git.run(identity + ["commit", "-q", "-m", "second"], in: root)
        #expect(await eventually { project.git.status.isClean })
    }
}

@MainActor
@Suite struct WatchLoopTests {
    /// If our own git commands wrote into .git, every refresh would trigger another one, forever.
    @Test func ownGitCommandsCauseNoFileEvents() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", to: root.appendingPathComponent("a.txt"))
        _ = try await Git.run(["init", "-q"], in: root)
        _ = try await Git.run(["add", "-A"], in: root)
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "x"], in: root)
        try write("two\n", to: root.appendingPathComponent("a.txt"))

        let git = GitRepository(projectURL: root)
        await git.refresh()
        try await Task.sleep(for: .milliseconds(400))

        var events: [Set<String>] = []
        let watcher = FileWatcher(url: root) { events.append($0.folders) }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let document = DiffDocument(repository: git, source: .change(path: "a.txt", area: .unstaged))
        for _ in 0..<3 {
            await git.refresh()
            await git.loadBranches()
            await git.loadLog()
            document.reload()
        }
        #expect(await eventually { document.diff != nil })
        try await Task.sleep(for: .milliseconds(800))
        #expect(events.isEmpty, "unexpected events: \(events)")
    }
}

@MainActor
@Suite struct DiskSyncTests {
    private func openDocument(_ text: String) throws -> (EditorDocument, URL) {
        let root = try makeFolder()
        let url = root.appendingPathComponent("main.go")
        try write(text, to: url)
        let document = EditorDocument(url: url)
        _ = document.controller(theme: EditorThemes.light).view
        return (document, url)
    }

    private func setModificationDate(_ url: URL, offset: TimeInterval) throws {
        // File systems can round timestamps; force a distinct one so the change is visible.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: url.path)
    }

    @Test func cleanTabPicksUpOutsideChanges() throws {
        let (document, url) = try openDocument("package main\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try write("package other\n", to: url)
        try setModificationDate(url, offset: 5)
        document.checkDisk()
        #expect(document.diskState == .inSync)
        #expect(!document.isDirty)
        #expect(document.controller(theme: EditorThemes.light).text == "package other\n")
    }

    @Test func dirtyTabAsksBeforeLosingEdits() throws {
        let (document, url) = try openDocument("package main\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = document.controller(theme: EditorThemes.light)
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// mine\n")
        #expect(document.isDirty)

        try write("package theirs\n", to: url)
        try setModificationDate(url, offset: 5)
        document.checkDisk()
        #expect(document.diskState == .changedOnDisk)
        #expect(controller.text == "// mine\npackage main\n") // nothing lost yet

        document.reloadFromDisk()
        #expect(document.diskState == .inSync)
        #expect(!document.isDirty)
        #expect(controller.text == "package theirs\n")
    }

    @Test func keepingLocalVersionOverwritesOnSave() throws {
        let (document, url) = try openDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.controller(theme: EditorThemes.light).textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        try write("theirs\n", to: url)
        try setModificationDate(url, offset: 5)
        document.checkDisk()
        document.keepLocalVersion()
        #expect(document.diskState == .inSync)
        try document.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine a\n")
    }

    @Test func touchAloneIsNotAConflict() throws {
        let (document, url) = try openDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.controller(theme: EditorThemes.light).textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        try setModificationDate(url, offset: 5)
        document.checkDisk()
        #expect(document.diskState == .inSync)
        #expect(document.isDirty)
    }

    @Test func ownSaveIsNotReportedAsOutsideChange() throws {
        let (document, url) = try openDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.controller(theme: EditorThemes.light).textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        try document.save()
        document.checkDisk()
        #expect(document.diskState == .inSync)
        #expect(!document.isDirty)
    }

    @Test func deletionIsReportedAndSaveRecreatesTheFile() throws {
        let (document, url) = try openDocument("a\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        document.checkDisk()
        #expect(document.diskState == .deletedOnDisk)
        try document.save()
        #expect(document.diskState == .inSync)
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\n")
    }
}
