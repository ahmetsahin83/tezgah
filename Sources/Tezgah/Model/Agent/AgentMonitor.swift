import Foundation

/// Connects the coding agents Tezgah starts to the app.
///
/// Each agent is launched with hooks (on top of the user's own) that run a tiny script. The
/// script drops every event as a JSON file into an events folder, tagged with the tab's id from
/// the `TEZGAH_TAB_ID` variable. Tezgah watches that folder and routes each event to its tab.
/// How the hooks get installed is up to each agent, e.g. `ClaudeMonitor`.
@MainActor
final class AgentMonitor {
    let directory: URL
    var eventsDirectory: URL { directory.appendingPathComponent("events", isDirectory: true) }
    var hookURL: URL { directory.appendingPathComponent("hook.sh") }

    /// Finds the activity for a tab id.
    var activityForTab: (UUID) -> AgentActivity? = { _ in nil }

    private var watcher: FileWatcher?

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tezgah/agents", isDirectory: true)
    }

    /// Writes the hook script and starts watching for events.
    func start() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        // Files from a previous run belong to tabs that no longer exist.
        for leftover in (try? fileManager.contentsOfDirectory(at: eventsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: leftover)
        }
        try Data(Self.hookScript.utf8).write(to: hookURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        watcher = FileWatcher(url: eventsDirectory) { [weak self] _ in
            self?.drainEvents()
        }
        watcher?.start(latency: 0.05)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func environment(forTab id: UUID) -> [String: String] {
        ["TEZGAH_TAB_ID": id.uuidString, "TEZGAH_EVENTS_DIR": eventsDirectory.path]
    }

    /// Reads and deletes queued event files, oldest first.
    func drainEvents() {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles] // ".incoming.*" files are still being written
        )) ?? []

        let ordered = files
            .filter { $0.pathExtension == "json" }
            .map { url in (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }

        for (url, _) in ordered {
            defer { try? fileManager.removeItem(at: url) }
            // File name: <tab-uuid>.<random>.json
            guard let tabID = url.lastPathComponent.split(separator: ".").first.flatMap({ UUID(uuidString: String($0)) }),
                  let data = try? Data(contentsOf: url),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            activityForTab(tabID)?.handle(event)
        }
    }

    /// Must stay silent and quick: for some events the agent shows hook output to the model,
    /// and every hook delays the agent until it returns.
    static let hookScript = """
    #!/bin/sh
    # Written by Tezgah on every launch. Forwards coding agent hook events to the app.
    if [ -z "$TEZGAH_TAB_ID" ] || [ ! -d "$TEZGAH_EVENTS_DIR" ]; then
        cat > /dev/null
        exit 0
    fi
    tmp=$(mktemp "$TEZGAH_EVENTS_DIR/.incoming.XXXXXX") || exit 0
    cat > "$tmp"
    mv "$tmp" "$TEZGAH_EVENTS_DIR/$TEZGAH_TAB_ID.${tmp##*.}.json"
    exit 0

    """

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
