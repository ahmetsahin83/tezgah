import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct DiffTabTests {
    /// A store saving to a temp file (never the real workspace.json) with one git project
    /// containing two modified files.
    private func makeStore() async throws -> (WorkspaceStore, Project, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-tabs-\(UUID().uuidString)")
        let root = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] {
            try Data("one\n".utf8).write(to: root.appendingPathComponent(name))
        }
        _ = try await Git.run(["init", "-q"], in: root)
        _ = try await Git.run(["add", "-A"], in: root)
        _ = try await Git.run(["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "x"], in: root)
        for name in ["a.txt", "b.txt"] {
            try Data("two\n".utf8).write(to: root.appendingPathComponent(name))
        }

        let store = WorkspaceStore(
            snapshotURL: base.appendingPathComponent("workspace.json"),
            agentsDirectory: base.appendingPathComponent("agents")
        )
        store.addFolder(root)
        let project = try #require(store.activeProject)
        await project.git.refresh()
        return (store, project, base)
    }

    private func titles(_ project: Project) -> [String] {
        project.diffDocuments.map(\.title)
    }

    @Test func previewTabIsReusedUntilPinned() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.openDiff(.change(path: "a.txt", area: .unstaged))
        store.openDiff(.change(path: "b.txt", area: .unstaged))
        #expect(titles(project) == ["b.txt"]) // the preview tab was replaced, not duplicated

        project.diffDocuments[0].isPreview = false // double-click on the tab
        store.openDiff(.change(path: "a.txt", area: .unstaged))
        #expect(titles(project) == ["b.txt", "a.txt"])

        // Opening a diff that already has a tab selects it.
        store.openDiff(.change(path: "b.txt", area: .unstaged))
        #expect(project.diffDocuments.count == 2)
        #expect(project.selectedTabID == project.diffDocuments[0].id)
    }

    @Test func pinnedOpenFromDoubleClick() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.openDiff(.change(path: "a.txt", area: .unstaged), pin: true)
        store.openDiff(.change(path: "b.txt", area: .unstaged))
        #expect(titles(project) == ["a.txt", "b.txt"])
        #expect(project.diffDocuments.map(\.isPreview) == [false, true])
    }

    @Test func diffTabFollowsStagingAndCommit() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        store.openDiff(.change(path: "a.txt", area: .unstaged))
        let document = try #require(project.diffDocuments.first)
        #expect(await waitFor { document.diff != nil })

        let change = try #require(document.currentChange)
        await project.git.stage([change])
        document.reload()
        #expect(await waitFor { document.source == .change(path: "a.txt", area: .staged) })

        project.git.commitMessage = "a"
        await project.git.commit() // b.txt is unstaged, so only a.txt is committed
        document.reload()
        #expect(await waitFor { document.hasNoChanges })
    }

    @Test func closingADiffTabClearsTheMatchingSelection() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        let change = try #require(project.git.status.unstaged.first { $0.path == "a.txt" })
        project.git.selectChanges([change.id])
        store.openDiff(.change(path: "a.txt", area: .unstaged))
        store.closeActiveTab()
        #expect(project.diffDocuments.isEmpty)
        #expect(project.git.selectedChangeIDs.isEmpty)
    }

    @Test func commitDiffOpensInATab() async throws {
        let (store, project, base) = try await makeStore()
        defer { project.stopWatching(); try? FileManager.default.removeItem(at: base) }

        await project.git.loadLog()
        let commit = try #require(project.git.commits.first)
        store.openDiff(.commit(commit))
        let document = try #require(project.diffDocuments.first)
        #expect(await waitFor { document.diff != nil })
        #expect(document.diff?.files == ["a.txt", "b.txt"])
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
