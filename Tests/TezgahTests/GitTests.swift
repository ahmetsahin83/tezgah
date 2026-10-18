import Foundation
import Testing
@testable import Tezgah

/// A throwaway repository in the temp folder.
private struct TempRepo {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tezgah-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Test")
        try git("config", "user.email", "test@example.com")
        try git("config", "commit.gpgsign", "false")
        try git("config", "core.hooksPath", "/dev/null")
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = url
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitError(message: "git \(args.joined(separator: " ")): \(text)")
        }
        return text
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func status() async throws -> GitStatus {
        let output = try await Git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: url)
        return GitStatus.parse(output.stdout)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct GitStatusTests {
    @Test func emptyRepositoryHasNoHead() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")

        let status = try await repo.status()
        #expect(status.branch == "main")
        #expect(status.headOID == nil)
        #expect(status.unstaged.map(\.path) == ["a.txt"])
        #expect(status.unstaged.first?.isUntracked == true)
    }

    @Test func parsesEveryKindOfChange() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("modified.txt", "one\n")
        try repo.write("deleted.txt", "bye\n")
        try repo.write("old name.txt", "rename me\nline 2\nline 3\n")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "initial")

        try repo.write("modified.txt", "one\ntwo\n")
        try repo.git("add", "modified.txt")
        try repo.write("modified.txt", "one\ntwo\nthree\n") // staged and unstaged
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("deleted.txt"))
        try repo.git("mv", "old name.txt", "yeni ad ğüş.txt")
        try repo.write("klasör/yeni dosya.txt", "new\n")
        try repo.write("added.txt", "added\n")
        try repo.git("add", "added.txt")

        let status = try await repo.status()
        #expect(status.headOID != nil)
        #expect(status.upstream == nil)

        #expect(status.staged.map(\.path) == ["added.txt", "modified.txt", "yeni ad ğüş.txt"])
        let rename = try #require(status.staged.first { $0.path == "yeni ad ğüş.txt" })
        #expect(rename.code == "R")
        #expect(rename.originalPath == "old name.txt")
        #expect(status.staged.first { $0.path == "added.txt" }?.code == "A")

        #expect(status.unstaged.map(\.path) == ["deleted.txt", "klasör/yeni dosya.txt", "modified.txt"])
        #expect(status.unstaged.first { $0.path == "deleted.txt" }?.code == "D")
        #expect(status.unstaged.first { $0.path == "klasör/yeni dosya.txt" }?.letter == "U")
        #expect(status.conflicted.isEmpty)
    }

    @Test func detectsMergeConflicts() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("file.txt", "base\n")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "base")
        try repo.git("switch", "-q", "-c", "other")
        try repo.write("file.txt", "other\n")
        try repo.git("commit", "-q", "-am", "other")
        try repo.git("switch", "-q", "main")
        try repo.write("file.txt", "main\n")
        try repo.git("commit", "-q", "-am", "main")
        _ = try? repo.git("merge", "other")

        let status = try await repo.status()
        #expect(status.conflicted.map(\.path) == ["file.txt"])
        #expect(status.conflicted.first?.letter == "!")
    }
}

@Suite struct ParsedDiffTests {
    @Test func numbersLinesInHunks() {
        let diff = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -10,4 +10,5 @@ struct A {
             let x = 1
        -    let y = 2
        +    let y = 3
        +    let z = 4
             let w = 5
        \\ No newline at end of file

        """
        let parsed = ParsedDiff.parse(Data(diff.utf8), showFileHeaders: true)
        let kinds = parsed.lines.map(\.kind)
        #expect(kinds == [.fileHeader, .hunkHeader, .context, .deletion, .addition, .addition, .context, .info])
        #expect(parsed.lines[0].text == "a.swift")
        #expect(parsed.additions == 2)
        #expect(parsed.deletions == 1)

        let context = parsed.lines[2]
        #expect(context.oldNumber == 10 && context.newNumber == 10)
        let deletion = parsed.lines[3]
        #expect(deletion.oldNumber == 11 && deletion.newNumber == nil)
        #expect(deletion.text == "    let y = 2")
        let additions = parsed.lines[4...5].map(\.newNumber)
        #expect(additions == [11, 12])
        let lastContext = parsed.lines[6]
        #expect(lastContext.oldNumber == 12 && lastContext.newNumber == 13)
    }

    @Test func hidesFileHeadersForSingleFileDiffs() {
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let parsed = ParsedDiff.parse(Data(diff.utf8), showFileHeaders: false)
        #expect(parsed.lines.map(\.kind) == [.hunkHeader, .deletion, .addition])
    }

    @Test func handlesDeletedLinesThatLookLikeHeaders() {
        let diff = "diff --git a/q.sql b/q.sql\n--- a/q.sql\n+++ b/q.sql\n@@ -1,2 +1 @@\n--- comment\n select 1;\n"
        let parsed = ParsedDiff.parse(Data(diff.utf8), showFileHeaders: false)
        #expect(parsed.lines.map(\.kind) == [.hunkHeader, .deletion, .context])
        #expect(parsed.lines[1].text == "-- comment")
    }

    @Test func parsesCommitLog() {
        let log = "abc123\u{1f}abc\u{1f}Ahmet\u{1f}1700000000\u{1f}İlk commit\u{1f}HEAD -> main, origin/main\u{1f}def456 fed789\u{1e}\n"
            + "def456\u{1f}def\u{1f}Ahmet\u{1f}1690000000\u{1f}subject, with comma\u{1f}\u{1f}\u{1e}\n"
        let commits = GitCommit.parseLog(log)
        #expect(commits.count == 2)
        #expect(commits[0].parents == ["def456", "fed789"])
        #expect(commits[0].isMerge)
        #expect(commits[1].parents.isEmpty)
        #expect(commits[0].refs == ["HEAD -> main", "origin/main"])
        #expect(commits[1].subject == "subject, with comma")
        #expect(commits[1].refs.isEmpty)
    }
}

@MainActor
@Suite struct GitRepositoryTests {
    @Test func stagesCommitsAndDecorates() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("src/app.swift", "print(1)\n")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "initial")

        // Open a sub-folder as the project, like a package inside a monorepo.
        let git = GitRepository(projectURL: repo.url.appendingPathComponent("src"))
        await git.refresh()
        #expect(git.isRepository)
        #expect(git.prefix == "src/")
        #expect(git.status.isClean)

        try repo.write("src/app.swift", "print(2)\n")
        try repo.write("src/new/file.swift", "x\n")
        await git.refresh()
        #expect(git.decorations["app.swift"]?.letter == "M")
        #expect(git.decorations["new/file.swift"]?.letter == "U")
        #expect(git.changedFolders == ["new"])

        let modified = try #require(git.status.unstaged.first { $0.path == "src/app.swift" })
        git.panelMode = .changes
        git.selectChanges([modified.id])
        await git.stage([modified])
        #expect(git.status.staged.map(\.path) == ["src/app.swift"])
        // Selection follows the file from "changes" to "staged".
        #expect(git.selectedChangeIDs == ["staged:src/app.swift"])

        git.commitMessage = "Değişiklik \"tırnak\" ile"
        await git.commit()
        #expect(git.lastError == nil)
        #expect(git.commitMessage.isEmpty)
        #expect(git.status.staged.isEmpty)
        #expect(git.status.unstaged.map(\.path) == ["src/new/file.swift"])

        await git.loadLog()
        #expect(git.commits.first?.subject == "Değişiklik \"tırnak\" ile")
        #expect(git.commits.count == 2)
    }

    /// A refresh requested while another one is running must not return the older result.
    @Test func overlappingRefreshReturnsFreshStatus() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "initial")

        let git = GitRepository(projectURL: repo.url)
        await git.refresh()
        for _ in 0..<5 {
            let first = Task { await git.refresh() }
            await Task.yield() // let the first refresh start and suspend on git
            try repo.write("new-\(UUID().uuidString).txt", "x\n")
            await git.refresh()
            let onDisk = try FileManager.default.contentsOfDirectory(atPath: repo.url.path).filter { $0.hasPrefix("new-") }
            #expect(Set(git.status.unstaged.map(\.path)) == Set(onDisk))
            await first.value
        }
    }

    @Test func reportsGitErrors() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "initial")

        let git = GitRepository(projectURL: repo.url)
        await git.refresh()
        await git.switchBranch("does-not-exist")
        #expect(git.lastError != nil)
        await git.push()
        #expect(git.lastError == "Bu depoda uzak depo (remote) tanımlı değil.")
    }

    // Untracked files go to the real Trash, so only tracked files are exercised here.
    @Test func discardRestoresTrackedFiles() async throws {
        let repo = try TempRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try repo.git("add", "-A")
        try repo.git("commit", "-q", "-m", "initial")
        try repo.write("a.txt", "changed\n")

        let git = GitRepository(projectURL: repo.url)
        await git.refresh()
        await git.discard(git.status.unstaged)
        #expect(git.status.isClean)
        #expect(try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
    }

    @Test func nonRepositoryIsDetected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let git = GitRepository(projectURL: folder)
        await git.refresh()
        #expect(git.hasChecked)
        #expect(!git.isRepository)
        await git.initRepository()
        #expect(git.isRepository)
    }
}
