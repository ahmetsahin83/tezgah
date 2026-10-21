import Foundation

/// Folders trusted ahead for the agents Tezgah opens in them, so neither stops at its "Trust this
/// folder?" screen with nobody at the Mac. Claude Code's defaults to "No, exit".
enum AgentTrust {
    /// The folder, the repository it is in and, for a worktree, the main checkout: Claude Code and
    /// Codex each key trust by one of these.
    static func folders(for directory: URL) -> [String] {
        var folders: [String] = []
        func add(_ path: String) {
            let path = (path as NSString).standardizingPath
            if !folders.contains(path) { folders.append(path) }
        }
        add(directory.path)
        add(directory.resolvingSymlinksInPath().path)

        var folder = directory.standardizedFileURL
        while folder.path != "/" {
            let git = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                add(folder.path)
                // A worktree's .git is a file: "gitdir: /main/.git/worktrees/<name>".
                if !isDirectory.boolValue, let text = try? String(contentsOf: git, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let gitDirectory = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if let range = gitDirectory.range(of: "/.git/worktrees/") {
                        add(String(gitDirectory[..<range.lowerBound]))
                    }
                }
                break
            }
            folder.deleteLastPathComponent()
        }
        return folders
    }

    /// Claude Code's global config: `.claude.json` in CLAUDE_CONFIG_DIR, or in the home folder.
    static func claudeConfigURL(environment: [String: String]) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// Sets `projects[folder].hasTrustDialogAccepted` for the folders, the way accepting the dialog
    /// does. The file is only written when something changes; one Claude Code never created is
    /// left alone (its first run has an onboarding of its own).
    static func trustForClaude(_ directory: URL, configURL: URL) {
        guard let data = try? Data(contentsOf: configURL),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var projects = config["projects"] as? [String: Any] ?? [:]
        var changed = false
        for folder in folders(for: directory) {
            var project = projects[folder] as? [String: Any] ?? [:]
            guard project["hasTrustDialogAccepted"] as? Bool != true else { continue }
            project["hasTrustDialogAccepted"] = true
            projects[folder] = project
            changed = true
        }
        guard changed else { return }
        config["projects"] = projects
        guard let updated = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        do {
            try updated.write(to: configURL, options: .atomic)
        } catch {
            NSLog("Tezgah: could not trust \(directory.path) for Claude Code: \(error)")
        }
    }

    /// Codex's `-c` setting that trusts the folders for this session only; its config.toml is not touched.
    @MainActor static func codexOverride(for folders: [String]) -> String? {
        guard !folders.isEmpty else { return nil }
        // A dotted key can't be spelled out in `-c`, so the folders go in as one inline table.
        let entries = folders.map { "\(CodexMonitor.tomlString($0))={trust_level=\"trusted\"}" }
        return "projects={\(entries.joined(separator: ","))}"
    }
}
