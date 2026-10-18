import AppKit
import SwiftUI

/// A diff opened from the git panel: one changed file or a whole commit.
struct DiffTabView: View {
    @Environment(WorkspaceStore.self) private var store
    let document: DiffDocument

    var body: some View {
        VStack(spacing: 0) {
            switch document.source {
            case .change(let path, let area):
                changeHeader(path: path, area: area)
            case .commit(let commit):
                commitHeader(commit)
            case .snapshot(_, let paths, let title):
                snapshotHeader(paths: paths, title: title)
            }
            Divider()
            if document.hasNoChanges {
                ContentUnavailableView(
                    "Değişiklik kalmadı",
                    systemImage: "checkmark.circle",
                    description: Text(noChangesText)
                )
            } else if let diff = document.diff {
                DiffView(diff: diff)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: document.repository.refreshCount) {
            // Working-tree diffs follow edits, staging and commits.
            switch document.source {
            case .change, .snapshot: document.reload()
            case .commit: break
            }
        }
    }

    private func changeHeader(path: String, area: GitChange.Area) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(area == .staged ? "hazır" : "çalışma alanı")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let diff = document.diff {
                Group {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if let change = document.currentChange {
                changeActions(change)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    @ViewBuilder
    private func changeActions(_ change: GitChange) -> some View {
        let git = document.repository
        switch change.area {
        case .staged:
            Button("Unstage Et") { Task { await git.unstage([change]) } }
        case .unstaged:
            Button("Geri Al…") { discardWithConfirmation([change], git: git) }
            Button("Stage'le") { Task { await git.stage([change]) } }
        case .conflicted:
            Button("Çözüldü (Stage'le)") { Task { await git.stage([change]) } }
        }
        if let url = git.fileURL(for: change), FileManager.default.fileExists(atPath: url.path) {
            Button("Dosyayı Aç") { store.openFile(url) }
        }
    }

    private var noChangesText: String {
        if case .snapshot = document.source {
            return "Oturum başladığından beri bu dosyalarda net bir değişiklik yok."
        }
        return "Bu dosyada artık commit'lenmemiş bir değişiklik yok."
    }

    private func snapshotHeader(paths: [String], title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.secondary)
            Text(paths.count == 1 ? paths[0] : "\(paths.count) dosya")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(title.lowercased(with: Locale(identifier: "tr")))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let diff = document.diff {
                Group {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if paths.count == 1, let root = document.repository.root {
                let url = root.appendingPathComponent(paths[0])
                if FileManager.default.fileExists(atPath: url.path) {
                    Button("Dosyayı Aç") { store.openFile(url) }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .help(document.tooltip)
    }

    private func commitHeader(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
                .font(.headline)
            if !document.commitBody.isEmpty {
                Text(document.commitBody)
                    .font(.callout)
            }
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .dateTime)
                Text("·")
                Text(commit.hash).monospaced()
                Spacer()
                if let diff = document.diff {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
