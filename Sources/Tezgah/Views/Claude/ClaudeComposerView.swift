import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where the composer sends things and what it can offer.
struct ClaudeComposerActions {
    var send: () -> Void
    var interrupt: () -> Void
    /// Esc with an empty draft while a dialog waits: answers "no".
    var reject: () -> Void
}

/// The native prompt box of a Claude tab: multi-line text, @ files, / commands, pasted images.
struct ClaudeComposerView: View {
    @Bindable var state: ClaudeComposerState
    let project: Project
    let commands: [ClaudeSlashCommand]
    let isWorking: Bool
    let isWaiting: Bool
    let isEnded: Bool
    /// Tab on an empty composer takes the first of these.
    var suggestion: String?
    /// Mode, model and effort menus, in the bottom bar.
    var sessionControls: AnyView?
    /// Whose composer it is, for its texts.
    var provider = AgentProvider.claude
    let actions: ClaudeComposerActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var editorHeight: CGFloat = 20
    @State private var token: ComposerToken?
    @State private var suggestions: [Suggestion] = []
    @State private var selection = 0
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.attachments) { attachment in
                            AttachmentChip(attachment: attachment) { state.removeAttachment(attachment) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }

            ComposerTextEditor(
                state: state,
                placeholder: placeholder,
                height: $editorHeight,
                isEnabled: !isEnded,
                onKey: handleKey,
                onToken: updateToken,
                onFiles: addFiles,
                onImage: { state.attachImage($0) }
            )
            .frame(height: editorHeight)
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 4)

            HStack(spacing: 2) {
                ComposerIconButton(symbol: "paperclip", help: "Dosya ya da görsel ekle") { chooseFiles() }
                ComposerIconButton(symbol: "at", help: "Dosya an (@)") { insertTrigger("@") }
                ComposerIconButton(symbol: "slash.circle", help: "Komutlar (/)") { insertTrigger("/") }
                if let sessionControls {
                    Divider().frame(height: 14).padding(.horizontal, 4)
                    sessionControls
                }
                Spacer(minLength: 8)
                if state.isWaitingForAgent {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("\(provider.displayName) hazır olunca gönderilecek")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else if isWaiting {
                    Text("Önce yukarıdaki soruyu yanıtla")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else if isWorking, state.canSend {
                    Text("Sıraya alınır")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                sendButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.17) : Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.07), radius: 10, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.11),
                              lineWidth: isDropTargeted ? 2 : 1)
        }
        .overlay(alignment: .bottomLeading) {
            if !suggestions.isEmpty {
                SuggestionList(suggestions: suggestions, selection: selection) { accept($0) }
                    .alignmentGuide(.bottom) { $0[.bottom] + 8 + 0 }
                    .offset(y: -(editorHeight + 56 + (state.attachments.isEmpty ? 0 : 52)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .opacity(isEnded ? 0.55 : 1)
        .animation(.easeOut(duration: 0.12), value: suggestions.isEmpty)
    }

    private var placeholder: String {
        if isEnded { return "Oturum kapandı" }
        if isWorking { return "\(provider.displayName) çalışırken yaz, sıraya alınır…" }
        return "\(provider.toName) bir şey sor ya da bir görev ver…"
    }

    @ViewBuilder
    private var sendButton: some View {
        if isWorking && !state.canSend {
            Button(action: actions.interrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .help("Durdur (Esc)")
            .accessibilityLabel("\(provider.objectName) durdur")
        } else {
            Button(action: actions.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(canSend ? Color.claudeAccent : Color.secondary.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Gönder (↩)")
            .accessibilityLabel("Gönder")
        }
    }

    private var canSend: Bool {
        state.canSend && !isEnded && !isWaiting
    }

    // MARK: Keys

    private func handleKey(_ key: ComposerKey) -> Bool {
        if !suggestions.isEmpty {
            switch key {
            case .up:
                selection = (selection - 1 + suggestions.count) % suggestions.count
                return true
            case .down:
                selection = (selection + 1) % suggestions.count
                return true
            case .enter, .tab:
                accept(suggestions[min(selection, suggestions.count - 1)])
                return true
            case .escape:
                suggestions = []
                return true
            }
        }
        switch key {
        case .enter:
            if canSend { actions.send() }
            return true
        case .up:
            return state.previousFromHistory()
        case .down:
            return state.nextFromHistory()
        case .escape:
            if isWaiting, !state.canSend {
                actions.reject()
                return true
            }
            if isWorking, !state.canSend {
                actions.interrupt()
                return true
            }
            return false
        case .tab:
            guard let suggestion, !state.canSend else { return false }
            state.text = suggestion
            state.pendingCursor = (suggestion as NSString).length
            return true
        }
    }

    // MARK: Suggestions

    private func updateToken(_ token: ComposerToken?) {
        let isNewFileMention = token?.kind == .file && self.token?.kind != .file
        self.token = token
        guard let token else {
            suggestions = []
            return
        }
        if isNewFileMention {
            // Files Claude just created should be mentionable too.
            Task {
                await project.fileIndex.refresh()
                if let current = self.token, current.kind == .file { updateToken(current) }
            }
        }
        switch token.kind {
        case .file:
            let entries = project.fileIndex.entries
            let results = token.query.isEmpty
                ? project.recentFiles.filter { !$0.hasPrefix("/") }.prefix(8).map { Suggestion.file($0) }
                : FuzzyMatcher.search(token.query, in: entries, limit: 8).map { Suggestion.file($0.entry.path) }
            suggestions = Array(results)
        case .command:
            let query = token.query.lowercased()
            let all = ClaudeSlashCommand.builtIn + commands.filter { custom in !ClaudeSlashCommand.builtIn.contains { $0.name == custom.name } }
            let matches = query.isEmpty
                ? all
                : all.filter { $0.name.lowercased().hasPrefix(query) } + all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
            suggestions = matches.prefix(8).map { .command($0) }
        }
        selection = 0
    }

    private func accept(_ suggestion: Suggestion) {
        guard let token else { return }
        let replacement: String
        switch suggestion {
        case .file(let path): replacement = "@" + path + " "
        case .command(let command): replacement = "/" + command.name + " "
        }
        let text = state.text as NSString
        guard NSMaxRange(token.range) <= text.length else { return }
        state.text = text.replacingCharacters(in: token.range, with: replacement)
        state.pendingCursor = token.range.location + (replacement as NSString).length
        suggestions = []
        self.token = nil
        state.focus()
    }

    private func insertTrigger(_ trigger: String) {
        if trigger == "/" {
            state.text = "/" + state.text.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" }
            state.pendingCursor = 1
        } else {
            let needsSpace = !(state.text.isEmpty || state.text.hasSuffix(" ") || state.text.hasSuffix("\n"))
            state.text += (needsSpace ? " " : "") + trigger
            state.pendingCursor = (state.text as NSString).length
        }
        state.focus()
    }

    // MARK: Files

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            let relative = project.relativePath(of: url)
            if isImage || relative == url.path {
                // Images go as attachments; files outside the project by path.
                state.addAttachment(url)
            } else {
                let needsSpace = !(state.text.isEmpty || state.text.hasSuffix(" ") || state.text.hasSuffix("\n"))
                state.text += (needsSpace ? " " : "") + "@" + relative + " "
                state.pendingCursor = (state.text as NSString).length
            }
        }
        state.focus()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = project.url
        panel.prompt = "Ekle"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFiles([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in state.attachImage(image) }
                }
            }
        }
        return handled
    }
}

extension Color {
    /// Claude's terracotta, used sparingly for Claude's own controls.
    static let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)
}

enum Suggestion: Identifiable, Equatable {
    case file(String)
    case command(ClaudeSlashCommand)

    var id: String {
        switch self {
        case .file(let path): "f:" + path
        case .command(let command): "c:" + command.name
        }
    }
}

private struct SuggestionList: View {
    let suggestions: [Suggestion]
    let selection: Int
    let choose: (Suggestion) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { choose(suggestion) } label: {
                    row(suggestion)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(index == selection ? Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.14) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(width: 440)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
    }

    @ViewBuilder
    private func row(_ suggestion: Suggestion) -> some View {
        switch suggestion {
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            HStack(spacing: 8) {
                FileTypeIcon(url)
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                let folder = (path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        case .command(let command):
            HStack(spacing: 8) {
                Text("/" + command.name)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                Text(command.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if command.isInteractive {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Claude Code'un menüsü terminalde açılır")
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ClaudeComposerState.Attachment
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    FileTypeIcon(attachment.url)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(attachment.isTemporary ? "Yapıştırılan görsel" : attachment.url.lastPathComponent)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .onHover { isHovering = $0 }
        .help(attachment.url.path)
        .accessibilityLabel(attachment.url.path)
        .task(id: attachment.url) {
            guard attachment.isImage else { return }
            let url = attachment.url
            thumbnail = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

private struct ComposerIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Text view

enum ComposerKey {
    case enter, up, down, tab, escape
}

/// The `@query` or `/query` the cursor is in.
struct ComposerToken: Equatable {
    enum Kind { case file, command }
    let kind: Kind
    let query: String
    /// The whole token including the trigger character, in UTF-16.
    let range: NSRange

    static func find(in text: String, cursor: Int) -> ComposerToken? {
        let string = text as NSString
        guard cursor <= string.length else { return nil }
        var start = cursor
        while start > 0 {
            let character = string.character(at: start - 1)
            if character == 0x20 || character == 0x0A || character == 0x09 { break }
            start -= 1
        }
        guard start < cursor || (start < string.length && cursor == start) else { return nil }
        guard start < string.length else { return nil }
        let first = string.character(at: start)
        let range = NSRange(location: start, length: cursor - start)
        guard range.length >= 1 else { return nil }
        let query = string.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
        if first == 0x40 /* @ */ {
            return ComposerToken(kind: .file, query: query, range: range)
        }
        if first == 0x2F /* / */, start == 0, !query.contains("/") {
            return ComposerToken(kind: .command, query: query, range: range)
        }
        return nil
    }
}

private struct ComposerTextEditor: NSViewRepresentable {
    @Bindable var state: ClaudeComposerState
    let placeholder: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    let onKey: (ComposerKey) -> Bool
    let onToken: (ComposerToken?) -> Void
    let onFiles: ([URL]) -> Void
    let onImage: (NSImage) -> Void

    static let font = NSFont.systemFont(ofSize: 13.5)
    static let maxHeight: CGFloat = 220

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.string = state.text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight()
            textView.window?.makeFirstResponder(textView)
        }
        context.coordinator.lastFocusRequest = state.focusRequest
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        if textView.string != state.text {
            textView.string = state.text
            let cursor = state.pendingCursor ?? (state.text as NSString).length
            textView.setSelectedRange(NSRange(location: min(cursor, (state.text as NSString).length), length: 0))
            state.pendingCursor = nil
            coordinator.recalculateHeight()
            textView.needsDisplay = true
        } else if let cursor = state.pendingCursor {
            textView.setSelectedRange(NSRange(location: min(cursor, (state.text as NSString).length), length: 0))
            state.pendingCursor = nil
        }
        if let insertion = state.pendingInsertion {
            DispatchQueue.main.async {
                state.pendingInsertion = nil
                textView.window?.makeFirstResponder(textView)
                textView.insertText(insertion, replacementRange: textView.selectedRange())
            }
        }
        if coordinator.lastFocusRequest != state.focusRequest {
            coordinator.lastFocusRequest = state.focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor?
        weak var textView: ComposerNSTextView?
        var lastFocusRequest = 0

        func textDidChange(_ notification: Notification) {
            guard let textView, let parent else { return }
            if parent.state.text != textView.string {
                parent.state.text = textView.string
            }
            recalculateHeight()
            reportToken()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportToken()
        }

        private func reportToken() {
            guard let textView, let parent else { return }
            let selection = textView.selectedRange()
            let token = selection.length == 0 ? ComposerToken.find(in: textView.string, cursor: selection.location) : nil
            parent.onToken(token)
        }

        func recalculateHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let line = ceil(ComposerTextEditor.font.ascender - ComposerTextEditor.font.descender + ComposerTextEditor.font.leading) + 2.5
            let height = min(max(ceil(used), line), ComposerTextEditor.maxHeight)
            if abs((parent?.height ?? 0) - height) > 0.5 {
                parent?.height = height
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let parent else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                return parent.onKey(.enter)
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                // History only from the first line, so multi-line drafts stay editable.
                if isOnFirstLine(textView) || parent.state.isBrowsingHistory {
                    return parent.onKey(.up)
                }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if isOnLastLine(textView) {
                    return parent.onKey(.down)
                }
                return false
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            default:
                return false
            }
        }

        private func isOnFirstLine(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let cursor = textView.selectedRange().location
            return text.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: 0, length: min(cursor, text.length))).location == NSNotFound
        }

        private func isOnLastLine(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let cursor = min(textView.selectedRange().location, text.length)
            return text.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: cursor, length: text.length - cursor)).location == NSNotFound
        }

        func paste(from pasteboard: NSPasteboard) -> Bool {
            guard let parent else { return false }
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                parent.onFiles(urls)
                return true
            }
            // Plain text wins over an image that comes with it (e.g. copied from a web page).
            if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
                parent.onImage(image)
                return true
            }
            return false
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        NSString(string: placeholder).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }

    override func paste(_ sender: Any?) {
        if let coordinator = delegate as? ComposerTextEditorCoordinatorProxy, coordinator.paste(from: .general) { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let coordinator = delegate as? ComposerTextEditorCoordinatorProxy, coordinator.paste(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}

/// Lets the text view reach its coordinator's paste handling without knowing the generic parent.
@MainActor
protocol ComposerTextEditorCoordinatorProxy: AnyObject {
    func paste(from pasteboard: NSPasteboard) -> Bool
}

extension ComposerTextEditor.Coordinator: ComposerTextEditorCoordinatorProxy {}
