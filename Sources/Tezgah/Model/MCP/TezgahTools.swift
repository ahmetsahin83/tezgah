import Foundation

/// The tools Tezgah offers its Claude sessions. Each runs for the tab that called it, so it
/// acts in that session's project.
extension WorkspaceStore {
    func registerMCPTools() {
        registerBrowserTools()
        registerSimulatorTools()
        registerBoardTools()
        registerWorkspaceTools()
        registerOrchestraTools()
        registerLeadTools()
        mcpServer.register(MCPTool(
            name: "open_in_editor",
            description: "Open a file in Tezgah's editor, optionally at a line, to show it to the user.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path, or relative to the session's folder"],
                    "line": ["type": "integer", "description": "1-based line to reveal"],
                ],
                "required": ["path"],
            ]
        ) { [weak self] arguments, tab in
            guard let self, let (session, project) = self.claudeTab(tab) else { return .error("This Claude session is not in Tezgah anymore.") }
            guard let path = arguments["path"] as? String, !path.isEmpty else { return .error("path is required") }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : session.directory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return .error("No such file: \(url.path)") }
            self.openFile(url, line: (arguments["line"] as? NSNumber)?.intValue, in: project)
            return .text("Opened \(url.lastPathComponent) in Tezgah.")
        })
    }
}
