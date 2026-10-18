import Foundation
import Observation

/// A file or folder in a project's tree. Folder contents are read lazily on first expand.
@Observable
final class FileNode: Identifiable, Hashable {
    static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    let url: URL
    let isDirectory: Bool
    var isExpanded = false
    /// `nil` until the folder has been read.
    private(set) var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Re-reads the folder only if it has been read before; unread folders are read on expand anyway.
    func reloadIfLoaded() {
        if children != nil { reload() }
    }

    func loadChildrenIfNeeded() {
        if children == nil { reload() }
    }

    func reload() {
        guard isDirectory else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        // Reuse existing nodes so expanded folders stay expanded after a refresh.
        let existing = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })

        children = urls
            .filter { !Self.hiddenNames.contains($0.lastPathComponent) }
            .map { childURL in
                let isDir = Self.isDirectory(childURL)
                if let node = existing[childURL], node.isDirectory == isDir { return node }
                return FileNode(url: childURL, isDirectory: isDir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// The already-loaded node at a path relative to this one ("" is this node), or nil
    /// if that part of the tree has not been read yet.
    func loadedNode(at relativePath: String) -> FileNode? {
        var node = self
        for component in relativePath.split(separator: "/") {
            guard let child = node.children?.first(where: { $0.name == component }) else { return nil }
            node = child
        }
        return node
    }

    /// Re-reads this folder and every expanded folder beneath it.
    func refreshExpanded() {
        guard isDirectory, children != nil else { return }
        reload()
        for child in children ?? [] where child.isExpanded {
            child.refreshExpanded()
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        return values?.isDirectory ?? false
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
