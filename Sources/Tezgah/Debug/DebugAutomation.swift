#if DEBUG
import AppKit
import CoreGraphics

/// Lets a script drive a debug build for checking the UI without screen recording permission:
/// with `TEZGAH_DEBUG_DIR` set, each `*.cmd` file dropped there runs one command.
///
///     snapshot <name>      the main window → <dir>/<name>.png (an app may capture its own windows)
///     type <text>          replaces the active Claude or Codex tab's draft (\n for new lines)
///     insert <text>        types at the cursor, as the keyboard would (triggers @ and / suggestions)
///     send                 sends the draft
///     key <1-9|esc|enter>  answers a Claude dialog
///     view <conversation|terminal>
///     appearance <light|dark|system>
///     size <width> <height>
///     press <cmd+shift+g>  a keyboard shortcut or key (return, esc, up, down, tab, a letter)
///     click <x> <y>        a mouse click, in points from the window's top-left corner
///     scroll <x> <y> <dy>  scrolls what is under the point down by dy points (negative goes up)
///     keys <text>          types into whatever has focus, key by key
///     alert <1|2>          answers the open alert with its first or second button
///     tab <index>          selects a tab of the active project
///     activate             brings the window to the front (hidden windows stop drawing web and terminal views)
///     js <script>          runs in the visible conversation pages, e.g. to click a button
///     event <json>         feeds a hook event to the active Claude tab, e.g. a fake PermissionRequest
///     card start <claude|codex>   the first card in "Yapılacak" goes to an agent in its own worktree
///     card orchestra              the first card in "Yapılacak" goes to the project's orchestra team
///     card <merge|discard|show|stop>   on the first card that has a worktree
///     quit                 quits the way ⌘Q does, saving the workspace (answer its alert with `alert`)
@MainActor
final class DebugAutomation {
    private let directory: URL
    private let store: WorkspaceStore
    private var timer: Timer?

    init?(store: WorkspaceStore) {
        guard let path = ProcessInfo.processInfo.environment["TEZGAH_DEBUG_DIR"], !path.isEmpty else { return nil }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        self.store = store
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Common modes: keeps working while an alert or menu runs its own loop.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }

    private func poll() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "cmd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let line = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: file)
            run(line)
        }
    }

    private var claudeSession: TerminalSession? {
        guard case .terminal(let session) = store.activeProject?.selectedTab, session.claude != nil else { return nil }
        return session
    }

    private var codexSession: TerminalSession? {
        guard case .terminal(let session) = store.activeProject?.selectedTab, session.agent is CodexActivity else { return nil }
        return session
    }

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "snapshot":
            snapshot(name: argument.isEmpty ? "window" : argument)
        case "type":
            let text = argument.replacingOccurrences(of: "\\n", with: "\n")
            if let codex = codexSession?.agent as? CodexActivity { codex.composer.text = text } else { claudeSession?.claude?.composer.text = text }
        case "insert":
            claudeSession?.claude?.composer.typeAhead(argument)
        case "send":
            if let codex = codexSession { codex.sendCodexDraft() } else { claudeSession?.sendComposerDraft() }
        case "key":
            let key: TerminalSession.ClaudeKey = switch argument {
            case "esc": .escape
            case "enter": .enter
            default: .option(Int(argument) ?? 1)
            }
            claudeSession?.sendClaudeKey(key)
            claudeSession?.claude?.userAnswered()
        case "remote":
            guard let session = claudeSession else { return }
            Task {
                let error = argument == "off" ? await session.disableRemoteControl() : await session.enableRemoteControl()
                NSLog("Tezgah debug: remote \(argument) → \(error ?? "ok") · \(String(describing: session.claude?.remoteControl))")
            }
        case "view":
            claudeSession?.claude?.viewMode = argument == "terminal" ? .terminal : .conversation
        case "appearance":
            NSApp.appearance = switch argument {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
        case "click":
            // Points from the window's top-left corner, as in a snapshot divided by the scale.
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            if numbers.count == 2 { click(x: numbers[0], y: numbers[1]) }
        case "scroll":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            if numbers.count == 3 { scroll(x: numbers[0], y: numbers[1], by: numbers[2]) }
        case "confirmtest":
            let start = Date()
            Task {
                let answer = await WorkspaceStore.confirmWrite(["UPDATE t SET x = 1 WHERE id = 2"], connection: DatabaseConfig(name: "test", kind: .sqlite, path: "x.db"), agent: "Geliştirici · Claude")
                NSLog("Tezgah debug: confirmtest answered \(answer) after \(Date().timeIntervalSince(start))s")
            }
        case "alert":
            // Answers the alert on screen: "1" the first button, "2" the second.
            if let window = NSApp.windows.first(where: { $0.attachedSheet != nil }), let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: argument == "2" ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            } else {
                NSApp.stopModal(withCode: argument == "2" ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            }
        case "press":
            press(argument)
        case "keys":
            for character in argument { send(String(character), keyCode: 0, modifiers: []) }
        case "menu":
            // Logs a menu item's shortcut and state, then picks it.
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.title == argument { return item }
                    if let found = find(item.submenu) { return found }
                }
                return nil
            }
            guard let item = find(NSApp.mainMenu) else { NSLog("Tezgah debug: no menu item \(argument)"); break }
            NSLog("Tezgah debug: menu \(argument) key=\(item.keyEquivalent) mask=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled)")
            if let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
        case "mode", "model", "effort":
            guard let session = claudeSession else { break }
            Task {
                let result: String?
                switch command {
                case "mode": result = await session.setClaudeMode(TerminalSession.ClaudeMode(rawValue: argument) ?? .auto) ? nil : "failed"
                case "model": result = await session.setClaudeModel(argument)
                default: result = await session.setClaudeEffort(argument)
                }
                NSLog("Tezgah debug: \(command) \(argument) → \(result ?? "ok")")
            }
        case "screen":
            // The bottom of the active terminal tab, as text.
            if case .terminal(let session) = store.activeProject?.selectedTab {
                NSLog("Tezgah debug: screen\n\(session.view.bufferLines().suffix(Int(argument) ?? 30).joined(separator: "\n"))")
            }
        case "dbrun":
            // Runs SQL in the project's first open database tab, as the editor's Run would.
            store.activeProject?.databaseSessions.first?.run([DatabaseSession.Statement(sql: argument)])
        case "settings":
            UserDefaults.standard.set(argument.isEmpty ? "general" : argument, forKey: "settingsTab")
            // The app menu's "Ayarlar…" / "Settings…" item, as the user would pick it.
            if let appMenu = NSApp.mainMenu?.items.first?.submenu,
               let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") || $0.title.hasPrefix("Ayarlar") }) {
                appMenu.performActionForItem(at: index)
            }
        case "tab":
            if let project = store.activeProject, let index = Int(argument), project.tabs.indices.contains(index) {
                project.selectedTabID = project.tabs[index].id
            }
        case "overview":
            store.isAgentOverviewVisible = true
        case "quit":
            // After this timer callback: the quit alert's own loop must be able to run our commands.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "card":
            guard let project = store.activeProject else { return }
            let words = argument.split(separator: " ").map(String.init)
            if words.first == "start", let card = project.board.cards(in: .todo).first {
                store.startInWorktree(card, with: words.last == "codex" ? .codex : .claude, in: project)
            } else if words.first == "orchestra", let card = project.board.cards(in: .todo).first {
                store.startOrchestra(card, in: project)
            } else if let card = project.board.cards.first(where: { $0.worktree != nil }) {
                switch words.first {
                case "merge": store.mergeWorktree(of: card, in: project)
                case "discard": store.discardWorktree(of: card, in: project)
                case "show": store.showWorktree(of: card, in: project)
                case "stop": store.stopOrchestra(of: card, in: project)
                default: break
                }
            }
        case "appmenu":
            NSLog("Tezgah debug: appmenu \(NSApp.mainMenu?.items.first?.submenu?.items.map { "\($0.title)|\($0.keyEquivalent)" } ?? [])")
        case "windows":
            NSLog("Tezgah debug: windows \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) n=\($0.windowNumber) \($0.frame)" })")
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: \.isVisible)?.orderFrontRegardless()
        case "js":
            for webView in ClaudeConversationView.Coordinator.debugWebViews.compactMap(\.webView) where webView.window != nil {
                webView.evaluateJavaScript(argument, completionHandler: nil)
            }
        case "event":
            if let data = argument.data(using: .utf8),
               let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                claudeSession?.claude?.handle(event)
            }
        case "size":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            if numbers.count == 2, let window = NSApp.windows.first(where: \.isVisible) {
                window.setContentSize(NSSize(width: numbers[0], height: numbers[1]))
            }
        default:
            NSLog("Tezgah debug: unknown command \(line)")
        }
    }

    private func press(_ spec: String) {
        var modifiers: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.lowercased().split(separator: "+") {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "alt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: key = String(part)
            }
        }
        let special: [String: (String, UInt16)] = [
            "return": ("\r", 36), "esc": ("\u{1B}", 53), "tab": ("\t", 48),
            "up": ("\u{F700}", 126), "down": ("\u{F701}", 125),
        ]
        var (characters, code) = special[key] ?? (key, 0)
        if modifiers.contains(.shift), special[key] == nil { characters = characters.uppercased() }
        send(characters, keyCode: code, modifiers: modifiers)
    }

    private func click(x: Double, y: Double) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0.className.contains("Popover")) && $0.frame.width > 400 }) else { return }
        let location = NSPoint(x: x, y: window.frame.height - y)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Tables track the mouse in a loop of their own until the button comes up, so the
        // release has to be waiting in the queue already.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    private func scroll(x: Double, y: Double, by amount: Double) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0.className.contains("Popover")) && $0.frame.width > 400 }),
              let content = window.contentView else { return }
        var view = content.hitTest(content.convert(NSPoint(x: x, y: window.frame.height - y), from: nil))
        while let current = view, !(current is NSScrollView) { view = current.superview }
        guard let scrollView = view as? NSScrollView, let document = scrollView.documentView else {
            NSLog("Tezgah debug: nothing scrolls at \(x), \(y)")
            return
        }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? amount : -amount
        origin.y = max(0, min(origin.y, document.frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { continue }
            // Synthesized events don't go through menu key equivalents on their own.
            if type == .keyDown, !modifiers.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
            NSApp.sendEvent(event)
        }
    }

    /// The app's visible windows (the main one plus popovers and sheets) as one picture.
    private func snapshot(name: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 }
        let shots = windows.compactMap { window -> (NSRect, CGImage)? in
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return nil }
            return (window.frame, image)
        }
        guard let union = shots.map(\.0).reduce(nil, { ($0 ?? $1).union($1) }) as NSRect?,
              let scale = NSScreen.main?.backingScaleFactor else {
            NSLog("Tezgah debug: snapshot failed")
            return
        }
        let width = Int(union.width * scale), height = Int(union.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Bigger windows first, so popovers land on top.
        for (frame, image) in shots.sorted(by: { $0.0.width * $0.0.height > $1.0.width * $1.0.height }) {
            let rect = CGRect(x: (frame.minX - union.minX) * scale, y: (frame.minY - union.minY) * scale,
                              width: frame.width * scale, height: frame.height * scale)
            context.draw(image, in: rect)
        }
        guard let combined = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}
#endif
