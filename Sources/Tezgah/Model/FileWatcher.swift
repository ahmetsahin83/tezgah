import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports which folders changed.
/// Events are folder-level: a file edit reports the folder that contains it.
final class FileWatcher {
    struct Change {
        /// Changed folders, relative to the watched root ("" is the root itself).
        let folders: Set<String>
        /// FSEvents lost track (dropped events, root moved): everything should be re-read.
        let needsFullRescan: Bool
    }

    /// The watched folder with symlinks resolved, which is how FSEvents reports paths.
    let rootPath: String
    private let onChange: @MainActor (Change) -> Void
    private let queue = DispatchQueue(label: "dev.tezgah.file-watcher")
    private var stream: FSEventStreamRef?

    init(url: URL, onChange: @escaping @MainActor (Change) -> Void) {
        rootPath = Self.realPath(url.path)
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start(latency: TimeInterval = 0.25) {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            )
            let needsFullRescan = (0..<count).contains { eventFlags[$0] & rescanFlags != 0 }
            watcher.deliver(paths: paths, needsFullRescan: needsFullRescan)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync {} // let a callback that is already running finish before `self` can go away
    }

    private func deliver(paths: [String], needsFullRescan: Bool) {
        let prefix = rootPath + "/"
        var folders = Set<String>()
        for path in paths {
            let path = path.hasSuffix("/") ? String(path.dropLast()) : path
            if path == rootPath {
                folders.insert("")
            } else if path.hasPrefix(prefix) {
                folders.insert(String(path.dropFirst(prefix.count)))
            }
        }
        let change = Change(folders: folders, needsFullRescan: needsFullRescan)
        let onChange = onChange
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onChange(change) }
        }
    }

    /// Like `realpath(3)`: /var/… becomes /private/var/…, which `resolvingSymlinksInPath` would undo.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
