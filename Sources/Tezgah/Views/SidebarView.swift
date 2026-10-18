import SwiftUI

struct SidebarView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        List(selection: fileSelection) {
            Section("Projeler") {
                ForEach(store.groups) { group in
                    DisclosureGroup(isExpanded: expansion(of: group)) {
                        ForEach(group.projects) { project in
                            ProjectRow(project: project, isActive: project.id == store.activeProjectID)
                                .contentShape(Rectangle())
                                .onTapGesture { store.select(project) }
                                .contextMenu {
                                    Button("Finder'da Göster") {
                                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                                    }
                                    Divider()
                                    Button("Tezgah'tan Kaldır") { store.removeProject(project) }
                                }
                        }
                    } label: {
                        GroupRow(group: group)
                            .contentShape(Rectangle())
                            .onTapGesture { expansion(of: group).wrappedValue.toggle() }
                            .contextMenu {
                                Button("Klasördeki Yeni Projeleri Ekle") { store.addNewProjects(in: group) }
                                Button("Finder'da Göster") {
                                    NSWorkspace.shared.activateFileViewerSelecting([group.url])
                                }
                                Divider()
                                Button("Grubu Tezgah'tan Kaldır") { store.removeGroup(group) }
                            }
                    }
                }
            }

            if let project = store.activeProject {
                Section {
                    ForEach(project.root.children ?? []) { node in
                        FileTreeRow(node: node, project: project)
                    }
                } header: {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Button {
                            project.root.refreshExpanded()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Dosyaları yenile")
                        .accessibilityLabel("Dosyaları yenile")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    store.addProjectsViaPanel()
                } label: {
                    Label("Proje Ekle", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Proje Ekle (⌘O)")
                Spacer()
            }
            .padding(10)
        }
    }

    private func expansion(of group: ProjectGroup) -> Binding<Bool> {
        Binding(
            get: { store.isExpanded(group) },
            set: { store.setExpanded($0, for: group) }
        )
    }

    /// The tree's selection mirrors the open editor tab, and clicking a file opens it.
    private var fileSelection: Binding<URL?> {
        Binding(
            get: { store.activeProject?.selectedDocument?.url },
            set: { url in
                if let url { store.openFile(url) }
            }
        )
    }
}

private struct GroupRow: View {
    let group: ProjectGroup

    var body: some View {
        Label {
            HStack {
                Text(group.displayName)
                Spacer()
                Text("\(group.projects.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
        }
        .help((group.url.path as NSString).abbreviatingWithTildeInPath)
    }
}

private struct ProjectRow: View {
    let project: Project
    let isActive: Bool

    private var agentActivities: [AgentActivity] {
        project.tabs.compactMap { if case .terminal(let session) = $0 { session.agent } else { nil } }
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(project.name)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let status = AgentStatusIcon(summarizing: agentActivities) {
                    status.font(.caption)
                }
            }
        } icon: {
            ProjectAvatar(name: project.name)
        }
        .help(help)
    }

    private var help: String {
        var lines = [(project.url.path as NSString).abbreviatingWithTildeInPath]
        if let branch = project.git.status.branch { lines.append("Branch: \(branch)") }
        if !project.tabs.isEmpty { lines.append("\(project.tabs.count) sekme açık") }
        return lines.joined(separator: "\n")
    }
}

/// A project's initial on a colored tile; the color comes from the name, so it stays the same.
struct ProjectAvatar: View {
    let name: String
    var size: CGFloat = 18

    private static let palette: [UInt32] = [0x2E6BD9, 0x7C4DD8, 0xD9488A, 0xE8590C, 0x2F9E6E, 0x0C8DA8, 0xC28A1E, 0x5B6B8C]

    var body: some View {
        let initial = name.first(where: \.isLetter).map { String($0).uppercased() } ?? "#"
        let seed = name.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value }
        let color = Color(hex: Self.palette[Int(seed % UInt32(Self.palette.count))])
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
