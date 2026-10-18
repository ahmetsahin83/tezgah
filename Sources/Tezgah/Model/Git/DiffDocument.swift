import Foundation
import Observation

/// A diff shown in a tab: one changed file, or a whole commit.
@MainActor
@Observable
final class DiffDocument: Identifiable {
    enum Source: Equatable {
        case change(path: String, area: GitChange.Area)
        case commit(GitCommit)
        /// Changes to repository-relative `paths` since a working-tree snapshot, e.g. a Claude session's.
        case snapshot(tree: String, paths: [String], title: String)
    }

    let id = UUID()
    let repository: GitRepository
    private(set) var source: Source
    /// Preview tabs (italic title) are reused by the next click in the git panel; pinned ones stay.
    var isPreview = true
    private(set) var diff: ParsedDiff?
    private(set) var commitBody = ""
    /// The file no longer has changes (committed, discarded…).
    private(set) var hasNoChanges = false

    @ObservationIgnored private var loading: Task<Void, Never>?

    init(repository: GitRepository, source: Source) {
        self.repository = repository
        self.source = source
    }

    var title: String {
        switch source {
        case .change(let path, _): (path as NSString).lastPathComponent
        case .commit(let commit): commit.shortHash
        case .snapshot(_, let paths, let title):
            paths.count == 1 ? "\(title): \((paths[0] as NSString).lastPathComponent)" : title
        }
    }

    var tooltip: String {
        switch source {
        case .change(let path, let area): "\(path) (\(area == .staged ? "hazır" : "çalışma alanı"))"
        case .commit(let commit): "\(commit.shortHash) \(commit.subject)"
        case .snapshot(_, let paths, let title): "\(title)\n" + paths.joined(separator: "\n")
        }
    }

    /// The change this tab shows, as it currently appears in `git status`.
    var currentChange: GitChange? {
        guard case .change(let path, let area) = source else { return nil }
        return repository.change(at: path, preferring: area)
    }

    func show(_ source: Source) {
        guard source != self.source else { return }
        self.source = source
        diff = nil
        commitBody = ""
        hasNoChanges = false
        reload()
    }

    func reload() {
        loading?.cancel()
        loading = Task {
            switch source {
            case .change(let path, _):
                guard let change = currentChange else {
                    hasNoChanges = true
                    return
                }
                hasNoChanges = false
                // Follow the file when it moves between "changes" and "staged".
                if case .change(_, let area) = source, change.area != area {
                    source = .change(path: path, area: change.area)
                }
                let loaded = await repository.diff(for: change, replacing: diff)
                if !Task.isCancelled, let loaded, loaded != diff { diff = loaded }
            case .commit(let commit):
                guard diff == nil, let detail = await repository.detail(for: commit), !Task.isCancelled else { return }
                commitBody = detail.body
                diff = detail.diff
            case .snapshot(let tree, let paths, _):
                let loaded = await repository.diff(since: tree, paths: paths, replacing: diff)
                guard !Task.isCancelled, let loaded else { return }
                hasNoChanges = loaded.lines.isEmpty
                if loaded != diff { diff = loaded }
            }
        }
    }
}
