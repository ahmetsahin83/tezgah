import Foundation

/// Changed files as a folder tree, the way VS Code's source control shows them: folders first,
/// and a chain of folders with nothing else in them collapsed into one row ("Sources/App/Model").
struct ChangeTree: Equatable {
    struct Node: Identifiable, Equatable {
        /// Folder path, or the file's path, relative to the repository.
        let path: String
        /// What the row shows: a file name, or one or more folder names joined with "/".
        let name: String
        let change: GitChange?
        /// Staged and unstaged trees can hold the same folder; ids stay apart.
        let area: GitChange.Area
        var children: [Node]

        var isFolder: Bool { change == nil }
        var id: String { change?.id ?? "dir:\(area.rawValue):\(path)" }

        /// Every change at or below this node.
        var changes: [GitChange] {
            if let change { return [change] }
            return children.flatMap(\.changes)
        }
    }

    /// A row of the tree as shown, given which folders are collapsed.
    struct Row: Identifiable, Equatable {
        let node: Node
        let depth: Int
        var id: String { node.id }
    }

    let roots: [Node]

    init(_ changes: [GitChange], area: GitChange.Area) {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [GitChange] = []
        }
        let root = Folder()
        for change in changes {
            var folder = root
            for component in change.directory.split(separator: "/").map(String.init) {
                if let next = folder.folders[component] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[component] = next
                    folder = next
                }
            }
            folder.files.append(change)
        }

        func nodes(in folder: Folder, at path: String) -> [Node] {
            let folderNodes = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> Node in
                var name = name
                var current = folder.folders[name]!
                var fullPath = path.isEmpty ? name : path + "/" + name
                // A folder holding a single folder and nothing else joins its child: a/b/c.
                while current.files.isEmpty, current.folders.count == 1, let (childName, child) = current.folders.first {
                    name += "/" + childName
                    fullPath += "/" + childName
                    current = child
                }
                return Node(path: fullPath, name: name, change: nil, area: area, children: nodes(in: current, at: fullPath))
            }
            let fileNodes = folder.files
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                .map { Node(path: $0.path, name: $0.fileName, change: $0, area: area, children: []) }
            return folderNodes + fileNodes
        }
        roots = nodes(in: root, at: "")
    }

    /// The rows to show: folders and files depth first, skipping what is inside collapsed folders.
    func rows(collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        func visit(_ nodes: [Node], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isFolder, !collapsed.contains(node.id) {
                    visit(node.children, depth: depth + 1)
                }
            }
        }
        visit(roots, depth: 0)
        return rows
    }
}
