import SwiftUI

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 440)
        } detail: {
            if let project = store.activeProject {
                ProjectWorkspaceView(project: project)
                    .navigationTitle(project.name)
                    .modifier(HidesWindowTitle())
                    .inspector(isPresented: gitPanelVisible) {
                        GitPanelView(project: project)
                            .id(project.id)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
                    }
            } else {
                WelcomeView()
                    .navigationTitle("Tezgah")
            }
        }
        .overlay(alignment: .top) {
            if store.isQuickOpenVisible, let project = store.activeProject {
                ZStack(alignment: .top) {
                    // Clicking outside the panel closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { store.hideQuickOpen() }
                    QuickOpenView(project: project, query: store.quickOpenInitialQuery)
                        .id(project.id)
                        .padding(.top, 48)
                }
            }
        }
    }

    private var gitPanelVisible: Binding<Bool> {
        Binding(
            get: { store.isGitPanelVisible },
            set: { store.isGitPanelVisible = $0 }
        )
    }
}

struct ProjectWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            if !project.tabs.isEmpty {
                TabBarView(project: project)
                ThemeDivider()
            }
            if let splitTab = project.splitTab {
                HSplitView {
                    TabContentView(tab: project.selectedTab, project: project)
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.showsTabBar, false)
                    VStack(spacing: 0) {
                        SplitPaneHeader(tab: splitTab, project: project)
                        Divider()
                        TabContentView(tab: splitTab, project: project)
                    }
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                TabContentView(tab: project.selectedTab, project: project)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.showsTabBar, false)
            }
            WindowStatusBar(project: project)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // One item: a search field standing alone in the toolbar is dropped by macOS 26.
                HStack(spacing: 12) {
                    if #available(macOS 15, *) {
                        ProjectTitle(project: project)
                    } else {
                        ProjectTitle(project: project, showsName: false)
                    }
                    ToolbarSearchButton()
                }
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem {
                AgentSessionsButton()
            }
            ToolbarItemGroup {
                Button { store.toggleSplit() } label: {
                    Label(project.splitTabID == nil ? "Yan Yana Böl" : "Bölmeyi Kapat",
                          systemImage: project.splitTabID == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
                }
                .help(project.splitTabID == nil ? "Yan yana böl (⌘\\)" : "Bölmeyi kapat (⌘\\)")
                .disabled(project.tabs.isEmpty)
                Button { store.toggleGitPanel() } label: {
                    Label(store.isGitPanelVisible ? "Git Panelini Gizle" : "Git Panelini Göster",
                          systemImage: "sidebar.right")
                }
                .help(gitHelp)
                ToolbarAddMenu(project: project)
            }
        }
    }

    private var gitHelp: String {
        let action = store.isGitPanelVisible ? "Git panelini gizle (⇧⌘G)" : "Git panelini göster (⇧⌘G)"
        let count = project.git.status.allChanges.count
        return count > 0 ? "\(action) · \(count) değişiklik" : action
    }
}

/// The project name and branch sit in the toolbar instead (macOS 15 and later).
private struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// The content of one tab, in the main pane or the side pane.
struct TabContentView: View {
    @Environment(WorkspaceStore.self) private var store
    let tab: WorkspaceTab?
    let project: Project

    var body: some View {
        Group {
            switch tab {
            case .terminal(let session):
                TerminalHostView(session: session, project: project)
                    .id(session.id)
            case .editor(let document):
                EditorHostView(document: document)
                    .id(document.id)
            case .diff(let document):
                DiffTabView(document: document)
                    .id(document.id)
            case .search(let model):
                SearchTabView(model: model)
                    .id(model.id)
            case .database(let session):
                DatabaseTabView(session: session, project: project)
                    .id(session.id)
            case .board(let board):
                BoardTabView(board: board, project: project)
                    .id(board.id)
            case .browser(let session):
                BrowserTabView(session: session)
                    .id(session.id)
            case .simulator(let session):
                SimulatorTabView(session: session, project: project)
                    .id(session.id)
            case .run(let page):
                OrchestraRunView(page: page, project: project)
                    .id(page.cardID)
            case nil:
                ProjectStartView(project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Title bar of the side pane, with a button to close the split.
private struct SplitPaneHeader: View {
    let tab: WorkspaceTab
    let project: Project

    var body: some View {
        HStack(spacing: 6) {
            TabIcon(tab: tab)
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Button {
                project.selectedTabID = tab.id
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Panelleri yer değiştir")
            .accessibilityLabel("Panelleri yer değiştir")
            Button {
                project.splitTabID = nil
            } label: {
                Image(systemName: "xmark")
            }
            .help("Bölmeyi kapat (sekme açık kalır)")
            .accessibilityLabel("Bölmeyi kapat (sekme açık kalır)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }
}
