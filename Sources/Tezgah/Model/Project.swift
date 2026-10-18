import AppKit
import Observation

enum WorkspaceTab: Identifiable {
    case terminal(TerminalSession)
    case editor(EditorDocument)
    case diff(DiffDocument)
    case search(SearchModel)
    case database(DatabaseSession)
    case board(ProjectBoard)
    case browser(BrowserSession)
    case simulator(SimulatorSession)
    /// A card's orchestra run.
    case run(RunPage)

    var id: UUID {
        switch self {
        case .terminal(let session): session.id
        case .editor(let document): document.id
        case .diff(let document): document.id
        case .search(let model): model.id
        case .database(let session): session.id
        case .board(let board): board.id
        case .browser(let session): session.id
        case .simulator(let session): session.id
        case .run(let page): page.cardID
        }
    }

    /// Whether keyboard focus is inside this tab's content, for tabs that can tell.
    @MainActor var hasKeyboardFocus: Bool {
        switch self {
        case .terminal(let session):
            guard let responder = session.view.window?.firstResponder as? NSView else { return false }
            return responder === session.view || responder.isDescendant(of: session.view)
        case .editor(let document):
            return document.hasKeyboardFocus
        case .database(let session):
            return session.hasKeyboardFocus
        case .browser(let session):
            guard let responder = session.webView.window?.firstResponder as? NSView else { return false }
            return responder === session.webView || responder.isDescendant(of: session.webView)
        case .diff, .search, .board, .simulator, .run:
            return false
        }
    }
}

@MainActor
@Observable
final class Project: Identifiable {
    let id = UUID()
    let url: URL
    let root: FileNode
    let git: GitRepository
    let fileIndex: FileIndex
    var tabs: [WorkspaceTab] = []
    /// Project-relative paths of recently opened files, most recent first.
    private(set) var recentFiles: [String] = []
    var selectedTabID: UUID? {
        didSet {
            // A tab can only be on screen once: picking the side tab swaps the two.
            if let selectedTabID, selectedTabID == splitTabID {
                splitTabID = oldValue
            }
            noteEditorShown(selectedTabID)
        }
    }
    /// The tab shown next to the selected one, if the view is split.
    var splitTabID: UUID? {
        didSet { noteEditorShown(splitTabID) }
    }
    /// The editor the user looked at last, for "the file I'm in" while they talk to Claude.
    @ObservationIgnored private(set) var lastEditorID: UUID?

    private func noteEditorShown(_ id: UUID?) {
        guard let id, tabs.contains(where: { if case .editor(let document) = $0 { document.id == id } else { false } }) else { return }
        lastEditorID = id
    }

    /// The editor in front, or else the one looked at last.
    var currentEditor: EditorDocument? {
        if let focusedDocument { return focusedDocument }
        if case .editor(let document) = splitTab { return document }
        return documents.first { $0.id == lastEditorID }
    }
    /// Commands found in the project's build files, refreshed when they change.
    private(set) var detectedCommands: [ProjectCommand] = []
    /// Commands the user added; saved with the workspace.
    var customCommands: [ProjectCommand] = []
    /// The command run most recently, for "run again".
    var lastCommand: ProjectCommand?
    /// The bar of Makefile targets above the tabs; the user can hide it.
    var showsRunBar = true
    /// Saved database connections; passwords live in the Keychain.
    var databases: [DatabaseConfig] = []
    /// The connections agents query on, by connection: sessions of their own, never shown as tabs.
    @ObservationIgnored var agentDatabases: [UUID: DatabaseSession] = [:]
    /// Who develops, reviews and decides when the orchestra runs a card.
    var orchestraTeam = OrchestraTeam()
    /// The orchestra running the to-do cards one by one; nil when it isn't.
    var orchestraQueue: OrchestraQueue?
    @ObservationIgnored private var terminalCounter = 0
    @ObservationIgnored private var watcher: FileWatcher?
    /// Repositories of the agents' worktrees under `.tezgah/worktrees`, by folder.
    @ObservationIgnored private var worktreeRepositories: [String: GitRepository] = [:]

    var name: String { url.lastPathComponent }
    var parentURL: URL { url.deletingLastPathComponent() }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var selectedDocument: EditorDocument? {
        if case .editor(let document) = selectedTab { return document }
        return nil
    }

    var splitTab: WorkspaceTab? {
        tabs.first { $0.id == splitTabID }
    }

    /// The tab the user is working in: the side one when it has keyboard focus, otherwise the selected one.
    var focusedTab: WorkspaceTab? {
        if let splitTab, splitTab.hasKeyboardFocus { return splitTab }
        return selectedTab
    }

    var focusedDocument: EditorDocument? {
        if case .editor(let document) = focusedTab { return document }
        return nil
    }

    var databaseSessions: [DatabaseSession] {
        tabs.compactMap { if case .database(let session) = $0 { session } else { nil } }
    }

    var browsers: [BrowserSession] {
        tabs.compactMap { if case .browser(let session) = $0 { session } else { nil } }
    }

    var simulator: SimulatorSession? {
        tabs.lazy.compactMap { if case .simulator(let session) = $0 { session } else { nil } }.first
    }

    /// The project's to-do board; its tab may or may not be open.
    let board = ProjectBoard()

    var searchModel: SearchModel? {
        tabs.lazy.compactMap { if case .search(let model) = $0 { model } else { nil } }.first
    }

    var documents: [EditorDocument] {
        tabs.compactMap { if case .editor(let document) = $0 { document } else { nil } }
    }

    var terminals: [TerminalSession] {
        tabs.compactMap { if case .terminal(let session) = $0 { session } else { nil } }
    }

    var diffDocuments: [DiffDocument] {
        tabs.compactMap { if case .diff(let document) = $0 { document } else { nil } }
    }

    init(url: URL) {
        self.url = url
        root = FileNode(url: url, isDirectory: true)
        root.isExpanded = true
        root.reload()
        git = GitRepository(projectURL: url)
        fileIndex = FileIndex(rootURL: url)
        watcher = FileWatcher(url: url) { [weak self] change in
            self?.handle(change)
        }
        watcher?.start()
        reloadCommands()
    }

    var commands: [ProjectCommand] {
        customCommands + detectedCommands.filter { detected in !customCommands.contains { $0.command == detected.command } }
    }

    /// Makefile targets, for the run bar and its ⌃1…⌃9 shortcuts.
    var runBarCommands: [ProjectCommand] {
        detectedCommands.filter { ["Makefile", "makefile", "GNUmakefile"].contains($0.source ?? "") }
    }

    func reloadCommands() {
        let found = ProjectCommandDetector.detect(in: url)
        if found != detectedCommands { detectedCommands = found }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// The repository a folder belongs to: an agent's worktree, or the project's own checkout.
    func repository(for directory: URL) -> GitRepository {
        let worktrees = FileWatcher.realPath(url.appendingPathComponent(Worktrees.folder).path) + "/"
        let path = FileWatcher.realPath(directory.path)
        guard path.hasPrefix(worktrees),
              let name = path.dropFirst(worktrees.count).split(separator: "/").first.map(String.init) else { return git }
        let folder = url.appendingPathComponent(Worktrees.folder).appendingPathComponent(name, isDirectory: true)
        if let repository = worktreeRepositories[folder.path] { return repository }
        let repository = GitRepository(projectURL: folder)
        worktreeRepositories[folder.path] = repository
        return repository
    }

    /// A worktree was removed.
    func forgetRepository(at folder: URL) {
        worktreeRepositories[folder.path] = nil
    }

    /// Reacts to changes made outside Tezgah: terminal commands, other editors, git, formatters.
    private func handle(_ change: FileWatcher.Change) {
        // Agents' worktrees: their edits are not the project's.
        let changed = change.folders.filter { $0 != ".tezgah" && !$0.hasPrefix(".tezgah/") }
        guard change.needsFullRescan || !changed.isEmpty else { return }
        let folders = changed.filter { $0 != ".git" && !$0.hasPrefix(".git/") }
        if change.needsFullRescan {
            root.refreshExpanded()
        } else {
            for folder in folders {
                root.loadedNode(at: folder)?.reloadIfLoaded()
            }
        }
        for document in documents {
            let folder = (relativePath(of: document.url) as NSString).deletingLastPathComponent
            if change.needsFullRescan || folders.contains(folder) {
                document.checkDisk()
            }
        }
        if change.needsFullRescan || folders.contains("") {
            reloadCommands() // Makefile, package.json… live in the project folder
        }
        // Covers both working-tree edits and .git changes (commit, checkout, pull in a terminal).
        git.scheduleRefresh()
    }

    func relativePath(of fileURL: URL) -> String {
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let path = fileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    func noteOpened(_ fileURL: URL) {
        let path = relativePath(of: fileURL)
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 30 { recentFiles.removeLast() }
    }

    func nextTerminalTitle() -> String {
        terminalCounter += 1
        return "Terminal \(terminalCounter)"
    }
}
