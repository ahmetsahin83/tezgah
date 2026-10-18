import AppKit
import SwiftUI

struct FileTreeRow: View {
    @Environment(WorkspaceStore.self) private var store
    let node: FileNode
    let project: Project

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children ?? []) { child in
                    FileTreeRow(node: child, project: project)
                }
            } label: {
                Label {
                    Text(node.name)
                        .foregroundStyle(project.git.changedFolders.contains(relativePath) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                } icon: {
                    FolderIcon(name: node.name, isOpen: node.isExpanded)
                }
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded.wrappedValue.toggle() }
                    .contextMenu {
                        Button("Burada Terminal Aç") { store.newTerminal(in: node.url) }
                        Divider()
                        sharedMenuItems
                    }
            }
        } else {
            let change = project.git.decorations[relativePath]
            Label {
                HStack {
                    Text(node.name)
                        .foregroundStyle(change.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
                    Spacer()
                    if let change {
                        Text(change.letter)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(change.color)
                    }
                }
            } icon: {
                FileTypeIcon(node.url)
            }
            .tag(node.url)
            .contextMenu { sharedMenuItems }
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { node.isExpanded },
            set: { expanded in
                if expanded { node.loadChildrenIfNeeded() }
                node.isExpanded = expanded
            }
        )
    }

    @ViewBuilder
    private var sharedMenuItems: some View {
        Button("Finder'da Göster") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Button("Yolu Kopyala") { copy(node.url.path) }
        Button("Göreli Yolu Kopyala") { copy(relativePath) }
    }

    private var relativePath: String {
        let root = project.url.path.hasSuffix("/") ? project.url.path : project.url.path + "/"
        let path = node.url.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "dart", "kt", "java", "go", "rs", "c", "h", "cpp", "m", "py", "rb", "php":
            "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "plist", "xml": "curlybraces"
        case "md", "markdown", "txt": "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico": "photo"
        case "sh", "zsh", "bash": "terminal"
        case "lock": "lock"
        default: "doc"
        }
    }
}
