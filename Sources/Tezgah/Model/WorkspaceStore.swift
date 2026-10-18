import AppKit
import Observation

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var projects: [Project] = []
    private(set) var activeProjectID: UUID?
    private(set) var collapsedGroupPaths: Set<String> = []
    private(set) var isQuickOpenVisible = false
    /// ">" when the panel opens as the command palette.
    private(set) var quickOpenInitialQuery = ""
    /// Palette commands used most recently first, so they top the list.
    @ObservationIgnored private var recentCommandIDs: [String] = []
    /// Shows the "add database connection" sheet (from the palette or the toolbar).
    var isAddingDatabase = false
    var isGitPanelVisible = false {
        didSet { if isGitPanelVisible != oldValue { persist() } }
    }
    @ObservationIgnored private weak var focusBeforeQuickOpen: NSResponder?

    var activeProject: Project? {
        projects.first { $0.id == activeProjectID }
    }

    /// Projects grouped by parent folder, groups and projects sorted by name.
    var groups: [ProjectGroup] {
        let byParent = Dictionary(grouping: projects) { $0.parentURL.path }
        // Two parents with the same folder name (~/a/bee, ~/b/bee) are shown by full path.
        let nameCounts = Dictionary(grouping: byParent.keys) { ($0 as NSString).lastPathComponent }.mapValues(\.count)
        return byParent
            .map { path, members in
                let name = (path as NSString).lastPathComponent
                return ProjectGroup(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    displayName: nameCounts[name, default: 0] > 1 ? (path as NSString).abbreviatingWithTildeInPath : name,
                    projects: members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Projects in sidebar order.
    var orderedProjects: [Project] {
        groups.flatMap(\.projects)
    }

    /// Where the project list is saved. Tests pass a temporary file.
    @ObservationIgnored private let snapshotURL: URL
    @ObservationIgnored let agentMonitor: AgentMonitor
    @ObservationIgnored let claudeMonitor: ClaudeMonitor
    @ObservationIgnored let codexMonitor: CodexMonitor
    /// Tools for the agent sessions Tezgah starts (browser preview, simulator, board).
    @ObservationIgnored let mcpServer = MCPServer()

    /// Off in tests that only care about the project list.
    @ObservationIgnored private let restoresTabs: Bool

    init(
        snapshotURL: URL = WorkspaceStore.defaultSnapshotURL,
        agentsDirectory: URL = AgentMonitor.defaultDirectory,
        restoresTabs: Bool = true
    ) {
        self.snapshotURL = snapshotURL
        self.restoresTabs = restoresTabs
        agentMonitor = AgentMonitor(directory: agentsDirectory)
        claudeMonitor = ClaudeMonitor(
            directory: agentsDirectory.appendingPathComponent("claude", isDirectory: true),
            hookURL: agentMonitor.hookURL
        )
        codexMonitor = CodexMonitor(hookURL: agentMonitor.hookURL)
        restore()
        agentMonitor.activityForTab = { [weak self] id in
            self?.terminal(withID: id)?.session.agent
        }
        claudeMonitor.activityForTab = { [weak self] id in
            self?.terminal(withID: id)?.session.claude
        }
        registerMCPTools()
        telegram.store = self
        orchestraClock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOrchestraTimeouts() }
        }
        mcpServer.start()
        do {
            try agentMonitor.start()
            try claudeMonitor.start()
        } catch {
            NSLog("Tezgah: could not set up agent session tracking: \(error)")
        }
        for project in projects {
            Task { await project.git.refresh() }
        }
        // File watching catches most changes; this is a fallback for what FSEvents can miss
        // (network volumes, a repository root above the project folder).
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if NSApp?.isActive == true {
                    await self.activeProject?.git.refresh()
                }
            }
        }
    }

    // MARK: Projects

    func addProjectsViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ekle"
        panel.message = "Proje klasörlerini ya da projelerin bulunduğu bir grup klasörünü (ör. ~/bee) seç"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addFolder)
    }

    /// Adds `url` as a project, or, if it is a folder of projects, offers to add each of them.
    func addFolder(_ url: URL) {
        let url = url.standardizedFileURL
        if !ProjectDetector.isProject(url) {
            let children = ProjectDetector.projects(in: url)
            if !children.isEmpty {
                switch askGroupOrProject(url, children: children) {
                case .alertFirstButtonReturn:
                    let added = children.map(insertProject)
                    if let first = added.first { select(first) }
                    return
                case .alertThirdButtonReturn:
                    break
                default:
                    return
                }
            }
        }
        select(insertProject(url))
    }

    /// Adds projects that appeared in the group's folder since it was last scanned.
    func addNewProjects(in group: ProjectGroup) {
        let known = Set(projects.map(\.url.path))
        let found = ProjectDetector.projects(in: group.url).filter { !known.contains($0.path) }
        guard !found.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "“\(group.displayName)” klasöründe eklenmemiş proje yok"
            alert.runModal()
            return
        }
        found.forEach { insertProject($0) }
        persist()
    }

    func select(_ project: Project) {
        hideQuickOpen(restoreFocus: false)
        activeProjectID = project.id
        collapsedGroupPaths.remove(project.parentURL.path)
        project.root.refreshExpanded()
        Task { await project.git.refresh() }
        persist()
    }

    func removeProject(_ project: Project) {
        removeProjects([project])
    }

    func removeGroup(_ group: ProjectGroup) {
        let alert = NSAlert()
        alert.messageText = "“\(group.displayName)” grubu Tezgah'tan kaldırılsın mı?"
        alert.informativeText = "Gruptaki \(group.projects.count) proje listeden çıkar, açık terminalleri kapanır. Dosyalara dokunulmaz."
        alert.addButton(withTitle: "Kaldır")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeProjects(group.projects)
    }

    func isExpanded(_ group: ProjectGroup) -> Bool {
        !collapsedGroupPaths.contains(group.id)
    }

    func setExpanded(_ expanded: Bool, for group: ProjectGroup) {
        if expanded {
            collapsedGroupPaths.remove(group.id)
        } else {
            collapsedGroupPaths.insert(group.id)
        }
        persist()
    }

    @discardableResult
    private func insertProject(_ url: URL) -> Project {
        let url = url.standardizedFileURL
        if let existing = projects.first(where: { $0.url.path == url.path }) {
            return existing
        }
        let project = Project(url: url)
        project.board.onChange = { [weak self] in self?.persist() }
        projects.append(project)
        Task { await project.git.refresh() }
        return project
    }

    private func removeProjects(_ removed: [Project]) {
        guard confirmDiscardingUnsavedChanges(in: removed.flatMap(\.documents)),
              confirmStoppingRunningProcesses(in: removed.flatMap(\.terminals)) else { return }
        let ids = Set(removed.map(\.id))
        for project in removed {
            project.stopWatching()
            for case .terminal(let session) in project.tabs {
                session.terminate()
                Notifier.shared.clear(tabID: session.id)
            }
            project.databaseSessions.forEach { $0.close() }
        }
        projects.removeAll { ids.contains($0.id) }
        if let active = activeProjectID, ids.contains(active) {
            activeProjectID = orderedProjects.first?.id
        }
        updateDockBadge()
        persist()
    }

    private func askGroupOrProject(_ url: URL, children: [URL]) -> NSApplication.ModalResponse {
        let names = children.map(\.lastPathComponent)
        var list = names.prefix(6).joined(separator: ", ")
        if names.count > 6 { list += " ve \(names.count - 6) proje daha" }

        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” bir grup klasörüne benziyor"
        alert.informativeText = "İçinde \(children.count) proje var: \(list).\n\nHepsini “\(url.lastPathComponent)” grubu altında ayrı projeler olarak ekleyebilirsin."
        alert.addButton(withTitle: "\(children.count) Projeyi Ekle")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Tek Proje Olarak Ekle")
        return alert.runModal()
    }

    // MARK: Tabs

    func newTerminal(in directory: URL? = nil) {
        guard let project = activeProject else { return }
        makeTerminal(in: project, directory: directory)
    }

    @discardableResult
    private func makeTerminal(in project: Project, directory: URL? = nil, title: String? = nil, select: Bool = true) -> TerminalSession {
        let session = TerminalSession(directory: directory ?? project.url, title: title ?? project.nextTerminalTitle())
        session.onExit = { [weak self, weak project, weak session] in
            guard let self, let project, let session else { return }
            self.removeTab(session.id, from: project)
        }
        project.tabs.append(.terminal(session))
        if select { project.selectedTabID = session.id }
        return session
    }

    // MARK: Project commands

    /// Runs a project command in a terminal tab. The tab it ran in before is reused when its
    /// shell is back at the prompt; if the command is still running, the user picks what to do.
    func run(_ command: ProjectCommand) {
        guard let project = activeProject else { return }
        project.lastCommand = command
        let previous = project.terminals.first { $0.projectCommand == command.command && $0.isRunning }
        guard let previous else {
            let session = makeTerminal(in: project, title: command.name)
            session.projectCommand = command.command
            session.run(command.command)
            return
        }
        project.selectedTabID = previous.id
        guard let process = previous.foregroundProcessName else {
            previous.run(command.command)
            return
        }
        let alert = NSAlert()
        alert.messageText = "“\(command.name)” hâlâ çalışıyor (\(process))"
        alert.addButton(withTitle: "Durdur ve Yeniden Çalıştır")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Yeni Sekmede Çalıştır")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            restart(command, in: previous)
        case .alertThirdButtonReturn:
            let session = makeTerminal(in: project, title: command.name)
            session.projectCommand = command.command
            session.run(command.command)
        default:
            break
        }
    }

    /// Ctrl-C, then the command again in the same tab once the program has exited.
    private func restart(_ command: ProjectCommand, in session: TerminalSession) {
        session.interrupt()
        Task { [weak session] in
            // Give the program a moment to exit so the command reaches the shell, not the program.
            for _ in 0..<40 {
                guard let session, session.foregroundProcessName != nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            session?.run(command.command)
        }
    }

    /// The terminal a project command runs in, while it is still running (not back at the prompt).
    func runningTerminal(for command: ProjectCommand, in project: Project) -> TerminalSession? {
        project.terminals.first { $0.projectCommand == command.command && $0.foregroundProcessName != nil }
    }

    /// Stops a running command and starts it again, without asking.
    func restart(_ command: ProjectCommand) {
        guard let project = activeProject else { return }
        guard let session = runningTerminal(for: command, in: project) else {
            run(command)
            return
        }
        project.lastCommand = command
        project.selectedTabID = session.id
        restart(command, in: session)
    }

    func stop(_ command: ProjectCommand) {
        guard let project = activeProject else { return }
        runningTerminal(for: command, in: project)?.interrupt()
    }

    /// The run bar's buttons: start the target, or bring its terminal forward if it is already running.
    func runOrShow(_ command: ProjectCommand) {
        guard let project = activeProject else { return }
        if let session = runningTerminal(for: command, in: project) {
            if project.splitTabID != session.id { project.selectedTabID = session.id }
        } else {
            run(command)
        }
    }

    func setRunBarVisible(_ visible: Bool, in project: Project) {
        project.showsRunBar = visible
        persist()
    }

    func runLastCommand() {
        guard let command = activeProject?.lastCommand ?? activeProject?.commands.first else { return }
        run(command)
    }

    func setOrchestraTeam(_ team: OrchestraTeam, for project: Project) {
        project.orchestraTeam = team
        persist()
    }

    func addCustomCommand(_ command: ProjectCommand, to project: Project) {
        project.customCommands.removeAll { $0.command == command.command }
        project.customCommands.append(command)
        persist()
    }

    func removeCustomCommand(_ command: ProjectCommand, from project: Project) {
        project.customCommands.removeAll { $0.command == command.command }
        persist()
    }

    // MARK: Databases

    /// Opens a connection's tab, or brings its existing tab forward.
    func openDatabase(_ config: DatabaseConfig) {
        guard let project = activeProject else { return }
        openDatabase(config, in: project)
    }

    /// `beside`: a Claude tab using the connection; the database shows next to the conversation.
    @discardableResult
    func openDatabase(_ config: DatabaseConfig, in project: Project, beside tab: UUID? = nil) -> DatabaseSession {
        let session: DatabaseSession
        if let existing = project.databaseSessions.first(where: { $0.config.id == config.id }) {
            session = existing
            existing.connectIfNeeded()
        } else {
            session = DatabaseSession(config: config, projectURL: project.url, history: queryHistory(for: config))
            let insertIndex = project.tabs.firstIndex { $0.id == (tab ?? project.selectedTabID) }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.database(session), at: insertIndex)
        }
        if let tab, project.selectedTabID == tab {
            project.splitTabID = session.id
        } else if project.splitTabID != session.id {
            project.selectedTabID = session.id
        }
        return session
    }

    /// Where each connection's query history is kept, next to workspace.json.
    var queryHistoryDirectory: URL {
        snapshotURL.deletingLastPathComponent().appendingPathComponent("QueryHistory", isDirectory: true)
    }

    /// One history per connection, shared by its tab and its agents' session so neither saves
    /// over the other and the agents' queries show up in the tab's history as they run.
    func queryHistory(for config: DatabaseConfig) -> QueryHistory {
        if let history = queryHistories[config.id] { return history }
        let history = QueryHistory(directory: queryHistoryDirectory, connectionID: config.id)
        queryHistories[config.id] = history
        return history
    }

    /// The session agents query a connection on: its own, outside the tabs, so a query never takes
    /// the user to the database tab, clears what they have there or runs inside their transaction.
    func agentDatabase(_ config: DatabaseConfig, in project: Project) -> DatabaseSession {
        if let session = project.agentDatabases[config.id], session.config == config { return session }
        project.agentDatabases[config.id]?.close() // the connection changed
        let session = DatabaseSession(config: config, projectURL: project.url, history: queryHistory(for: config), forAgents: true)
        project.agentDatabases[config.id] = session
        return session
    }

    /// Saves a setting changed from the database tab itself (auto-commit), without reconnecting.
    func updateDatabaseConfig(_ config: DatabaseConfig, in project: Project) {
        guard let index = project.databases.firstIndex(where: { $0.id == config.id }) else { return }
        project.databases[index] = config
        persist()
    }

    /// Adds or updates a connection, stores its password and opens it.
    func saveDatabase(_ config: DatabaseConfig, password: String?, in project: Project) {
        DatabasePasswords.setPassword(password, for: config.id)
        if let index = project.databases.firstIndex(where: { $0.id == config.id }) {
            project.databases[index] = config
        } else {
            project.databases.append(config)
        }
        persist()
        if let session = project.databaseSessions.first(where: { $0.config.id == config.id }) {
            session.update(config)
        }
        if activeProjectID == project.id { openDatabase(config) }
    }

    func removeDatabase(_ config: DatabaseConfig, from project: Project) {
        let alert = NSAlert()
        alert.messageText = "“\(config.name)” bağlantısı silinsin mi?"
        alert.informativeText = "Bağlantı ayarları ve Keychain'deki parolası silinir. Veritabanının kendisine dokunulmaz."
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for session in project.databaseSessions where session.config.id == config.id {
            closeTab(session.id, in: project)
        }
        project.databases.removeAll { $0.id == config.id }
        DatabasePasswords.setPassword(nil, for: config.id)
        persist()
    }

    func toggleGitPanel() {
        isGitPanelVisible.toggle()
    }

    /// Shows a diff in a tab, VS Code style: an existing tab for the same diff is reused,
    /// otherwise the preview tab is replaced, otherwise a new preview tab opens.
    /// `repository`: an agent's worktree; the project's own by default.
    func openDiff(_ source: DiffDocument.Source, in repository: GitRepository? = nil, pin: Bool = false) {
        guard let project = activeProject else { return }
        let repository = repository ?? project.git
        let document: DiffDocument
        if let existing = project.diffDocuments.first(where: { $0.source == source && $0.repository === repository }) {
            document = existing
        } else if let preview = project.diffDocuments.first(where: { $0.isPreview && $0.repository === repository }) {
            document = preview
            document.show(source)
        } else {
            document = DiffDocument(repository: repository, source: source)
            let insertIndex = project.tabs.firstIndex { $0.id == project.selectedTabID }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.diff(document), at: insertIndex)
            document.reload()
        }
        if pin { document.isPreview = false }
        project.selectedTabID = document.id
    }

    func openFile(_ url: URL, line: Int? = nil, column: (column: Int, length: Int)? = nil) {
        guard let project = activeProject else { return }
        openFile(url, line: line, column: column, in: project)
    }

    func openFile(_ url: URL, line: Int? = nil, column: (column: Int, length: Int)? = nil, in project: Project) {
        project.noteOpened(url)
        let document: EditorDocument
        if let existing = project.documents.first(where: { $0.url.path == url.path }) {
            document = existing
        } else {
            document = EditorDocument(url: url, repository: project.git)
            // Open next to the current tab rather than at the far end.
            let insertIndex = project.tabs.firstIndex { $0.id == project.selectedTabID }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.editor(document), at: insertIndex)
        }
        project.selectedTabID = document.id
        if let line { document.reveal(line: line, column: column) }
    }

    // MARK: Search

    /// Opens (or brings back) the project's search tab, prefilled with the selected text.
    func showSearch() {
        guard let project = activeProject else { return }
        let selection = project.focusedDocument?.selectedSingleLineText
        let model: SearchModel
        if let existing = project.searchModel {
            model = existing
        } else {
            model = SearchModel(rootURL: project.url)
            let insertIndex = project.tabs.firstIndex { $0.id == project.selectedTabID }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.search(model), at: insertIndex)
        }
        if project.splitTabID != model.id {
            project.selectedTabID = model.id
        }
        model.focus(query: selection)
    }

    // MARK: Browser preview

    /// Opens a preview tab (reusing the project's existing one), optionally at an address.
    @discardableResult
    func showBrowser(_ url: URL? = nil, in project: Project? = nil, beside tab: UUID? = nil) -> BrowserSession? {
        guard let project = project ?? activeProject else { return nil }
        let session: BrowserSession
        if let existing = project.browsers.first {
            session = existing
        } else {
            session = BrowserSession()
            let insertIndex = project.tabs.firstIndex { $0.id == (tab ?? project.selectedTabID) }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.browser(session), at: insertIndex)
        }
        if let tab, project.selectedTabID == tab {
            // Claude drives it: keep the conversation in front, the page beside it.
            project.splitTabID = session.id
        } else if project.splitTabID != session.id {
            project.selectedTabID = session.id
        }
        if let url { session.open(url) }
        return session
    }

    // MARK: Simulator

    /// Opens (or brings up) the project's device tab.
    @discardableResult
    func showSimulator(in project: Project? = nil, beside tab: UUID? = nil) -> SimulatorSession? {
        guard let project = project ?? activeProject else { return nil }
        let session: SimulatorSession
        if let existing = project.simulator {
            session = existing
        } else {
            session = SimulatorSession()
            let insertIndex = project.tabs.firstIndex { $0.id == (tab ?? project.selectedTabID) }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.simulator(session), at: insertIndex)
        }
        if let tab, project.selectedTabID == tab {
            project.splitTabID = session.id
        } else if project.splitTabID != session.id {
            project.selectedTabID = session.id
        }
        return session
    }

    /// Installs AXe (touch input for the simulator) with Homebrew, in a terminal the user watches.
    func installAXe() {
        guard let project = activeProject else { return }
        let session = makeTerminal(in: project, title: "AXe kurulumu")
        session.run("brew install cameroncooke/axe/axe")
    }

    // MARK: Board

    /// Opens (or brings up) the project's board.
    func showBoard() {
        guard let project = activeProject else { return }
        if !project.tabs.contains(where: { $0.id == project.board.id }) {
            let insertIndex = project.tabs.firstIndex { $0.id == project.selectedTabID }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.board(project.board), at: insertIndex)
        }
        if project.splitTabID != project.board.id {
            project.selectedTabID = project.board.id
        }
    }

    /// Opens (or brings up) the page of a card's orchestra run.
    func showRunPage(of cardID: UUID, in project: Project) {
        if activeProjectID != project.id { select(project) }
        if !project.tabs.contains(where: { $0.id == cardID }) {
            let insertIndex = project.tabs.firstIndex { $0.id == project.selectedTabID }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(.run(RunPage(cardID: cardID, board: project.board)), at: insertIndex)
        }
        if project.splitTabID != cardID {
            project.selectedTabID = cardID
        }
    }

    /// "Claude'a ver" on a card: the card becomes a prompt in the project's Claude tab (a new one
    /// if there is none), ready to send, and moves to "Yapılıyor".
    func giveToClaude(_ card: BoardCard, in project: Project) {
        var prompt = card.title
        if !card.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + card.notes
        }
        project.board.move(card.id, to: .doing)
        if let session = project.terminals.first(where: { $0.claude != nil && $0.claude?.state != .ended }), let claude = session.claude {
            claude.composer.text = prompt
            claude.composer.pendingCursor = (prompt as NSString).length
            claude.viewMode = .conversation
            project.selectedTabID = session.id
            claude.composer.focus()
            return
        }
        if activeProjectID != project.id { select(project) }
        newClaudeSession { session in
            session.claude?.composer.text = prompt
            session.claude?.composer.focus()
        }
    }

    // MARK: Worktrees

    /// "Worktree'de başlat" on a card: a branch and worktree of its own, and an agent working on
    /// the card there. The card moves to "Yapılıyor".
    func startInWorktree(_ card: BoardCard, with provider: AgentProvider, in project: Project) {
        guard let root = project.git.root else {
            Self.showWorktreeError("Worktree açılamadı", "Bunun için proje bir git deposu olmalı.")
            return
        }
        let projectURL = project.url
        Task { [weak self, weak project] in
            do {
                let created = try await Worktrees.create(named: card.title, projectURL: projectURL, root: root)
                guard let self, let project, var current = project.board.cards.first(where: { $0.id == card.id }) else { return }
                current.worktree = BoardCard.Worktree(branch: created.branch, path: created.url.path)
                project.board.update(current)
                project.board.move(card.id, to: .doing)
                let directory = created.url.appendingPathComponent(project.git.prefix, isDirectory: true)
                let prompt = Self.worktreePrompt(for: current, branch: created.branch)
                if activeProjectID != project.id { select(project) }
                switch provider {
                case .claude:
                    newClaudeSession(in: project, directory: directory) { session in
                        session.claude?.composer.text = prompt
                        session.sendComposerDraft()
                    }
                case .codex:
                    newCodexSession(in: project, directory: directory, prompt: prompt)
                }
            } catch {
                Self.showWorktreeError("Worktree açılamadı", error.localizedDescription)
            }
        }
    }

    static func worktreePrompt(for card: BoardCard, branch: String) -> String {
        var prompt = card.title
        if !card.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + card.notes
        }
        return prompt + """


        Bu iş için ayrı bir git worktree'sindesin (dal: \(branch)). Değişiklikleri bu dalda yap ve iş \
        bitince commit'le; ana dala birleştirmeyi Tezgah yapacak.
        """
    }

    /// Terminal tabs (agents and shells) working in a card's worktree.
    func worktreeTabs(of card: BoardCard, in project: Project) -> [TerminalSession] {
        guard let worktree = card.worktree else { return [] }
        let folder = FileWatcher.realPath(worktree.path)
        return project.terminals.filter { session in
            let directory = FileWatcher.realPath(session.directory.path)
            return directory == folder || directory.hasPrefix(folder + "/")
        }
    }

    /// Brings up the agent working on the card, or a shell in its worktree when there is none.
    func showWorktree(of card: BoardCard, in project: Project) {
        guard let worktree = card.worktree else { return }
        let tabs = worktreeTabs(of: card, in: project)
        if activeProjectID != project.id { select(project) }
        if let tab = tabs.first(where: { $0.agent != nil }) ?? tabs.first {
            project.selectedTabID = tab.id
        } else {
            makeTerminal(in: project, directory: URL(fileURLWithPath: worktree.path, isDirectory: true), title: worktree.branch)
        }
    }

    /// Merges the card's branch into the project's checked-out branch, then removes the worktree and
    /// the branch; the card is done. Asks first, and refuses while the worktree has uncommitted work.
    func mergeWorktree(of card: BoardCard, in project: Project) {
        guard let worktree = card.worktree, let root = project.git.root else { return }
        let url = URL(fileURLWithPath: worktree.path, isDirectory: true)
        Task { [weak self, weak project] in
            if (try? await Worktrees.hasUncommittedChanges(at: url)) == true {
                Self.showWorktreeError(
                    "“\(worktree.branch)” dalında commit'lenmemiş değişiklikler var",
                    "Ajandan commit'lemesini iste ya da worktree'de bir terminalde commit'le; sonra yeniden birleştir."
                )
                return
            }
            guard let self, let project else { return }
            let tabs = worktreeTabs(of: card, in: project)
            let target = project.git.status.branch.map { "“\($0)” dalına" } ?? "projede açık olan dala"
            guard await ConfirmSheet.ask(
                title: "“\(worktree.branch)” birleştirilsin mi?",
                message: "Dal \(target) birleştirilecek, ardından worktree ve dal silinecek."
                    + (tabs.isEmpty ? "" : " Worktree'deki \(tabs.count) sekme kapanır."),
                confirm: "Birleştir",
                destructive: false
            ) else { return }
            do {
                try await Worktrees.merge(branch: worktree.branch, root: root)
            } catch {
                Self.showWorktreeError(
                    "“\(worktree.branch)” birleştirilemedi",
                    error.localizedDescription + "\n\nBirleştirme geri alındı; proje olduğu gibi duruyor."
                )
                await project.git.refresh()
                return
            }
            await finishWorktree(of: card, in: project, closing: tabs, force: false)
            project.board.move(card.id, to: .done)
            queueCardFinished(card.id, merged: true, in: project)
        }
    }

    /// Throws away the card's worktree and branch, uncommitted and unmerged work included.
    func discardWorktree(of card: BoardCard, in project: Project, removingCard: Bool = false) {
        guard let worktree = card.worktree else { return }
        Task { [weak self, weak project] in
            guard let self, let project else { return }
            let tabs = worktreeTabs(of: card, in: project)
            guard await ConfirmSheet.ask(
                title: removingCard ? "Kart, worktree'si ve “\(worktree.branch)” dalı silinsin mi?" : "“\(worktree.branch)” worktree'si silinsin mi?",
                message: "Dalda birleştirilmemiş ne varsa kaybolur."
                    + (tabs.isEmpty ? "" : " Worktree'deki \(tabs.count) sekme kapanır."),
                confirm: "Sil"
            ) else { return }
            await finishWorktree(of: card, in: project, closing: tabs, force: true)
            queueCardTakenOver(card.id, in: project)
            if removingCard { project.board.remove(card.id) }
        }
    }

    func finishWorktree(of card: BoardCard, in project: Project, closing tabs: [TerminalSession], force: Bool) async {
        guard let worktree = card.worktree, let root = project.git.root else { return }
        orchestraRuns[card.id] = nil // merged or thrown away by hand: nothing left to run
        for session in tabs {
            session.terminate()
            removeTab(session.id, from: project)
        }
        let url = URL(fileURLWithPath: worktree.path, isDirectory: true)
        do {
            try await Worktrees.remove(url, branch: worktree.branch, root: root, force: force)
        } catch {
            Self.showWorktreeError("Worktree temizlenemedi", error.localizedDescription)
        }
        project.forgetRepository(at: url)
        if var current = project.board.cards.first(where: { $0.id == card.id }) {
            current.worktree = nil
            project.board.update(current)
        }
        await project.git.refresh()
    }

    static func showWorktreeError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Sends a prompt to the project's Claude session (the one in front, else the first running one),
    /// starting a session when there is none.
    func askClaude(_ prompt: String, in project: Project) {
        let running = project.terminals.filter { $0.claude != nil && $0.claude?.state != .ended }
        let selected = running.first { $0.id == project.selectedTabID }
        if let session = selected ?? running.first, let claude = session.claude {
            claude.composer.text = prompt
            claude.viewMode = .conversation
            project.selectedTabID = session.id
            if activeProjectID != project.id { select(project) }
            session.sendComposerDraft()
            return
        }
        if activeProjectID != project.id { select(project) }
        newClaudeSession { session in
            session.claude?.composer.text = prompt
            session.sendComposerDraft()
        }
    }

    // MARK: Split view

    /// Splits the view with a neighbouring tab (or a new terminal), or closes the split.
    func toggleSplit() {
        guard let project = activeProject else { return }
        if project.splitTabID != nil {
            project.splitTabID = nil
            return
        }
        guard let selected = project.selectedTabID,
              let index = project.tabs.firstIndex(where: { $0.id == selected }) else { return }
        let neighbors = project.tabs.indices.filter { $0 != index }.sorted { abs($0 - index) < abs($1 - index) || (abs($0 - index) == abs($1 - index) && $0 > $1) }
        if let other = neighbors.first {
            project.splitTabID = project.tabs[other].id
        } else {
            let session = makeTerminal(in: project, select: false)
            project.splitTabID = session.id
        }
    }

    /// Shows a tab on the side, keeping the selected one in the main pane.
    func openInSplit(_ id: UUID, in project: Project) {
        if project.selectedTabID == id {
            // Move it aside; the main pane takes the nearest other tab.
            guard let index = project.tabs.firstIndex(where: { $0.id == id }) else { return }
            let others = project.tabs.indices.filter { $0 != index }
            guard let other = others.min(by: { abs($0 - index) < abs($1 - index) }) else { return }
            project.splitTabID = nil
            project.selectedTabID = project.tabs[other].id
        }
        project.splitTabID = id
    }

    /// Runs a command from a Claude conversation in a terminal beside the Claude tab, so the
    /// conversation stays in view. The "Komutlar" terminal is reused while it sits at the prompt.
    func runInTerminal(_ command: String, directory: URL) {
        guard let project = activeProject else { return }
        runInTerminal(command, directory: directory, in: project)
    }

    /// `name`: a terminal of its own (e.g. "dev server"), reused by name; otherwise the shared
    /// "Komutlar" terminal when it is free.
    @discardableResult
    func runInTerminal(_ command: String, directory: URL, in project: Project, name: String? = nil) -> TerminalSession {
        let title = name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name! : "Komutlar"
        let session: TerminalSession
        if let idle = project.terminals.first(where: { $0.runsClaudeCommands && $0.title == title && $0.isRunning && $0.foregroundProcessName == nil }) {
            session = idle
        } else {
            session = makeTerminal(in: project, directory: directory, title: title, select: false)
            session.runsClaudeCommands = true
        }
        if project.selectedTabID != session.id {
            project.splitTabID = session.id
        }
        // Claude's commands assume its folder; a reused shell may have moved.
        if FileWatcher.realPath(session.currentDirectory.path) != FileWatcher.realPath(directory.path) {
            session.run("cd " + AgentMonitor.quote(directory.path))
        }
        session.runPasted(command)
        return session
    }

    // MARK: Claude sessions

    /// In the active project's folder unless a project and a folder (an agent's worktree) are given.
    func newClaudeSession(
        _ launch: AgentLaunch = .new, in project: Project? = nil, directory: URL? = nil,
        configure: ((TerminalSession) -> Void)? = nil
    ) {
        guard let project = project ?? activeProject else { return }
        Task { [weak self, weak project] in
            guard let claudePath = await Self.findClaude() else {
                Self.showClaudeMissingAlert()
                return
            }
            guard let self, let project else { return }
            let session = await makeClaudeSession(in: project, launch: launch, claudePath: claudePath, directory: directory)
            showNewAgentTab(session, in: project)
            configure?(session)
        }
    }

    /// Puts a new agent tab after the selected one and brings it to the front.
    private func showNewAgentTab(_ session: TerminalSession, in project: Project) {
        let insertIndex = project.tabs.firstIndex { $0.id == project.selectedTabID }.map { $0 + 1 } ?? project.tabs.endIndex
        project.tabs.insert(.terminal(session), at: insertIndex)
        project.selectedTabID = session.id
        if activeProjectID != project.id { select(project) }
    }

    /// Follows an agent's state changes, and takes the working tree (the project's, or the
    /// worktree's the agent works in) before the agent can touch anything, so the session's own
    /// changes can be shown later.
    private func track(_ activity: AgentActivity, in project: Project, directory: URL) {
        activity.onChange = { [weak self] activity in
            self?.agentActivityChanged(activity)
        }
        let repository = project.repository(for: directory)
        Task { [weak activity] in
            if !repository.hasChecked { await repository.refresh() }
            guard repository.isRepository else { return }
            let tree = await repository.snapshotTree()
            activity?.baselineTree = tree
        }
    }

    /// A terminal running Claude Code with Tezgah's hooks, not yet added to the project's tabs.
    func makeClaudeSession(
        in project: Project,
        launch: AgentLaunch,
        claudePath: String,
        directory: URL? = nil,
        model: String? = nil,
        effort: String? = nil,
        readOnly: Bool = false,
        asksQuestions: Bool = true
    ) async -> TerminalSession {
        let configDirectory = ClaudeMonitor.configDirectory(environment: await ShellEnvironment.shared.environment())
        let ownStatusLine = ClaudeMonitor.hasOwnStatusLine(projectURL: project.url, configDirectory: configDirectory)
        let id = UUID()
        let directory = directory ?? project.url
        let activity = ClaudeActivity()
        if case .resume(let sessionID) = launch { activity.resumes(session: sessionID) }
        activity.viewMode = AppSettings.shared.claudeOpensAsConversation ? .conversation : .terminal
        if case .pick = launch {
            // Claude Code's own picker comes first.
            activity.viewMode = .terminal
            activity.returnsToConversationWhenLoaded = true
        }
        track(activity, in: project, directory: directory)
        activity.onRemoteControlChange = { [weak self] _ in
            self?.updateRemoteControlKeepAwake()
        }
        let remoteControl = AppSettings.shared.claudeRemoteControl
        if remoteControl { activity.remoteControl = .connecting }
        activity.canSkipPermissions = AppSettings.shared.agentsSkipPermissions
        if let effort { activity.effortLevel = effort }
        let session = TerminalSession(
            id: id,
            directory: directory,
            title: "Claude",
            command: claudeMonitor.command(
                for: launch, claudePath: claudePath, shell: TerminalSession.userShell, withStatusLine: !ownStatusLine,
                mcpConfig: await mcpConfig(forTab: id),
                remoteControlName: remoteControl ? "\(project.name) · Tezgah" : nil,
                model: model, effort: effort, readOnly: readOnly, skipPermissions: activity.canSkipPermissions, asksQuestions: asksQuestions
            ),
            environment: agentMonitor.environment(forTab: id).merging(claudeMonitor.environment) { $1 },
            agent: activity
        )
        session.onExit = { [weak self, weak project] in
            guard let self, let project else { return }
            self.removeTab(id, from: project)
        }
        if remoteControl { session.watchRemoteControl() }
        return session
    }

    // MARK: Codex sessions

    /// In the active project's folder unless a project and a folder (an agent's worktree) are given.
    /// `prompt` is the first message of a new session.
    func newCodexSession(
        _ launch: AgentLaunch = .new, in project: Project? = nil, directory: URL? = nil, prompt: String? = nil,
        configure: ((TerminalSession) -> Void)? = nil
    ) {
        guard let project = project ?? activeProject else { return }
        Task { [weak self, weak project] in
            guard let codexPath = await Self.findCodex() else {
                Self.showCodexMissingAlert()
                return
            }
            guard let self, let project else { return }
            let session = await makeCodexSession(in: project, launch: launch, codexPath: codexPath, directory: directory, prompt: prompt)
            showNewAgentTab(session, in: project)
            configure?(session)
        }
    }

    /// A terminal running Codex with Tezgah's hooks, not yet added to the project's tabs.
    func makeCodexSession(
        in project: Project,
        launch: AgentLaunch,
        codexPath: String,
        directory: URL? = nil,
        prompt: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        readOnly: Bool = false
    ) async -> TerminalSession {
        let id = UUID()
        let directory = directory ?? project.url
        let activity = CodexActivity()
        if case .resume(let sessionID) = launch { activity.resumes(session: sessionID) }
        track(activity, in: project, directory: directory)
        let toolsURL = await toolsURL(forTab: id)
        var environment = agentMonitor.environment(forTab: id)
        if toolsURL != nil { environment["TEZGAH_MCP_TOKEN"] = mcpServer.token }
        let session = TerminalSession(
            id: id,
            directory: directory,
            title: "Codex",
            command: codexMonitor.command(
                for: launch, codexPath: codexPath, shell: TerminalSession.userShell, mcpURL: toolsURL, prompt: prompt,
                model: model, effort: effort, readOnly: readOnly, skipPermissions: AppSettings.shared.agentsSkipPermissions
            ),
            environment: environment,
            agent: activity
        )
        session.onExit = { [weak self, weak project] in
            guard let self, let project else { return }
            self.removeTab(id, from: project)
        }
        return session
    }

    /// Starts Codex again in a Codex tab whose session ended, continuing the same conversation.
    func resumeCodex(in session: TerminalSession) {
        guard let activity = session.agent, activity.provider == .codex, activity.state == .ended,
              let sessionID = activity.sessionID else { return }
        Task { [weak self] in
            guard let codexPath = await Self.findCodex() else {
                Self.showCodexMissingAlert()
                return
            }
            guard let self else { return }
            // The tab's shell still has TEZGAH_TAB_ID and the tools' token, so events keep coming to this tab.
            session.run(codexMonitor.command(
                for: .resume(sessionID: sessionID), codexPath: codexPath, shell: TerminalSession.userShell,
                thenShell: false, mcpURL: await toolsURL(forTab: session.id),
                skipPermissions: AppSettings.shared.agentsSkipPermissions
            ))
            activity.restarting()
        }
    }

    /// Held while any Claude session is reachable remotely: a sleeping Mac would freeze it on the phone too.
    /// Only idle sleep is prevented; the display can still turn off.
    @ObservationIgnored private var remoteControlActivity: NSObjectProtocol?

    private func updateRemoteControlKeepAwake() {
        let reachable = projects.contains { project in
            project.terminals.contains { $0.claude?.remoteControl.isOn == true }
        }
        if reachable, remoteControlActivity == nil {
            remoteControlActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Claude oturumu uzaktan erişilebilir"
            )
        } else if !reachable, let activity = remoteControlActivity {
            ProcessInfo.processInfo.endActivity(activity)
            remoteControlActivity = nil
        }
    }

    /// Starts Claude Code again in a Claude tab whose session ended, continuing the same conversation.
    func resumeClaude(in session: TerminalSession) {
        guard let activity = session.claude, activity.state == .ended, let sessionID = activity.sessionID,
              let project = projects.first(where: { $0.tabs.contains { $0.id == session.id } }) else { return }
        Task { [weak self] in
            guard let claudePath = await Self.findClaude() else {
                Self.showClaudeMissingAlert()
                return
            }
            guard let self else { return }
            let configDirectory = ClaudeMonitor.configDirectory(environment: await ShellEnvironment.shared.environment())
            let ownStatusLine = ClaudeMonitor.hasOwnStatusLine(projectURL: project.url, configDirectory: configDirectory)
            // The tab's shell still has TEZGAH_TAB_ID, so events keep coming to this tab.
            activity.canSkipPermissions = AppSettings.shared.agentsSkipPermissions
            session.run(claudeMonitor.command(
                for: .resume(sessionID: sessionID), claudePath: claudePath, shell: TerminalSession.userShell,
                withStatusLine: !ownStatusLine, thenShell: false, mcpConfig: await mcpConfig(forTab: session.id),
                skipPermissions: activity.canSkipPermissions
            ))
            activity.restarting()
        }
    }

    /// Switches the active Claude tab between the conversation and Claude Code's terminal UI.
    func toggleClaudeView() {
        guard case .terminal(let session) = activeProject?.selectedTab else { return }
        if let activity = session.claude {
            activity.viewMode = activity.viewMode == .conversation ? .terminal : .conversation
            if activity.viewMode == .conversation { activity.composer.focus() }
        } else if let activity = session.agent as? CodexActivity {
            activity.viewMode = activity.viewMode == .conversation ? .terminal : .conversation
            if activity.viewMode == .conversation { activity.composer.focus() }
        }
    }

    /// An answer given from a permission notification. Only goes through while the same dialog
    /// is still open; otherwise the tab is brought up so the user can look.
    func answerPermission(tab id: UUID, request: Int, answer: Notifier.Answer) -> Bool {
        guard let (session, _) = terminal(withID: id), let agent = session.agent,
              agent.state == .needsPermission, agent.requestSerial == request else { return false }
        guard let activity = session.claude else {
            // Codex: its choices are read off the screen, and must still be there.
            guard let dialog = session.codexApproval, let allow = dialog.options.first, allow.allows else { return false }
            switch answer {
            case .allow: session.answerCodex(allow)
            case .always:
                guard let always = dialog.alwaysOption else { return false }
                session.answerCodex(always)
            case .deny: session.answerCodex(nil)
            }
            return true
        }
        switch answer {
        case .allow: session.sendClaudeKey(.option(1))
        case .always: session.sendClaudeKey(.option(2))
        case .deny: session.sendClaudeKey(.escape)
        }
        activity.userAnswered()
        return true
    }

    /// Font size changed in the settings: every open editor and terminal follows.
    func applyFonts() {
        let font = AppSettings.shared.terminalFont
        for project in projects {
            project.documents.forEach { $0.applyFont() }
            for session in project.terminals where session.view.font != font {
                session.view.font = font
            }
        }
    }

    /// `--mcp-config` for a Claude tab, or nil when the tool server could not start.
    private func mcpConfig(forTab id: UUID) async -> String? {
        guard AppSettings.shared.tezgahTools, let port = await mcpServer.readyPort() else { return nil }
        return mcpServer.config(forTab: id, port: port)
    }

    /// The tool server's address for a Codex tab, or nil when it could not start.
    private func toolsURL(forTab id: UUID) async -> String? {
        guard AppSettings.shared.tezgahTools, let port = await mcpServer.readyPort() else { return nil }
        return mcpServer.url(forTab: id, port: port)
    }

    /// The Claude tab with this id and its project, for tools working on behalf of a session.
    func claudeTab(_ id: UUID) -> (session: TerminalSession, project: Project)? {
        terminal(withID: id)
    }

    /// Fills in suggestions for what to ask next, once Claude's turn is over.
    private func suggestPrompts(for activity: ClaudeActivity) {
        guard PromptSuggester.isEnabled else { return }
        Task { [weak activity] in
            // The transcript is written just after the Stop hook; let it catch up.
            try? await Task.sleep(for: .milliseconds(800))
            guard let activity, activity.state == .finished, let entries = activity.transcript?.entries,
                  let claudePath = await Self.findClaude() else { return }
            let prompt = entries.last { if case .prompt = $0.kind { true } else { false } }
            let reply = entries.last { if case .reply = $0.kind { true } else { false } }
            guard case .prompt(let promptText, _) = prompt?.kind, case .reply(let replyText) = reply?.kind else { return }
            let suggestions = await PromptSuggester.suggest(prompt: promptText, reply: replyText, claudePath: claudePath)
            // Only if nothing happened meanwhile.
            guard activity.state == .finished || activity.state == .idle, activity.composer.text.isEmpty else { return }
            activity.suggestions = suggestions
        }
    }

    /// Brings a tab (and its project) to the front, e.g. from a clicked notification. The
    /// orchestra's notifications name a card (its run page) or a board.
    func focusTab(_ id: UUID) {
        if let project = projects.first(where: { $0.board.cards.contains { $0.id == id } }) {
            showRunPage(of: id, in: project)
            return
        }
        if let project = projects.first(where: { $0.board.id == id }) {
            if activeProjectID != project.id { select(project) }
            showBoard()
            return
        }
        guard let (_, project) = terminal(withID: id) else { return }
        if activeProjectID != project.id { select(project) }
        project.selectedTabID = id
        markVisibleAgentSessionSeen()
    }

    /// Clears the "needs attention" mark of the agent tab the user is looking at.
    func markVisibleAgentSessionSeen() {
        guard NSApp?.isActive == true,
              case .terminal(let session) = activeProject?.selectedTab else { return }
        session.agent?.markSeen()
    }

    /// Every agent tab in every project, most urgent first, for the sessions overview.
    var agentSessions: [(session: TerminalSession, project: Project)] {
        let all = orderedProjects.flatMap { project in
            project.tabs.compactMap { tab -> (TerminalSession, Project)? in
                if case .terminal(let session) = tab, session.agent != nil { (session, project) } else { nil }
            }
        }
        func rank(_ session: TerminalSession) -> Int {
            switch session.agent?.state {
            case .needsPermission: 0
            case .working: 1
            case .finished where session.agent?.isUnseen == true: 2
            case .starting: 3
            case .idle, .finished: 4
            default: 5
            }
        }
        return all.enumerated().sorted { a, b in
            (rank(a.element.0), a.offset) < (rank(b.element.0), b.offset)
        }.map(\.element)
    }

    /// Shows the sessions overview popover (menu, palette).
    var isAgentOverviewVisible = false

    /// Cards the orchestra is running, by card.
    var orchestraRuns: [UUID: OrchestraRun] = [:]
    /// Agents lead agents started, by their tab.
    var agentWorkers: [UUID: AgentWorker] = [:]
    @ObservationIgnored var queryHistories: [UUID: QueryHistory] = [:]
    /// Tezgah on Telegram; started by the app, never by a store made for tests.
    @ObservationIgnored let telegram = TelegramBot()
    /// Looks at the runs' time limits every minute.
    @ObservationIgnored private var orchestraClock: Timer?

    var agentSessionsNeedingAttention: Int {
        projects.reduce(0) { count, project in
            count + project.tabs.filter {
                if case .terminal(let session) = $0 { session.agent?.needsAttention == true } else { false }
            }.count
        }
    }

    private func agentActivityChanged(_ activity: AgentActivity) {
        guard let (session, project) = projects.lazy.compactMap({ project -> (TerminalSession, Project)? in
            for case .terminal(let session) in project.tabs where session.agent === activity {
                return (session, project)
            }
            return nil
        }).first else { return }

        orchestraNoticed(activity, in: session, project: project)
        // The orchestra tells about its own milestones; each agent's "finished" would only be noise.
        if activity.state == .finished, activity.isUnseen, orchestraRun(of: session.id)?.isActive == true {
            activity.markSeen() // comes back here with isUnseen == false
            return
        }

        let isVisible = NSApp?.isActive == true && activeProjectID == project.id && project.selectedTabID == session.id
        if isVisible, activity.isUnseen {
            activity.markSeen() // comes back here with isUnseen == false
            return
        }

        if let claude = activity as? ClaudeActivity, claude.wantsSuggestions {
            claude.wantsSuggestions = false
            suggestPrompts(for: claude)
        }

        if activity.needsAttention {
            switch activity.state {
            case .needsPermission:
                Notifier.shared.post(
                    title: "\(project.name) · Onay bekliyor",
                    body: activity.message ?? "\(activity.provider.displayName) devam etmek için iznini istiyor.",
                    tabID: session.id,
                    category: Self.notificationCategory(for: activity),
                    request: activity.requestSerial
                )
                announcePermission(activity, in: session, project: project)
            case .finished:
                Notifier.shared.post(
                    title: "\(project.name) · \(activity.provider.displayName) bitirdi",
                    body: activity.message ?? session.title,
                    tabID: session.id
                )
            default:
                break
            }
        } else {
            Notifier.shared.clear(tabID: session.id)
        }
        updateDockBadge()
    }

    /// Plain permissions can be answered right from the notification; Claude's questions and plans
    /// need the app. Codex offers "don't ask again" for commands and edits (a command prefix, the
    /// files, the session), and when its dialog has no such choice the answer opens the tab instead.
    static func notificationCategory(for activity: AgentActivity) -> Notifier.Category? {
        guard let request = activity.pendingRequest else { return nil }
        switch activity.provider {
        case .claude:
            guard !["AskUserQuestion", "ExitPlanMode"].contains(request.tool) else { return nil }
            return request.suggestions.isEmpty ? .permission : .permissionWithAlways
        case .codex:
            return ["Bash", AgentActivity.patchTool].contains(request.tool) ? .permissionWithAlways : .permission
        }
    }

    private func updateDockBadge() {
        let count = agentSessionsNeedingAttention
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func terminal(withID id: UUID) -> (session: TerminalSession, project: Project)? {
        for project in projects {
            for case .terminal(let session) in project.tabs where session.id == id {
                return (session, project)
            }
        }
        return nil
    }

    /// The `claude` executable, looked up in the login shell's PATH and the native installer's location.
    static func findClaude() async -> String? {
        await findExecutable("claude", alsoIn: [(NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")])
    }

    /// The `codex` executable, looked up in the login shell's PATH and Homebrew's folders.
    static func findCodex() async -> String? {
        await findExecutable("codex", alsoIn: ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    private static func findExecutable(_ name: String, alsoIn extraFolders: [String]) async -> String? {
        let environment = await ShellEnvironment.shared.environment()
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + extraFolders
        return folders
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func showClaudeMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Claude Code bulunamadı"
        alert.informativeText = """
        Terminalde şu komutla kurabilirsin:

        curl -fsSL https://claude.ai/install.sh | bash

        Sonra ~/.local/bin klasörünü PATH'ine ekle.
        """
        alert.runModal()
    }

    private static func showCodexMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Codex bulunamadı"
        alert.informativeText = """
        Terminalde şu komutla kurabilirsin:

        brew install codex

        Sonra codex login ile hesabına bağlan.
        """
        alert.runModal()
    }

    // MARK: Quick open

    func showQuickOpen() {
        showQuickOpen(query: "")
    }

    func showCommandPalette() {
        showQuickOpen(query: ">")
    }

    private func showQuickOpen(query: String) {
        guard activeProject != nil else { return }
        if isQuickOpenVisible {
            hideQuickOpen()
            return
        }
        quickOpenInitialQuery = query
        focusBeforeQuickOpen = NSApp.keyWindow?.firstResponder
        isQuickOpenVisible = true
    }

    func noteCommandUsed(_ id: String) {
        recentCommandIDs.removeAll { $0 == id }
        recentCommandIDs.insert(id, at: 0)
        if recentCommandIDs.count > 20 { recentCommandIDs.removeLast() }
    }

    /// Everything the command palette offers for a project, recently used first.
    func paletteCommands(for project: Project) -> [PaletteCommand] {
        let git = project.git
        var commands: [PaletteCommand] = [
            PaletteCommand(id: "browser.show", title: "Tarayıcı Önizleme", shortcut: "⇧⌘B", symbol: "globe") { [weak self] in self?.showBrowser() },
            PaletteCommand(id: "simulator.show", title: "iOS Simülatörü", shortcut: "⇧⌘I", symbol: "iphone") { [weak self] in self?.showSimulator() },
            PaletteCommand(id: "board.show", title: "Pano: Yapılacaklar", shortcut: "⇧⌘K", symbol: "rectangle.split.3x1") { [weak self] in self?.showBoard() },
            PaletteCommand(id: "terminal.new", title: "Yeni Terminal", shortcut: "⌘T", symbol: "terminal") { [weak self] in self?.newTerminal() },
            PaletteCommand(id: "claude.new", title: "Claude: Yeni Oturum", shortcut: "⇧⌘C", symbol: "sparkle") { [weak self] in self?.newClaudeSession() },
            PaletteCommand(id: "claude.continue", title: "Claude: Son Oturumu Sürdür", shortcut: "⌥⇧⌘C", symbol: "sparkle") { [weak self] in self?.newClaudeSession(.continueLast) },
            PaletteCommand(id: "claude.pick", title: "Claude: Önceki Oturumlardan Seç", symbol: "sparkle") { [weak self] in self?.newClaudeSession(.pick) },
            PaletteCommand(id: "codex.new", title: "Codex: Yeni Oturum", shortcut: "⇧⌘X", symbol: AgentProvider.codex.symbol) { [weak self] in self?.newCodexSession() },
            PaletteCommand(id: "codex.continue", title: "Codex: Son Oturumu Sürdür", shortcut: "⌥⇧⌘X", symbol: AgentProvider.codex.symbol) { [weak self] in self?.newCodexSession(.continueLast) },
            PaletteCommand(id: "codex.pick", title: "Codex: Önceki Oturumlardan Seç", symbol: AgentProvider.codex.symbol) { [weak self] in self?.newCodexSession(.pick) },
            PaletteCommand(id: "agents.overview", title: "Ajanlar: Tüm Oturumlar", shortcut: "⇧⌘A", symbol: "rectangle.stack") { [weak self] in self?.isAgentOverviewVisible = true },
            PaletteCommand(id: "claude.toggleView", title: "Ajanlar: Sohbet / Terminal Görünümü", shortcut: "⌘J", symbol: "rectangle.2.swap") { [weak self] in self?.toggleClaudeView() },
            PaletteCommand(id: "search", title: "Projede Ara", shortcut: "⇧⌘F", symbol: "magnifyingglass") { [weak self] in self?.showSearch() },
            PaletteCommand(id: "quickopen", title: "Dosya Aç", shortcut: "⌘P", symbol: "doc") { [weak self] in self?.showQuickOpen() },
            PaletteCommand(id: "split", title: project.splitTabID == nil ? "Görünüm: Yan Yana Böl" : "Görünüm: Bölmeyi Kapat", shortcut: "⌘\\", symbol: "rectangle.split.2x1") { [weak self] in self?.toggleSplit() },
            PaletteCommand(id: "git.panel", title: isGitPanelVisible ? "Git: Paneli Gizle" : "Git: Paneli Göster", shortcut: "⇧⌘G", symbol: "arrow.triangle.branch") { [weak self] in self?.toggleGitPanel() },
            PaletteCommand(id: "file.save", title: "Dosya: Kaydet", shortcut: "⌘S", symbol: "square.and.arrow.down") { [weak self] in self?.saveActiveTab() },
            PaletteCommand(id: "file.saveAll", title: "Dosya: Tümünü Kaydet", shortcut: "⌥⌘S", symbol: "square.and.arrow.down.on.square") { [weak self] in self?.saveAll() },
            PaletteCommand(id: "tab.close", title: "Sekmeyi Kapat", shortcut: "⌘W", symbol: "xmark") { [weak self] in self?.closeActiveTab() },
            PaletteCommand(id: "project.add", title: "Proje Ekle", shortcut: "⌘O", symbol: "plus") { [weak self] in self?.addProjectsViaPanel() },
            PaletteCommand(id: "project.finder", title: "Projeyi Finder'da Göster", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            },
        ]
        if let document = project.focusedDocument, document.isMarkdown {
            commands.append(PaletteCommand(id: "markdown.preview", title: "Markdown: Önizlemeyi Aç/Kapat", shortcut: "⇧⌘V", symbol: "eye") {
                document.toggleMarkdownPreview()
            })
        }
        if git.isRepository {
            commands += [
                PaletteCommand(id: "git.fetch", title: "Git: Fetch", symbol: "arrow.down.circle") { Task { await git.fetch() } },
                PaletteCommand(id: "git.pull", title: "Git: Pull", symbol: "arrow.down") { Task { await git.pull() } },
                PaletteCommand(id: "git.push", title: "Git: Push", symbol: "arrow.up") { Task { await git.push() } },
                PaletteCommand(id: "git.stageAll", title: "Git: Tümünü Stage'le", symbol: "plus.circle") { Task { await git.stageAll() } },
                PaletteCommand(id: "git.unstageAll", title: "Git: Tümünü Unstage Et", symbol: "minus.circle") { Task { await git.unstageAll() } },
            ]
            for branch in git.localBranches where branch != git.status.branch {
                commands.append(PaletteCommand(id: "git.switch.\(branch)", title: "Git: Branch'e Geç › \(branch.replacingOccurrences(of: "/", with: "∕"))", symbol: "arrow.triangle.branch") {
                    Task { await git.switchBranch(branch) }
                })
            }
        }
        for command in project.commands {
            commands.append(PaletteCommand(id: "run.\(command.command)", title: "Çalıştır: \(command.name.replacingOccurrences(of: "/", with: "∕"))", symbol: "play") { [weak self] in
                self?.run(command)
            })
        }
        commands.append(PaletteCommand(id: "database.add", title: "Veritabanı: Bağlantı Ekle", symbol: "plus") { [weak self] in
            self?.isAddingDatabase = true
        })
        for database in project.databases {
            commands.append(PaletteCommand(id: "database.\(database.id)", title: "Veritabanı › \(database.name.replacingOccurrences(of: "/", with: "∕"))", symbol: "cylinder.split.1x2") { [weak self] in
                self?.openDatabase(database)
            })
        }
        for other in orderedProjects where other.id != project.id {
            commands.append(PaletteCommand(id: "project.\(other.url.path)", title: "Projeye Geç › \(other.name)", symbol: "folder") { [weak self] in
                self?.select(other)
            })
        }
        let rank = Dictionary(uniqueKeysWithValues: recentCommandIDs.enumerated().map { ($1, $0) })
        return commands.enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Closes the panel. Focus goes back to where it was unless a file is about to take it.
    func hideQuickOpen(restoreFocus: Bool = true) {
        guard isQuickOpenVisible else { return }
        isQuickOpenVisible = false
        if restoreFocus, let responder = focusBeforeQuickOpen {
            NSApp.keyWindow?.makeFirstResponder(responder)
        }
        focusBeforeQuickOpen = nil
    }

    func closeTab(_ id: UUID, in project: Project) {
        guard let tab = project.tabs.first(where: { $0.id == id }) else { return }
        switch tab {
        case .terminal(let session):
            guard confirmStoppingRunningProcesses(in: [session]) else { return }
            session.terminate()
        case .editor(let document):
            guard confirmDiscardingUnsavedChanges(in: [document]) else { return }
        case .search, .board, .run:
            break
        case .browser(let session):
            session.stop()
        case .simulator(let session):
            session.removeViewer()
        case .database(let session):
            guard session.confirmClosing() else { return }
            session.close()
        case .diff(let document):
            // Clear the matching selection so clicking the same row again reopens the diff.
            switch document.source {
            case .change(let path, _):
                if project.git.selectedChangeIDs.contains(where: { $0.hasSuffix(":\(path)") }) {
                    project.git.selectChanges([])
                }
            case .commit(let commit):
                if project.git.selectedCommitID == commit.hash {
                    project.git.selectCommit(nil)
                }
            case .snapshot:
                break
            }
        }
        removeTab(id, from: project)
    }

    func closeActiveTab() {
        guard let project = activeProject, let id = project.focusedTab?.id else { return }
        closeTab(id, in: project)
    }

    func cycleTab(by offset: Int) {
        guard let project = activeProject, !project.tabs.isEmpty else { return }
        let current = project.tabs.firstIndex { $0.id == project.selectedTabID } ?? 0
        let next = (current + offset + project.tabs.count) % project.tabs.count
        project.selectedTabID = project.tabs[next].id
    }

    func saveActiveTab() {
        guard let project = activeProject, let document = project.focusedDocument else { return }
        if save(document) {
            Task { await project.git.refresh() }
        }
    }

    @discardableResult
    private func save(_ document: EditorDocument) -> Bool {
        if document.diskState == .changedOnDisk {
            let alert = NSAlert()
            alert.messageText = "“\(document.title)” diskte değişti"
            alert.informativeText = "Başka bir program bu dosyayı değiştirdi. Kaydedersen o değişikliklerin üzerine yazılır."
            alert.addButton(withTitle: "Üzerine Yaz")
            alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            try document.save()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "\"\(document.title)\" kaydedilemedi"
            alert.runModal()
            return false
        }
    }

    func removeTab(_ id: UUID, from project: Project) {
        guard let index = project.tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tabs.remove(at: index)
        if case .terminal(let session) = removed, session.agent != nil {
            Notifier.shared.clear(tabID: session.id)
            updateDockBadge()
        }
        if project.splitTabID == id {
            project.splitTabID = nil
        }
        if project.selectedTabID == id {
            if let side = project.splitTabID {
                // The side tab takes over the main pane.
                project.splitTabID = nil
                project.selectedTabID = side
            } else {
                let neighbor = min(index, project.tabs.count - 1)
                project.selectedTabID = neighbor >= 0 ? project.tabs[neighbor].id : nil
            }
        }
    }

    // MARK: Unsaved changes and running processes

    /// Asked before quitting: unsaved files first, then programs still running in terminals.
    func confirmQuitting() -> Bool {
        confirmDiscardingUnsavedChanges(in: projects.flatMap(\.documents))
            && confirmStoppingRunningProcesses(in: projects.flatMap(\.terminals))
    }

    func saveAll() {
        for project in projects {
            let dirty = project.documents.filter(\.isDirty)
            guard !dirty.isEmpty else { continue }
            for document in dirty where !save(document) { return }
            Task { await project.git.refresh() }
        }
    }

    /// Warns when closing would stop a running program (a dev server, an editor, a coding agent).
    /// Returns false if the user cancels.
    private func confirmStoppingRunningProcesses(in sessions: [TerminalSession]) -> Bool {
        let running = sessions.compactMap { session in
            session.foregroundProcessName.map { (session: session, process: $0) }
        }
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        if running.count == 1, let only = running.first {
            alert.messageText = if let agent = only.session.agent {
                "“\(only.session.title)” sekmesinde \(agent.provider.displayName) hâlâ açık"
            } else {
                "“\(only.session.title)” sekmesinde “\(only.process)” hâlâ çalışıyor"
            }
            alert.informativeText = "Kapatırsan işlem durdurulur."
        } else {
            alert.messageText = "\(running.count) terminalde çalışan işlem var"
            alert.informativeText = running.map { "• \($0.session.title): \($0.process)" }.joined(separator: "\n")
                + "\n\nKapatırsan hepsi durdurulur."
        }
        alert.addButton(withTitle: "Durdur ve Kapat")
        alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks about dirty documents: one by one for a single file, all at once for several.
    /// Returns false if the user cancels.
    private func confirmDiscardingUnsavedChanges(in documents: [EditorDocument]) -> Bool {
        let dirty = documents.filter(\.isDirty)
        if dirty.count > 1 {
            let alert = NSAlert()
            alert.messageText = "\(dirty.count) dosyada kaydedilmemiş değişiklik var"
            alert.informativeText = dirty.map { "• \($0.title)" }.joined(separator: "\n")
                + "\n\nKaydetmezsen değişiklikler kaybolur."
            alert.addButton(withTitle: "Tümünü Kaydet")
            alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Kaydetme")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return dirty.allSatisfy { save($0) }
            case .alertThirdButtonReturn:
                return true
            default:
                return false
            }
        }
        for document in dirty {
            let alert = NSAlert()
            alert.messageText = "\"\(document.title)\" dosyasındaki değişiklikler kaydedilsin mi?"
            alert.informativeText = "Kaydetmezsen değişiklikler kaybolur."
            alert.addButton(withTitle: "Kaydet")
            alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Kaydetme")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !save(document) { return false }
            case .alertThirdButtonReturn:
                continue
            default:
                return false
            }
        }
        return true
    }

    // MARK: Persistence

    struct Snapshot: Codable {
        var projectPaths: [String]
        var activeProjectPath: String?
        var collapsedGroupPaths: [String]?
        var gitPanelVisible: Bool?
        /// Open tabs and settings per project path.
        var projects: [String: ProjectState]?
    }

    struct ProjectState: Codable, Equatable {
        var tabs: [SavedTab] = []
        var selectedTab: Int?
        var splitTab: Int?
        var customCommands: [ProjectCommand]?
        var lastCommand: String?
        var databases: [DatabaseConfig]?
        var hidesRunBar: Bool?
        var board: [BoardCard]?
        var orchestraTeam: OrchestraTeam?
        var orchestraRuns: [SavedOrchestraRun]?
        var orchestraQueue: OrchestraQueue?
        var agentWorkers: [SavedAgentWorker]?
    }

    enum SavedTab: Codable, Equatable {
        case editor(path: String, markdownMode: String?)
        case terminal(directory: String, title: String?, command: String?)
        case claude(sessionID: String, directory: String)
        case codex(sessionID: String, directory: String)
        case search(query: String)
        case database(id: UUID, sql: String)
        case board
        case browser(url: String?)
        case simulator(udid: String?)
        case run(card: UUID)
    }

    nonisolated static var defaultSnapshotURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tezgah/workspace.json")
    }

    /// Claude tabs are restored asynchronously; a save in between would keep only the tabs restored so far,
    /// and lose the rest if Tezgah did not quit normally afterwards.
    @ObservationIgnored private var isRestoringTabs = false

    func persist() {
        guard !isRestoringTabs else { return }
        let snapshot = Snapshot(
            projectPaths: projects.map(\.url.path),
            activeProjectPath: activeProject?.url.path,
            collapsedGroupPaths: collapsedGroupPaths.sorted(),
            gitPanelVisible: isGitPanelVisible,
            projects: Dictionary(uniqueKeysWithValues: projects.map {
                ($0.url.path, Self.state(of: $0, runs: Array(orchestraRuns.values), workers: agentWorkers))
            })
        )
        do {
            let url = snapshotURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            NSLog("Tezgah: could not save workspace: \(error)")
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        projects = snapshot.projectPaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { Project(url: URL(fileURLWithPath: $0, isDirectory: true)) }
        activeProjectID = projects.first { $0.url.path == snapshot.activeProjectPath }?.id ?? orderedProjects.first?.id
        collapsedGroupPaths = Set(snapshot.collapsedGroupPaths ?? [])
        isGitPanelVisible = snapshot.gitPanelVisible ?? false

        let states = snapshot.projects ?? [:]
        for project in projects {
            guard let state = states[project.url.path] else { continue }
            project.customCommands = state.customCommands ?? []
            project.databases = state.databases ?? []
            project.board.restore(state.board ?? [])
            project.showsRunBar = !(state.hidesRunBar ?? false)
            project.orchestraTeam = state.orchestraTeam ?? OrchestraTeam()
            project.orchestraQueue = state.orchestraQueue
            project.lastCommand = state.lastCommand.flatMap { command in project.commands.first { $0.command == command } }
        }
        for project in projects {
            project.board.onChange = { [weak self] in self?.persist() }
        }
        if restoresTabs, states.values.contains(where: { !$0.tabs.isEmpty }) {
            isRestoringTabs = true
            Task {
                await restoreTabs(states)
                isRestoringTabs = false
            }
        } else if restoresTabs {
            projects.forEach { advanceQueue(in: $0) } // no runs to wait for
        }
    }

    /// What to save about a project's tabs. Diff tabs are left out; they are quick to reopen.
    /// `runs` and `workers` are saved for the project's cards and agents, so they go on after a restart.
    static func state(of project: Project, runs: [OrchestraRun] = [], workers: [UUID: AgentWorker] = [:]) -> ProjectState {
        var state = ProjectState()
        var indexByID: [UUID: Int] = [:]
        // The planner's and a review's agents don't come back; their step is done again.
        let stepTabs = Set(runs.flatMap(\.stepTabs))
        for tab in project.tabs where !stepTabs.contains(tab.id) {
            let saved: SavedTab?
            switch tab {
            case .editor(let document):
                saved = .editor(path: document.url.path, markdownMode: document.isMarkdown ? document.markdownMode.rawValue : nil)
            case .terminal(let session):
                guard session.isRunning else { continue }
                if let claude = session.claude, claude.state != .ended, let sessionID = claude.sessionID {
                    saved = .claude(sessionID: sessionID, directory: session.directory.path)
                } else if let agent = session.agent, agent.provider == .codex, agent.state != .ended, let sessionID = agent.sessionID {
                    saved = .codex(sessionID: sessionID, directory: session.directory.path)
                } else if let agent = session.agent, agent.state != .ended {
                    saved = nil // the agent never got going; nothing to resume
                } else {
                    saved = .terminal(
                        directory: session.currentDirectory.path,
                        title: session.projectCommand == nil ? nil : session.title,
                        command: session.projectCommand
                    )
                }
            case .search(let model):
                saved = .search(query: model.options.query)
            case .board:
                saved = .board
            case .run(let page):
                saved = .run(card: page.cardID)
            case .browser(let session):
                saved = .browser(url: session.url?.absoluteString)
            case .simulator(let session):
                saved = .simulator(udid: session.device?.udid)
            case .database(let session):
                saved = .database(id: session.config.id, sql: session.sql)
            case .diff:
                saved = nil
            }
            guard let saved else { continue }
            indexByID[tab.id] = state.tabs.count
            state.tabs.append(saved)
        }
        state.selectedTab = project.selectedTabID.flatMap { indexByID[$0] }
        state.splitTab = project.splitTabID.flatMap { indexByID[$0] }
        state.customCommands = project.customCommands.isEmpty ? nil : project.customCommands
        state.lastCommand = project.lastCommand?.command
        state.hidesRunBar = project.showsRunBar ? nil : true
        state.orchestraTeam = project.orchestraTeam
        state.orchestraQueue = project.orchestraQueue
        state.databases = project.databases.isEmpty ? nil : project.databases
        state.board = project.board.cards.isEmpty ? nil : project.board.cards

        func session(_ tab: UUID?) -> String? {
            tab.flatMap { id in project.terminals.first { $0.id == id }?.agent?.sessionID }
        }
        let projectRuns = runs.filter { run in project.board.cards.contains { $0.id == run.cardID } && run.phase != .merged }
        state.orchestraRuns = projectRuns.isEmpty ? nil : projectRuns.map { $0.saved(developerSession: session($0.developerTab)) }
        let projectWorkers = workers.compactMap { tab, worker -> SavedAgentWorker? in
            guard let lead = session(worker.lead) else { return nil } // a lead that is gone leads nobody
            return SavedAgentWorker(
                leadSession: lead, workerSession: session(tab), name: worker.name, provider: worker.provider,
                worktree: worker.worktree?.path, branch: worker.branch, base: worker.base, cardID: worker.cardID
            )
        }
        state.agentWorkers = projectWorkers.isEmpty ? nil : projectWorkers
        return state
    }

    /// Reopens the tabs that were open at quit: files, shells in their last folder, agent conversations.
    /// Project commands are not started again, only their tab comes back.
    private func restoreTabs(_ states: [String: ProjectState]) async {
        // Agents' new tabs by their session ids, for the runs and leads that name them so.
        var sessionTabs: [String: UUID] = [:]
        let needsClaude = states.values.contains { $0.tabs.contains { if case .claude = $0 { true } else { false } } }
        let claudePath = needsClaude ? await Self.findClaude() : nil
        let needsCodex = states.values.contains { $0.tabs.contains { if case .codex = $0 { true } else { false } } }
        let codexPath = needsCodex ? await Self.findCodex() : nil

        for project in projects {
            guard let state = states[project.url.path], project.tabs.isEmpty else { continue }
            var restored: [Int: UUID] = [:]
            // The orchestra's developers come back as they were started: with nobody to ask.
            let developers = Set(state.orchestraRuns?.compactMap(\.developerSession) ?? [])
            for (index, saved) in state.tabs.enumerated() {
                switch saved {
                case .editor(let path, let mode):
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    let document = EditorDocument(url: url, repository: project.git)
                    if let mode = mode.flatMap(EditorDocument.MarkdownMode.init(rawValue:)) { document.markdownMode = mode }
                    project.tabs.append(.editor(document))
                    project.noteOpened(url)
                    restored[index] = document.id
                case .terminal(let directory, let title, let command):
                    let folder = FileManager.default.fileExists(atPath: directory) ? URL(fileURLWithPath: directory, isDirectory: true) : project.url
                    let session = makeTerminal(in: project, directory: folder, title: title, select: false)
                    session.projectCommand = command
                    restored[index] = session.id
                case .claude(let sessionID, let directory):
                    guard let claudePath else { continue }
                    let folder = FileManager.default.fileExists(atPath: directory) ? URL(fileURLWithPath: directory, isDirectory: true) : project.url
                    let session = await makeClaudeSession(
                        in: project, launch: .resume(sessionID: sessionID), claudePath: claudePath, directory: folder,
                        asksQuestions: !developers.contains(sessionID)
                    )
                    project.tabs.append(.terminal(session))
                    restored[index] = session.id
                    sessionTabs[sessionID] = session.id
                case .codex(let sessionID, let directory):
                    guard let codexPath else { continue }
                    let folder = FileManager.default.fileExists(atPath: directory) ? URL(fileURLWithPath: directory, isDirectory: true) : project.url
                    let session = await makeCodexSession(in: project, launch: .resume(sessionID: sessionID), codexPath: codexPath, directory: folder)
                    project.tabs.append(.terminal(session))
                    restored[index] = session.id
                    sessionTabs[sessionID] = session.id
                case .search(let query):
                    let model = SearchModel(rootURL: project.url)
                    model.options.query = query
                    project.tabs.append(.search(model))
                    restored[index] = model.id
                case .board:
                    project.tabs.append(.board(project.board))
                    restored[index] = project.board.id
                case .run(let cardID):
                    guard project.board.cards.contains(where: { $0.id == cardID }) else { continue }
                    project.tabs.append(.run(RunPage(cardID: cardID, board: project.board)))
                    restored[index] = cardID
                case .simulator:
                    // Picks the booted device again, if any; never boots one by itself.
                    let session = SimulatorSession()
                    project.tabs.append(.simulator(session))
                    restored[index] = session.id
                case .browser(let url):
                    let session = BrowserSession()
                    if let url = url.flatMap(URL.init(string:)) { session.open(url) }
                    project.tabs.append(.browser(session))
                    restored[index] = session.id
                case .database(let id, let sql):
                    // Connects when the tab is first shown, not at launch.
                    guard let config = project.databases.first(where: { $0.id == id }) else { continue }
                    let session = DatabaseSession(config: config, projectURL: project.url, sql: sql, history: queryHistory(for: config))
                    project.tabs.append(.database(session))
                    restored[index] = session.id
                }
            }
            project.selectedTabID = state.selectedTab.flatMap { restored[$0] } ?? project.tabs.first?.id
            project.splitTabID = state.splitTab.flatMap { restored[$0] }.flatMap { $0 == project.selectedTabID ? nil : $0 }
        }

        for project in projects {
            guard let state = states[project.url.path] else { continue }
            resumeOrchestraRuns(state.orchestraRuns ?? [], in: project, tabs: sessionTabs)
            resumeAgentWorkers(state.agentWorkers ?? [], tabs: sessionTabs)
            // Its card's run goes on above; one that had ended at quit hands over to the next card.
            advanceQueue(in: project)
        }
    }
}
