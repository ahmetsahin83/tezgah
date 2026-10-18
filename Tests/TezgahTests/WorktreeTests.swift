import Foundation
import Testing
@testable import Tezgah

@Suite struct WorktreeTests {
    private func commit(_ message: String, in directory: URL) async throws {
        _ = try await Git.run(["add", "-A"], in: directory)
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", message], in: directory)
    }

    @Test func branchNamesComeFromTheCardTitle() {
        #expect(Worktrees.slug("Giriş ekranı: şifre sıfırlama") == "giris-ekrani-sifre-sifirlama")
        #expect(Worktrees.slug("  Fix #42 — crash on İstanbul!  ") == "fix-42-crash-on-istanbul")
        #expect(Worktrees.slug("🙂") == "")
        let long = Worktrees.slug("Ödeme sayfasında kart bilgileri girilirken klavye alanı kapatıyor")
        #expect(long.count <= 40)
        #expect(!long.hasSuffix("-"))
    }

    @Test func worktreeIsIgnoredAndNamesDoNotCollide() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let first = try await Worktrees.create(named: "Yeni özellik", projectURL: root, root: root)
        #expect(first.branch == "tezgah/yeni-ozellik")
        #expect(first.url.path.hasSuffix("/.tezgah/worktrees/yeni-ozellik"))
        #expect(FileManager.default.fileExists(atPath: first.url.appendingPathComponent("a.txt").path))
        #expect(try await Git.run(["status", "--porcelain"], in: root).text.isEmpty) // .tezgah/ is excluded
        let exclude = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").filter { $0 == ".tezgah/" }.count == 1)

        let second = try await Worktrees.create(named: "Yeni özellik", projectURL: root, root: root)
        #expect(second.branch == "tezgah/yeni-ozellik-2")
        let againExcluded = try String(contentsOf: root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(againExcluded == exclude) // added once
    }

    @Test func committedWorkIsMergedAndTheWorktreeGoes() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let worktree = try await Worktrees.create(named: "Ekle", projectURL: root, root: root)

        try Data("yeni\n".utf8).write(to: worktree.url.appendingPathComponent("b.txt"))
        #expect(try await Worktrees.hasUncommittedChanges(at: worktree.url))
        try await commit("b ekle", in: worktree.url)
        #expect(try await !Worktrees.hasUncommittedChanges(at: worktree.url))

        try await Worktrees.merge(branch: worktree.branch, root: root)
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "yeni\n")

        try await Worktrees.remove(worktree.url, branch: worktree.branch, root: root, force: false)
        #expect(!FileManager.default.fileExists(atPath: worktree.url.path))
        #expect(try await Git.run(["branch", "--list", worktree.branch], in: root).text.isEmpty)
    }

    @Test func aConflictingMergeIsUndone() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let worktree = try await Worktrees.create(named: "Çakışma", projectURL: root, root: root)

        try Data("dal\n".utf8).write(to: worktree.url.appendingPathComponent("a.txt"))
        try await commit("dalda", in: worktree.url)
        try Data("ana\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await commit("anada", in: root)

        await #expect(throws: (any Error).self) {
            try await Worktrees.merge(branch: worktree.branch, root: root)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "ana\n")
        #expect(try await Git.run(["status", "--porcelain"], in: root).text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test func discardingThrowsAwayUnmergedWork() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let worktree = try await Worktrees.create(named: "Deneme", projectURL: root, root: root)
        try Data("x\n".utf8).write(to: worktree.url.appendingPathComponent("c.txt"))
        try await commit("c", in: worktree.url)
        try Data("y\n".utf8).write(to: worktree.url.appendingPathComponent("d.txt"))

        try await Worktrees.remove(worktree.url, branch: worktree.branch, root: root, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.url.path))
        #expect(try await Git.run(["branch", "--list", worktree.branch], in: root).text.isEmpty)
    }
}

@MainActor
@Suite struct WorktreeProjectTests {
    @Test func agentsInAWorktreeGetItsRepository() async throws {
        let root = try await makeRepository(["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let project = Project(url: root)
        defer { project.stopWatching() }

        #expect(project.repository(for: root) === project.git)
        let worktree = root.appendingPathComponent(".tezgah/worktrees/is", isDirectory: true)
        let repository = project.repository(for: worktree.appendingPathComponent("Sources"))
        #expect(repository !== project.git)
        #expect(repository.projectURL.path == worktree.path)
        #expect(project.repository(for: worktree) === repository) // one per worktree
        project.forgetRepository(at: worktree)
        #expect(project.repository(for: worktree) !== repository)
    }

    @Test func cardsSavedBeforeWorktreesStillLoad() throws {
        let json = #"{"id":"6F1C3A52-1D2B-4F0E-9C3A-2B1D4E5F6A7B","title":"Eski kart","notes":"","column":"todo","createdAt":0}"#
        let card = try JSONDecoder().decode(BoardCard.self, from: Data(json.utf8))
        #expect(card.title == "Eski kart")
        #expect(card.worktree == nil)
    }

    @Test func thePromptAsksForACommitOnTheBranch() {
        let card = BoardCard(title: "Giriş ekranı", notes: "Şifre alanı kayıyor")
        let prompt = WorkspaceStore.worktreePrompt(for: card, branch: "tezgah/giris-ekrani")
        #expect(prompt.hasPrefix("Giriş ekranı\n\nŞifre alanı kayıyor\n\n"))
        #expect(prompt.contains("tezgah/giris-ekrani"))
        #expect(prompt.contains("commit'le"))
    }
}
