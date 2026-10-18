import AppKit
import CodeEditSourceEditor
import SwiftTerm
import SwiftUI

/// Shows a session's terminal view. The view is reused, never recreated, so the shell
/// and its scrollback survive tab and project switches.
struct TerminalHostView: View {
    let session: TerminalSession
    let project: Project

    var body: some View {
        Group {
            if let claude = session.claude {
                ClaudeSessionView(session: session, activity: claude, project: project)
            } else if let codex = session.agent as? CodexActivity {
                CodexSessionView(session: session, activity: codex, project: project)
            } else if let agent = session.agent {
                AgentTerminalView(session: session, activity: agent, project: project)
            } else {
                TerminalRepresentable(view: session.view)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: session.view.nativeBackgroundColor))
            }
        }
        .onAppear {
            // Looking at an agent tab acknowledges its "needs attention" mark.
            if NSApp.isActive { session.agent?.markSeen() }
        }
    }
}

struct TerminalRepresentable: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        focusWhenAttached(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

struct EditorHostView: View {
    @Environment(WorkspaceStore.self) private var store
    let document: EditorDocument
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let error = document.loadError {
            ContentUnavailableView(document.title, systemImage: "doc.questionmark", description: Text(error))
        } else if document.isImage && document.showsImage {
            ImageViewer(document: document)
        } else {
            VStack(spacing: 0) {
                if document.isMarkdown {
                    MarkdownModeBar(document: document)
                } else if document.isImage {
                    HStack {
                        Spacer()
                        Button("Görseli Göster") { document.showsImage = true }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
                switch document.diskState {
                case .inSync:
                    EmptyView()
                case .changedOnDisk:
                    DiskBanner(message: "Bu dosya başka bir programda değişti, sende de kaydedilmemiş değişiklikler var.") {
                        Button("Diskteki Sürümü Yükle") { document.reloadFromDisk() }
                        Button("Benimkini Koru") { document.keepLocalVersion() }
                    }
                case .deletedOnDisk:
                    DiskBanner(message: "Bu dosya diskten silindi. Kaydedersen yeniden oluşturulur.") {
                        Button("Sekmeyi Kapat") { store.closeActiveTab() }
                    }
                }
                let theme = EditorThemes.theme(for: colorScheme)
                switch document.isMarkdown ? document.markdownMode : .source {
                case .source:
                    SourceEditorRepresentable(document: document, controller: document.controller(theme: theme), theme: theme)
                case .split:
                    HSplitView {
                        SourceEditorRepresentable(document: document, controller: document.controller(theme: theme), theme: theme)
                            .frame(minWidth: 200, maxWidth: .infinity)
                        preview
                            .frame(minWidth: 200, maxWidth: .infinity)
                    }
                case .preview:
                    preview
                }
            }
            .onChange(of: document.repository?.refreshCount) {
                // Staging, committing or checking out changes what the change marks compare against.
                document.reloadGitBase()
            }
        }
    }

    private var preview: some View {
        let root = store.activeProject?.url ?? document.url.deletingLastPathComponent()
        return MarkdownPreview(document: document, version: document.textVersion, root: root) { url in
            store.openFile(url)
        }
    }
}

/// Source / split / preview switch above Markdown files.
private struct MarkdownModeBar: View {
    @Bindable var document: EditorDocument

    var body: some View {
        HStack {
            Spacer()
            Picker("Görünüm", selection: $document.markdownMode) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").help("Kaynak").tag(EditorDocument.MarkdownMode.source)
                Image(systemName: "rectangle.split.2x1").help("Yan yana").tag(EditorDocument.MarkdownMode.split)
                Image(systemName: "eye").help("Önizleme").tag(EditorDocument.MarkdownMode.preview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Markdown görünümü (⇧⌘V)")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct DiskBanner<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
            actions
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct SourceEditorRepresentable: NSViewControllerRepresentable {
    let document: EditorDocument
    let controller: TextViewController
    let theme: EditorTheme

    func makeNSViewController(context: Context) -> TextViewController {
        DispatchQueue.main.async { [document, controller] in
            controller.view.window?.makeFirstResponder(controller.textView)
            document.applyPendingLine()
        }
        return controller
    }

    func updateNSViewController(_ controller: TextViewController, context: Context) {
        // Follows light/dark mode changes.
        if controller.configuration.appearance.theme != theme {
            controller.configuration.appearance.theme = theme
        }
    }
}

/// Makes `view` first responder once SwiftUI has put it in a window.
@MainActor
private func focusWhenAttached(_ view: NSView) {
    DispatchQueue.main.async {
        view.window?.makeFirstResponder(view)
    }
}
