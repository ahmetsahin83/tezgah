import SwiftUI

/// The project's name and branch at the leading edge of the toolbar, in place of the window title and folder path.
struct ProjectTitle: View {
    @Environment(\.colorScheme) private var scheme
    let project: Project
    /// macOS 14 still draws the window title, so the name is shown only once.
    var showsName = true

    var body: some View {
        HStack(spacing: 9) {
            if showsName {
                ProjectAvatar(name: project.name, size: 20)
                Text(project.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            let git = project.git
            if git.isRepository {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(git.status.branch ?? "detached")
                        .lineLimit(1)
                    if git.status.ahead > 0 {
                        Text("↑\(git.status.ahead)").foregroundStyle(Color.accentColor)
                    }
                    if git.status.behind > 0 {
                        Text("↓\(git.status.behind)").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Theme.chip(scheme)))
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
        .help((project.url.path as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .combine)
    }
}

/// The wide search field in the middle of the toolbar: files, commands and Claude, all from one place.
struct ToolbarSearchButton: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button {
            store.showQuickOpen()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Text("Ara ya da Claude'a sor…")
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chip(scheme)))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .frame(width: 320, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? Theme.hover(scheme) : Theme.chip(scheme).opacity(0.55))
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line(scheme)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Dosya aç, komut çalıştır ya da Claude'a sor (⌘K)")
        .accessibilityLabel("Ara ya da Claude'a sor")
    }
}

/// "+" in the toolbar: every kind of tab, database connections and project commands.
struct ToolbarAddMenu: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project
    @State private var isAddingCommand = false
    @State private var editingDatabase: DatabaseConfig?

    var body: some View {
        @Bindable var store = store
        Menu {
            Button("Yeni Terminal") { store.newTerminal() }
            Menu("Claude") {
                Button("Yeni Oturum") { store.newClaudeSession() }
                Button("Son Oturumu Sürdür") { store.newClaudeSession(.continueLast) }
                Button("Önceki Oturumlardan Seç…") { store.newClaudeSession(.pick) }
            }
            Menu("Codex") {
                Button("Yeni Oturum") { store.newCodexSession() }
                Button("Son Oturumu Sürdür") { store.newCodexSession(.continueLast) }
                Button("Önceki Oturumlardan Seç…") { store.newCodexSession(.pick) }
            }
            Divider()
            Button("Pano") { store.showBoard() }
            Button("Tarayıcı Önizleme") { store.showBrowser() }
            Button("iOS Simülatörü") { store.showSimulator() }
            Divider()
            Menu("Veritabanı") {
                ForEach(project.databases) { database in
                    Button("\(database.name) — \(database.summary)") { store.openDatabase(database) }
                }
                if !project.databases.isEmpty { Divider() }
                Button("Bağlantı Ekle…") { store.isAddingDatabase = true }
                if !project.databases.isEmpty {
                    Menu("Düzenle") {
                        ForEach(project.databases) { database in
                            Button(database.name) { editingDatabase = database }
                        }
                    }
                    Menu("Sil") {
                        ForEach(project.databases) { database in
                            Button(database.name) { store.removeDatabase(database, from: project) }
                        }
                    }
                }
            }
            Menu("Komut Çalıştır") {
                let custom = project.customCommands
                if !custom.isEmpty {
                    Section("Komutlarım") {
                        ForEach(custom) { command in
                            Button(command.name) { store.run(command) }
                        }
                    }
                }
                let grouped = Dictionary(grouping: project.detectedCommands.filter { detected in
                    !custom.contains { $0.command == detected.command }
                }) { $0.source ?? "" }
                ForEach(grouped.keys.sorted(), id: \.self) { source in
                    Section(source) {
                        ForEach(grouped[source] ?? []) { command in
                            Button(command.name) { store.run(command) }
                        }
                    }
                }
                Divider()
                Button("Komut Ekle…") { isAddingCommand = true }
                if !custom.isEmpty {
                    Menu("Komut Sil") {
                        ForEach(custom) { command in
                            Button(command.name) { store.removeCustomCommand(command, from: project) }
                        }
                    }
                }
                if !project.showsRunBar, !project.runBarCommands.isEmpty {
                    Divider()
                    Button("Make Menüsünü Göster") { store.setRunBarVisible(true, in: project) }
                }
            }
        } label: {
            Label("Yeni", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("Yeni sekme, veritabanı, komut")
        .sheet(isPresented: $store.isAddingDatabase) {
            ConnectionSheet(project: project) { config, password in
                store.saveDatabase(config, password: password, in: project)
            }
        }
        .sheet(item: $editingDatabase) { database in
            ConnectionSheet(project: project, existing: database) { config, password in
                store.saveDatabase(config, password: password, in: project)
            }
        }
        .sheet(isPresented: $isAddingCommand) {
            AddCommandSheet { command in
                store.addCustomCommand(command, to: project)
                store.run(command)
            }
        }
    }
}
