import Testing
@testable import Tezgah

@Suite struct ChangeTreeTests {
    private func change(_ path: String, _ code: Character = "M") -> GitChange {
        GitChange(path: path, originalPath: nil, code: code, area: .unstaged)
    }

    @Test func foldersFirstAndSingleChildChainsJoin() {
        let tree = ChangeTree([
            change("README.md"),
            change("Sources/App/Model/Board.swift", "A"),
            change("Sources/App/Model/Database/Client.swift"),
            change("Sources/App/Views/ContentView.swift"),
            change("Tests/AppTests/ProjectTests.swift"),
        ], area: .unstaged)

        let rows = tree.rows(collapsed: [])
        #expect(rows.map(\.node.name) == [
            "Sources/App", "Model", "Database", "Client.swift", "Board.swift", "Views", "ContentView.swift",
            "Tests/AppTests", "ProjectTests.swift",
            "README.md",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 2, 1, 2, 0, 1, 0])
        #expect(rows[0].node.changes.count == 3)
    }

    @Test func collapsedFoldersHideTheirContents() {
        let tree = ChangeTree([change("a/b.txt"), change("a/c/d.txt"), change("e.txt")], area: .unstaged)
        let folder = tree.roots[0]
        #expect(folder.id == "dir:unstaged:a")
        #expect(tree.rows(collapsed: [folder.id]).map(\.node.name) == ["a", "e.txt"])
    }
}
