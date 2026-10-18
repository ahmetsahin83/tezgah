import AppKit
import Observation

/// Git state and operations for one project. Commands run in the repository root, which
/// can be above the project folder when the project is a sub-folder of a larger repo.
@MainActor
@Observable
final class GitRepository: Identifiable {
    enum PanelMode: Hashable { case changes, history }

    let id = UUID()
    let projectURL: URL

    private(set) var root: URL?
    /// The project's path inside the repository ("" or e.g. "apps/web/").
    private(set) var prefix = ""
    private(set) var hasChecked = false
    private(set) var status = GitStatus()
    private(set) var localBranches: [String] = []
    private(set) var remoteBranches: [String] = []
    private(set) var commits: [GitCommit] = [] {
        didSet { graph = CommitGraph(commits) }
    }
    /// Lanes for drawing `commits` as a graph.
    private(set) var graph = CommitGraph([])
    private(set) var unpushed: Set<String> = []
    /// Upstream commits not pulled yet; shown in the history beside the local ones.
    private(set) var incoming: Set<String> = []
    private(set) var busyLabel: String?
    var lastError: String?
    var commitMessage = ""
    var panelMode: PanelMode = .changes

    /// Selection in the side panel's lists.
    private(set) var selectedChangeIDs: Set<String> = []
    private(set) var selectedCommitID: String?
    /// Bumped after every status refresh, so open diff tabs know to reload.
    private(set) var refreshCount = 0

    /// Project-relative path → status letter, for the file tree.
    private(set) var decorations: [String: GitChange] = [:]
    /// Project-relative folders that contain changes.
    private(set) var changedFolders: Set<String> = []

    @ObservationIgnored private var runningRefresh: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var logLoaded = false
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?

    var isRepository: Bool { root != nil }
    var isBusy: Bool { busyLabel != nil }

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func change(withID id: String) -> GitChange? {
        status.allChanges.first { $0.id == id }
    }

    /// The current change for a file given by absolute path, if git reports one.
    func change(atAbsolutePath path: String) -> GitChange? {
        guard let relative = repositoryPath(ofAbsolutePath: path) else { return nil }
        return status.allChanges.first { $0.path == relative }
    }

    /// A file's path relative to the repository root, or nil if it is outside the repository.
    func repositoryPath(ofAbsolutePath path: String) -> String? {
        guard let root else { return nil }
        let rootPath = FileWatcher.realPath(root.path) + "/"
        let filePath = FileWatcher.realPath((path as NSString).deletingLastPathComponent) + "/" + (path as NSString).lastPathComponent
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    /// The file as it is in git's index (staged, or as committed if nothing is staged).
    /// Nil for untracked files and files outside the repository.
    func indexText(ofFile url: URL) async -> String? {
        if root == nil { await refresh() }
        guard let root, let path = repositoryPath(ofAbsolutePath: url.path),
              let output = try? await Git.run(["show", ":\(path)"], in: root),
              output.stdout.count <= EditorDocument.maxFileSize else { return nil }
        return String(data: output.stdout, encoding: .utf8)
    }

    /// Where a changed file lives on disk, preferring the project's own path.
    func fileURL(for change: GitChange) -> URL? {
        if change.path.hasPrefix(prefix) {
            return projectURL.appendingPathComponent(String(change.path.dropFirst(prefix.count)))
        }
        return root?.appendingPathComponent(change.path)
    }

    // MARK: Refresh

    /// Refreshes shortly, coalescing bursts of file events into one `git status`.
    func scheduleRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Returns once the status reflects everything that happened before the call. Calls that
    /// arrive during a refresh share it, plus one more pass, instead of returning stale data.
    func refresh() async {
        if let runningRefresh {
            needsRefresh = true
            await runningRefresh.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                needsRefresh = false
                await refreshOnce()
            } while needsRefresh
            // Cleared in the same main-actor step as the final check, so a caller that sees
            // a running refresh is guaranteed another pass.
            runningRefresh = nil
        }
        runningRefresh = task
        await task.value
    }

    private func refreshOnce() async {
        if root == nil {
            guard let output = try? await Git.run(["rev-parse", "--show-toplevel", "--show-prefix"], in: projectURL) else {
                hasChecked = true
                return
            }
            let lines = output.text.components(separatedBy: "\n")
            root = URL(fileURLWithPath: lines[0], isDirectory: true)
            prefix = lines.count > 1 ? lines[1] : ""
        }
        guard let root else { return }

        let newStatus: GitStatus
        do {
            let output = try await Git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root)
            newStatus = GitStatus.parse(output.stdout)
        } catch {
            // The repository may have been removed (rm -rf .git); check again next time.
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
                self.root = nil
                status = GitStatus()
                rebuildDecorations()
            }
            hasChecked = true
            return
        }
        hasChecked = true

        let previous = status
        if newStatus != previous {
            status = newStatus
            rebuildDecorations()
            followSelectionAcrossAreas()
        }
        if newStatus.branch != previous.branch || localBranches.isEmpty {
            await loadBranches()
        }
        if logLoaded, newStatus.headOID != previous.headOID || newStatus.ahead != previous.ahead {
            await loadLog()
        }
        refreshCount += 1
    }

    private func rebuildDecorations() {
        var decorations: [String: GitChange] = [:]
        var folders: Set<String> = []
        // Conflicts first, then working-tree changes, which matter more than staged ones.
        for change in status.conflicted + status.unstaged + status.staged where change.path.hasPrefix(prefix) {
            let relative = String(change.path.dropFirst(prefix.count))
            if decorations[relative] == nil { decorations[relative] = change }
            var components = relative.split(separator: "/")
            components.removeLast()
            while !components.isEmpty {
                folders.insert(components.joined(separator: "/"))
                components.removeLast()
            }
        }
        self.decorations = decorations
        changedFolders = folders
    }

    /// Keeps a file selected when it moves between "changes" and "staged".
    private func followSelectionAcrossAreas() {
        guard selectedChangeIDs.count == 1, let id = selectedChangeIDs.first, change(withID: id) == nil else { return }
        let path = String(id.split(separator: ":", maxSplits: 1).last ?? "")
        if let moved = status.allChanges.first(where: { $0.path == path }) {
            selectedChangeIDs = [moved.id]
        }
    }

    func loadBranches() async {
        guard let root,
              let output = try? await Git.run(
                ["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"],
                in: root
              ) else { return }
        let refs = output.lines
        let local = refs.filter { $0.hasPrefix("refs/heads/") }.map { String($0.dropFirst("refs/heads/".count)) }
        let localSet = Set(local)
        localBranches = local
        remoteBranches = refs
            .filter { $0.hasPrefix("refs/remotes/") && !$0.hasSuffix("/HEAD") }
            .map { String($0.dropFirst("refs/remotes/".count)) }
            .filter { remote in
                // Hide origin/x when a local x already exists.
                guard let slash = remote.firstIndex(of: "/") else { return true }
                return !localSet.contains(String(remote[remote.index(after: slash)...]))
            }
    }

    func loadLog() async {
        logLoaded = true
        guard let root, status.headOID != nil else {
            commits = []
            return
        }
        // The branch and its upstream together, like VS Code's graph: commits to pull show up too.
        var revisions = ["HEAD"]
        if status.upstream != nil { revisions.append("@{upstream}") }
        if let output = try? await Git.run(["log", "-n", "300", "--topo-order", "--format=\(GitCommit.logFormat)"] + revisions, in: root) {
            let parsed = GitCommit.parseLog(output.text)
            if parsed != commits { commits = parsed }
        }
        if status.upstream != nil {
            unpushed = Set((try? await Git.run(["rev-list", "@{upstream}..HEAD"], in: root))?.lines ?? [])
            incoming = Set((try? await Git.run(["rev-list", "HEAD..@{upstream}"], in: root))?.lines ?? [])
        } else {
            unpushed = []
            incoming = []
        }
    }

    // MARK: Selection and diffs

    func selectChanges(_ ids: Set<String>) {
        if ids != selectedChangeIDs { selectedChangeIDs = ids }
    }

    func selectCommit(_ id: String?) {
        if id != selectedCommitID { selectedCommitID = id }
    }

    /// The change at `path`, preferring `area`. A file that was just staged or unstaged
    /// is found in its new area.
    func change(at path: String, preferring area: GitChange.Area) -> GitChange? {
        let matches = status.allChanges.filter { $0.path == path }
        return matches.first { $0.area == area } ?? matches.first
    }

    /// `current` is returned as is when the diff text has not changed, which skips re-highlighting.
    func diff(for change: GitChange, replacing current: ParsedDiff?) async -> ParsedDiff? {
        guard let root else { return nil }
        let args: [String]
        var allowed: Set<Int32> = [0]
        switch (change.area, change.isUntracked) {
        case (.staged, _):
            args = ["diff", "--cached", "--no-ext-diff", "-M", "--", change.path] + (change.originalPath.map { [$0] } ?? [])
        case (_, true):
            // `--no-index` exits with 1 when the files differ, which is always here.
            args = ["diff", "--no-index", "--", "/dev/null", change.path]
            allowed = [0, 1]
        default:
            args = ["diff", "--no-ext-diff", "--", change.path]
        }
        guard let output = try? await Git.run(args, in: root, allowedExitCodes: allowed) else { return nil }
        return await Self.parseAndHighlight(output.stdout, showFileHeaders: false, unlessSameAs: current)
    }

    /// Parses off the main actor, then adds syntax colors. Returns `current` untouched when the
    /// diff text has not changed, so periodic refreshes do not re-highlight.
    private static func parseAndHighlight(_ data: Data, showFileHeaders: Bool, unlessSameAs current: ParsedDiff? = nil) async -> ParsedDiff {
        let parsed = await Task.detached { ParsedDiff.parse(data, showFileHeaders: showFileHeaders) }.value
        if let current, current.raw == parsed.raw { return current }
        let grammars = DiffHighlighter.grammars(for: parsed)
        guard !grammars.isEmpty else { return parsed }
        return await Task.detached {
            var highlighted = parsed
            highlighted.highlights = DiffHighlighter.highlights(for: parsed, grammars: grammars)
            return highlighted
        }.value
    }

    // MARK: Snapshots

    /// Records the whole working tree, untracked files included, as a git tree object and returns
    /// its hash. Uses a throwaway copy of the index, so the user's staging is left alone.
    func snapshotTree() async -> String? {
        if root == nil { await refresh() }
        guard let root else { return nil }
        let fileManager = FileManager.default
        let temporaryIndex = fileManager.temporaryDirectory.appendingPathComponent("tezgah-index-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryIndex) }
        do {
            // Starting from a copy of the real index lets git skip re-hashing unchanged files.
            let indexPath = try await Git.run(["rev-parse", "--git-path", "index"], in: root).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let realIndex = URL(fileURLWithPath: indexPath, relativeTo: root)
            if fileManager.fileExists(atPath: realIndex.path) {
                try fileManager.copyItem(at: realIndex, to: temporaryIndex)
            }
            let environment = ["GIT_INDEX_FILE": temporaryIndex.path]
            _ = try await Git.run(["add", "-A"], in: root, environment: environment)
            let tree = try await Git.run(["write-tree"], in: root, environment: environment).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tree.isEmpty ? nil : tree
        } catch {
            NSLog("Tezgah: could not snapshot the working tree: \(error)")
            return nil
        }
    }

    /// What changed in `paths` (repository-relative) between a snapshot and now.
    func diff(since snapshot: String, paths: [String], replacing current: ParsedDiff?) async -> ParsedDiff? {
        guard let root, !paths.isEmpty, let now = await snapshotTree(),
              let output = try? await Git.run(["diff", "--no-ext-diff", "-M", snapshot, now, "--"] + paths, in: root)
        else { return nil }
        return await Self.parseAndHighlight(output.stdout, showFileHeaders: paths.count > 1, unlessSameAs: current)
    }

    func detail(for commit: GitCommit) async -> GitCommitDetail? {
        guard let root,
              let output = try? await Git.run(
                ["show", "--no-ext-diff", "-M", "--diff-merges=first-parent", "--format=%B%x1e", commit.hash],
                in: root
              ) else { return nil }
        let data = output.stdout
        let separator = data.firstIndex(of: 0x1e) ?? data.endIndex
        let message = String(decoding: data[..<separator], as: UTF8.self)
        let patch = separator < data.endIndex ? data[data.index(after: separator)...] : Data()
        let body = message
            .components(separatedBy: "\n")
            .dropFirst() // subject is shown separately
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = await Self.parseAndHighlight(Data(patch), showFileHeaders: true)
        return GitCommitDetail(commit: commit, body: body, diff: diff)
    }

    // MARK: Operations

    func stage(_ changes: [GitChange]) async {
        let paths = Self.paths(of: changes)
        await perform { root in
            _ = try await Git.run(["add", "-A", "--"] + paths, in: root)
        }
    }

    func stageAll() async {
        await perform { root in
            _ = try await Git.run(["add", "-A"], in: root)
        }
    }

    func unstage(_ changes: [GitChange]) async {
        let paths = Self.paths(of: changes)
        await perform { [status] root in
            if status.headOID == nil {
                _ = try await Git.run(["rm", "--cached", "-r", "-q", "--"] + paths, in: root)
            } else {
                _ = try await Git.run(["restore", "--staged", "--"] + paths, in: root)
            }
        }
    }

    func unstageAll() async {
        await unstage(status.staged)
    }

    /// Throws away working-tree changes. Untracked files go to the Trash.
    func discard(_ changes: [GitChange]) async {
        let tracked = changes.filter { !$0.isUntracked }
        let untracked = changes.filter(\.isUntracked)
        await perform { root in
            if !tracked.isEmpty {
                _ = try await Git.run(["restore", "--"] + tracked.map(\.path), in: root)
            }
            for change in untracked {
                try FileManager.default.trashItem(at: root.appendingPathComponent(change.path), resultingItemURL: nil)
            }
        }
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let stageEverything = status.staged.isEmpty
        let succeeded = await perform(label: "Commit") { root in
            if stageEverything {
                _ = try await Git.run(["add", "-A"], in: root)
            }
            _ = try await Git.run(["commit", "-F", "-"], in: root, input: message)
        }
        if succeeded { commitMessage = "" }
    }

    func fetch() async {
        await perform(label: "Fetch") { root in
            _ = try await Git.run(["fetch", "--all", "--prune"], in: root)
        }
        await loadBranches()
    }

    func pull() async {
        await perform(label: "Pull") { root in
            _ = try await Git.run(["pull"], in: root)
        }
    }

    func push() async {
        await perform(label: "Push") { root in
            try await Git.push(in: root)
        }
    }

    func switchBranch(_ name: String) async {
        guard name != status.branch else { return }
        await perform(label: "Branch değişiyor") { root in
            _ = try await Git.run(["switch", name], in: root)
        }
    }

    /// Checks out a remote-only branch such as origin/feature as a local tracking branch.
    func checkoutRemoteBranch(_ remoteBranch: String) async {
        await perform(label: "Branch değişiyor") { root in
            _ = try await Git.run(["switch", "--track", remoteBranch], in: root)
        }
        await loadBranches()
    }

    func createBranch(_ name: String) async {
        await perform(label: "Branch oluşturuluyor") { root in
            _ = try await Git.run(["switch", "-c", name], in: root)
        }
        await loadBranches()
    }

    func initRepository() async {
        do {
            _ = try await Git.run(["init"], in: projectURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Runs a git operation, records any error and refreshes afterwards.
    /// A `label` marks long operations: the UI shows a spinner and disables other actions.
    @discardableResult
    private func perform(label: String? = nil, _ operation: (URL) async throws -> Void) async -> Bool {
        guard let root, !isBusy else { return false }
        busyLabel = label
        defer { busyLabel = nil }
        var succeeded = true
        do {
            try await operation(root)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            succeeded = false
        }
        await refresh()
        return succeeded
    }

    private static func paths(of changes: [GitChange]) -> [String] {
        changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
    }
}
