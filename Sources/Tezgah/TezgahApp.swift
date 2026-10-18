import AppKit
import SwiftUI

@main
struct TezgahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Tezgah", id: "main") {
            ContentView()
                .environment(appDelegate.store)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands { TezgahCommands(store: appDelegate.store) }

        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var debugAutomation: DebugAutomation?
    #endif
    let store = AppDelegate.makeStore()

    /// `TEZGAH_SUPPORT_DIR` keeps a development copy's state (projects, tabs, agent events) apart
    /// from the Tezgah in daily use, so both can run side by side.
    private static func makeStore() -> WorkspaceStore {
        guard let path = ProcessInfo.processInfo.environment["TEZGAH_SUPPORT_DIR"], !path.isEmpty else { return WorkspaceStore() }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return WorkspaceStore(
            snapshotURL: folder.appendingPathComponent("workspace.json"),
            agentsDirectory: folder.appendingPathComponent("agents", isDirectory: true)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) instead of a .app bundle.
        NSApp.setActivationPolicy(.regular)
        AppSettings.shared.applyAppearance()
        AppSettings.shared.onFontChange = { [store] in store.applyFonts() }
        NSApp.activate(ignoringOtherApps: true)
        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [store] tabID in store.focusTab(tabID) }
        Notifier.shared.onAnswer = { [store] tabID, request, answer in
            store.answerPermission(tab: tabID, request: request, answer: answer)
        }
        AppSettings.shared.onTelegramAwakeChange = { [store] in store.telegram.updateAwake() }
        // A development copy leaves the bot to the Tezgah in daily use: two readers of one bot
        // take each other's messages.
        if ProcessInfo.processInfo.environment["TEZGAH_SUPPORT_DIR"] == nil {
            store.telegram.resume()
        }
        #if DEBUG
        debugAutomation = DebugAutomation(store: store)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.confirmQuitting() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Before the shells go away, so their folders can still be read.
        store.persist()
    }

    func applicationDidResignActive(_ notification: Notification) {
        store.persist()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.markVisibleAgentSessionSeen()
        guard let project = store.activeProject else { return }
        project.root.refreshExpanded()
        project.documents.forEach { $0.checkDisk() }
        Task { await project.git.refresh() }
    }
}

struct TezgahCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Proje Ekle…") { store.addProjectsViaPanel() }
                .keyboardShortcut("o")
            Button("Yeni Terminal") { store.newTerminal() }
                .keyboardShortcut("t")
                .disabled(store.activeProject == nil)
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .saveItem) {
            Button("Kaydet") { store.saveActiveTab() }
                .keyboardShortcut("s")
            Button("Tümünü Kaydet") { store.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Sekmeyi Kapat") { store.closeActiveTab() }
                .keyboardShortcut("w")
        }
        CommandMenu("Çalıştır") {
            Button(store.activeProject?.lastCommand.map { "Tekrar Çalıştır: \($0.name)" } ?? "Tekrar Çalıştır") { store.runLastCommand() }
                .keyboardShortcut("r")
                .disabled(store.activeProject?.commands.isEmpty ?? true)
            if let project = store.activeProject, !project.runBarCommands.isEmpty {
                Button(project.showsRunBar ? "Make Çubuğunu Gizle" : "Make Çubuğunu Göster") {
                    store.setRunBarVisible(!project.showsRunBar, in: project)
                }
                Divider()
                ForEach(Array(project.runBarCommands.prefix(9).enumerated()), id: \.element.id) { index, command in
                    Button(command.name) { store.runOrShow(command) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                }
            }
            Divider()
            ForEach(store.activeProject?.commands.filter { command in
                !(store.activeProject?.runBarCommands.prefix(9).contains(command) ?? false)
            } ?? []) { command in
                Button(command.name) { store.run(command) }
            }
        }
        CommandMenu("Ajanlar") {
            Group {
                Button("Yeni Claude Oturumu") { store.newClaudeSession() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Son Claude Oturumunu Sürdür") { store.newClaudeSession(.continueLast) }
                    .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                Button("Önceki Claude Oturumlarından Seç…") { store.newClaudeSession(.pick) }
                Divider()
                Button("Yeni Codex Oturumu") { store.newCodexSession() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Son Codex Oturumunu Sürdür") { store.newCodexSession(.continueLast) }
                    .keyboardShortcut("x", modifiers: [.command, .shift, .option])
                Button("Önceki Codex Oturumlarından Seç…") { store.newCodexSession(.pick) }
            }
            .disabled(store.activeProject == nil)
            Divider()
            Toggle("Claude Prompt Önerileri", isOn: Binding(
                get: { AppSettings.shared.promptSuggestions },
                set: { AppSettings.shared.promptSuggestions = $0 }
            ))
            Button("Tüm Oturumlar…") { store.isAgentOverviewVisible = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            // Always enabled: the menu is not rebuilt when tabs are restored, so a state-based
            // title or disabled flag would go stale. Does nothing outside a Claude tab.
            Button("Sohbet / Terminal Görünümü") { store.toggleClaudeView() }
                .keyboardShortcut("j")
        }
        CommandMenu("Gezin") {
            Button("Hızlı Aç…") { store.showQuickOpen() }
                .keyboardShortcut("p")
                .disabled(store.activeProject == nil)
            Button("Ara ya da Claude'a Sor…") { store.showQuickOpen() }
                .keyboardShortcut("k")
                .disabled(store.activeProject == nil)
            Button("Komut Paleti…") { store.showCommandPalette() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.activeProject == nil)
            Button("Projede Ara…") { store.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.activeProject == nil)
            Button("Pano") { store.showBoard() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Tarayıcı Önizleme") { store.showBrowser() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("iOS Simülatörü") { store.showSimulator() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Markdown Önizleme") { store.activeProject?.focusedDocument?.toggleMarkdownPreview() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button(store.activeProject?.splitTabID == nil ? "Yan Yana Böl" : "Bölmeyi Kapat") { store.toggleSplit() }
                .keyboardShortcut("\\")
                .disabled(store.activeProject?.tabs.isEmpty ?? true)
            Button(store.isGitPanelVisible ? "Git Panelini Gizle" : "Git Panelini Göster") { store.toggleGitPanel() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Sonraki Sekme") { store.cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Önceki Sekme") { store.cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(store.orderedProjects.prefix(9).enumerated()), id: \.element.id) { index, project in
                Button("\(project.parentURL.lastPathComponent) / \(project.name)") { store.select(project) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}
