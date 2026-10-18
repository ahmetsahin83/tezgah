import SwiftUI

/// First launch: no projects yet.
struct WelcomeView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            appIcon
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 6) {
                Text("Tezgah'a hoş geldin")
                    .font(.system(size: 26, weight: .semibold))
                Text("Projelerin, terminallerin, git, veritabanı ve Claude tek pencerede.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Button {
                store.addProjectsViaPanel()
            } label: {
                Label("Proje Ekle…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Proje ekle (⌘O)")

            HStack(alignment: .top, spacing: 14) {
                FeatureTile(symbol: "sparkle", tint: .claudeAccent, title: "Ajanlar", detail: "Claude ve Codex")
                FeatureTile(symbol: "arrow.triangle.branch", tint: Color(hex: 0xF05033), title: "Git", detail: "Değişiklikler, diff, grafik")
                FeatureTile(symbol: "cylinder.split.1x2", tint: Color(hex: 0x00A8A8), title: "Veritabanı", detail: "Postgres, MySQL, SQLite")
                FeatureTile(symbol: "iphone", tint: Color(hex: 0x3FB950), title: "Önizleme", detail: "Tarayıcı ve simülatör")
            }
            .padding(.top, 10)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.25)) { appeared = true }
        }
    }

    /// The app's icon; run outside a .app (swift run, tests) there is none, so draw a stand-in.
    @ViewBuilder
    private var appIcon: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage).resizable()
        } else {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A3142), Color(hex: 0x151925)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(Color(hex: 0x6EE7B7))
                        .offset(x: -14, y: -10)
                }
                .padding(10)
        }
    }
}

private struct FeatureTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.13)))
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 118)
        .accessibilityElement(children: .combine)
    }
}

/// A project with no tabs open: ways to start, and recent files.
struct ProjectStartView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 24, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ActionCard(symbol: "sparkle", tint: .claudeAccent, title: "Claude", detail: "Yeni oturum", shortcut: "⇧⌘C") {
                        store.newClaudeSession()
                    }
                    ActionCard(symbol: AgentProvider.codex.symbol, tint: AgentProvider.codex.accent, title: "Codex", detail: "Yeni oturum", shortcut: "⇧⌘X") {
                        store.newCodexSession()
                    }
                    ActionCard(symbol: "terminal", tint: Color(hex: 0x4EAA25), title: "Terminal", detail: "Proje klasöründe", shortcut: "⌘T") {
                        store.newTerminal()
                    }
                    ActionCard(symbol: "doc.text.magnifyingglass", tint: Color(hex: 0x4C8DF6), title: "Dosya aç", detail: "Adına göre bul", shortcut: "⌘P") {
                        store.showQuickOpen()
                    }
                    ActionCard(symbol: "rectangle.split.3x1", tint: Color(hex: 0xA855F7), title: "Pano",
                               detail: project.board.openCount > 0 ? "\(project.board.openCount) açık iş" : "Yapılacaklar", shortcut: "⇧⌘K") {
                        store.showBoard()
                    }
                    ActionCard(symbol: "globe", tint: Color(hex: 0x4C8DF6), title: "Tarayıcı", detail: "Önizleme", shortcut: "⇧⌘B") {
                        store.showBrowser()
                    }
                    ActionCard(symbol: "iphone", tint: Color(hex: 0x3FB950), title: "Simülatör", detail: "iOS cihazı", shortcut: "⇧⌘I") {
                        store.showSimulator()
                    }
                }

                let recent = project.recentFiles.filter { !$0.hasPrefix("/") && FileManager.default.fileExists(atPath: project.url.appendingPathComponent($0).path) }.prefix(6)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Son dosyalar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(recent), id: \.self) { path in
                            RecentFileRow(path: path) {
                                store.openFile(project.url.appendingPathComponent(path))
                            }
                        }
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        var parts = [(project.url.path as NSString).abbreviatingWithTildeInPath]
        if let branch = project.git.status.branch { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}

private struct ActionCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.075 : (colorScheme == .dark ? 0.045 : 0.035)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.12 : 0.06))
            }
            .scaleEffect(isHovering ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint("Kısayol \(shortcut)")
    }
}

private struct RecentFileRow: View {
    let path: String
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                FileTypeIcon(path: path)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12.5))
                let folder = (path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// An empty area: a tinted symbol, a short title, what to do next. One look across Tezgah.
struct EmptyState: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    var message: String?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(Circle().fill(tint.opacity(0.13)))
                .scaleEffect(appeared ? 1 : 0.85)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(24)
        .opacity(appeared ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.3)) { appeared = true } }
        .accessibilityElement(children: .combine)
    }
}
