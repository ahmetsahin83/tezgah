import AppKit
import Observation
import SwiftTerm

/// One shell running in a pseudo-terminal. The view is owned here, not by SwiftUI,
/// so the shell keeps running while its tab or project is not on screen.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    var title: String
    private(set) var isRunning = true
    /// Set for tabs running a coding agent.
    let agent: AgentActivity?
    /// The agent, when it is Claude Code.
    var claude: ClaudeActivity? { agent as? ClaudeActivity }
    /// The folder the shell started in.
    let directory: URL
    /// The project command this tab was opened for (e.g. "make run"), so running it again reuses the tab.
    var projectCommand: String?
    /// Opened to run commands from a Claude conversation; reused for the next one.
    var runsClaudeCommands = false

    @ObservationIgnored let view: InputObservingTerminalView
    @ObservationIgnored var onExit: (() -> Void)?
    /// Watches for Remote Control to connect; see `watchRemoteControl()`.
    @ObservationIgnored var remoteControlWatch: Task<Void, Never>?
    @ObservationIgnored private let defaultTitle: String

    /// Starts the user's login shell, or, with `command`, runs it through an interactive login
    /// shell so the user's PATH and aliases apply.
    init(
        id: UUID = UUID(),
        directory: URL,
        title: String,
        command: String? = nil,
        environment extraEnvironment: [String: String] = [:],
        agent: AgentActivity? = nil
    ) {
        self.id = id
        self.title = title
        self.defaultTitle = title
        self.agent = agent
        self.directory = directory

        var options = TerminalOptions.default
        options.scrollback = 10_000
        view = InputObservingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: AppSettings.shared.terminalFont,
            options: options
        )
        // Option must type characters, not act as Meta: Turkish and other layouts
        // need it for @ [ ] { } | \ ~ and friends.
        view.optionAsMetaKey = false
        view.processDelegate = self
        if let agent {
            if agent is ClaudeActivity {
                agent.onReady = { [weak self] in self?.sendDraftWaitingForClaude() }
            } else if let codex = agent as? CodexActivity {
                // A prompt sent while Codex started goes out once its UI is up.
                agent.onReady = { [weak self, weak codex] in
                    if codex?.composer.isWaitingForAgent == true { self?.sendCodexDraft() }
                }
            }
            view.onUserInput = { [weak agent] data in
                // Enter or a single key (1/2/y/n) answers a permission dialog; escape
                // sequences are arrow keys or the terminal's own replies to queries.
                if data.contains(13) || (data.count == 1 && data.first != 27) {
                    agent?.userAnswered()
                }
            }
        }

        let shell = Self.userShell
        let shellName = (shell as NSString).lastPathComponent
        let environment = Self.environment(shell: shell)
            + extraEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        if let command {
            view.startProcess(executable: shell, args: ["-l", "-i", "-c", command], environment: environment,
                              execName: shellName, currentDirectory: directory.path)
        } else {
            view.startProcess(executable: shell, args: [], environment: environment,
                              execName: "-" + shellName, // login shell, like Terminal.app
                              currentDirectory: directory.path)
        }
    }

    /// Sessions being stopped, kept until their shell is gone: their terminal must still be read
    /// meanwhile, or a program writing to it can't exit.
    private static var stopping: [UUID: TerminalSession] = [:]

    /// Stops what runs in the tab, the way closing a Terminal window does: a hangup for the
    /// foreground job (Claude, a dev server) and the shell, which as an interactive shell ignores
    /// SwiftTerm's SIGTERM. Whatever still runs a few seconds later is killed.
    func terminate() {
        guard isRunning else { return }
        isRunning = false
        Self.stopping[id] = self
        var groups: [(id: pid_t, name: String)] = []
        if let process = view.process, process.shellPid > 0 {
            let shell = process.shellPid
            if let job = ProcessInspector.foregroundGroup(ofTerminal: process.childfd), job != shell,
               let name = ProcessInspector.name(of: job) {
                groups.append((job, name))
            }
            // The shell leads its own process group.
            if let name = ProcessInspector.name(of: shell) { groups.append((shell, name)) }
        }
        for group in groups { killpg(group.id, SIGHUP) }
        view.terminate()
        Task { @MainActor [id] in
            try? await Task.sleep(for: .seconds(3))
            // Only if the group is still the same program, not a new one that got its id.
            for group in groups where ProcessInspector.name(of: group.id) == group.name {
                killpg(group.id, SIGKILL)
            }
            try? await Task.sleep(for: .seconds(5))
            Self.stopping[id] = nil
        }
    }

    /// Name of the program running in the foreground (e.g. "npm", "vim", "claude"), or nil at the shell prompt.
    var foregroundProcessName: String? {
        guard isRunning, let process = view.process else { return nil }
        let shell = process.shellPid
        guard shell > 0, let group = ProcessInspector.foregroundGroup(ofTerminal: process.childfd), group != shell else {
            return nil
        }
        return ProcessInspector.name(of: group) ?? "?"
    }

    /// Where the shell is now, which may differ from where it started.
    var currentDirectory: URL {
        guard isRunning, let pid = view.process?.shellPid, pid > 0,
              let path = ProcessInspector.currentDirectory(of: pid) else { return directory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Types a command at the prompt and presses return, as if the user did.
    func run(_ command: String) {
        view.send(txt: command + "\r")
    }

    /// Like `run`, but as one paste, so a multi-line command (a heredoc, a `\`-continued line)
    /// reaches the shell whole instead of line by line.
    func runPasted(_ command: String) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.contains("\n") else {
            run(text)
            return
        }
        view.send(txt: "\u{1B}[200~" + text.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~\r")
    }

    /// Ctrl-C, stopping whatever runs in the foreground.
    func interrupt() {
        view.send([3])
    }

    static var userShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    private static func environment(shell: String) -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("SHELL=\(shell)")
        env.append("TERM_PROGRAM=Tezgah")
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            env.append("PATH=\(path)")
        }
        return env
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? defaultTitle : trimmed
        // Codex's first title says its UI is up. The shell around it sets titles too (before it
        // starts, after it exits), but then no program is in the foreground.
        if let agent, agent.isWaitingForUI, foregroundProcessName != nil {
            agent.uiAppeared()
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        Self.stopping[id] = nil
        agent?.processExited()
        onExit?()
    }
}

/// Reports what the user sends to the process (keys, pastes), so agent tabs notice answers.
final class InputObservingTerminalView: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    /// The terminal's text, scrollback included, as lines; trailing blank lines dropped.
    func bufferLines() -> [String] {
        var lines = String(decoding: getBufferAsData(), as: UTF8.self)
            .components(separatedBy: "\n")
            .map { line in line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }
}
