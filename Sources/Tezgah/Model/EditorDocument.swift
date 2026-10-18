import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import Observation

/// A text file open in a tab. The editor controller lives here, not in SwiftUI, so undo history,
/// selection and scroll position survive tab switches.
@MainActor
@Observable
final class EditorDocument: Identifiable {
    enum DiskState {
        case inSync
        /// Changed by another program while this tab has unsaved edits.
        case changedOnDisk
        case deletedOnDisk
    }

    /// How a Markdown file is shown.
    enum MarkdownMode: String, CaseIterable {
        case source, split, preview
    }

    static let maxFileSize = 5 * 1024 * 1024
    static let maxImageSize = 100 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "ico", "icns", "svg"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    let id = UUID()
    let url: URL
    /// For the change marks next to the line numbers.
    @ObservationIgnored weak var repository: GitRepository?
    private(set) var isDirty = false
    private(set) var loadError: String?
    private(set) var diskState = DiskState.inSync
    /// Bumped on every edit, for views that follow the text (the Markdown preview).
    private(set) var textVersion = 0
    var markdownMode = MarkdownMode.source
    /// Pictures open in an image viewer; SVGs can switch to their source.
    let isImage: Bool
    var showsImage = true
    private(set) var image: NSImage?
    @ObservationIgnored private let gutter = GutterMarksCoordinator()
    @ObservationIgnored private var baseText: String?
    @ObservationIgnored private var lineDiffTask: Task<Void, Never>?

    @ObservationIgnored private(set) var language: CodeLanguage = .default
    @ObservationIgnored private(set) var indentOption: IndentOption = .spaces(count: 4)
    @ObservationIgnored private var initialText = ""
    @ObservationIgnored private var _controller: TextViewController?
    @ObservationIgnored private let changeTracker = ChangeTracker()
    @ObservationIgnored private var pendingLine: (line: Int, column: (column: Int, length: Int)?)?
    /// Modification date and content hash of the version on disk that this tab is based on.
    @ObservationIgnored private var knownModificationDate: Date?
    @ObservationIgnored private var knownContentHash: Int?

    var title: String { url.lastPathComponent }
    var isMarkdown: Bool { Self.markdownExtensions.contains(url.pathExtension.lowercased()) }
    /// Raster images have no text to edit; SVGs do.
    var isRasterImage: Bool { isImage && url.pathExtension.lowercased() != "svg" }

    init(url: URL, repository: GitRepository? = nil) {
        self.url = url
        self.repository = repository
        isImage = Self.imageExtensions.contains(url.pathExtension.lowercased())
        load()
    }

    func toggleMarkdownPreview() {
        markdownMode = markdownMode == .source ? .split : .source
    }

    /// The editor, created the first time the tab is shown.
    func controller(theme: EditorTheme) -> TextViewController {
        if let _controller { return _controller }
        changeTracker.onChange = { [weak self] in
            guard let self else { return }
            if !isDirty { isDirty = true }
            textVersion += 1
        }
        gutter.onTextChange = { [weak self] in self?.scheduleLineDiff() }
        gutter.onAppear = { [weak self] in self?.reloadGitBase() }
        let controller = TextViewController(
            string: initialText,
            language: language,
            configuration: Self.configuration(theme: theme, indentOption: indentOption),
            cursorPositions: [],
            coordinators: [changeTracker, gutter]
        )
        initialText = "" // the text view owns the contents from now on
        _controller = controller
        return controller
    }

    /// Picks up a changed font size from the settings.
    func applyFont() {
        guard let controller = _controller else { return }
        let font = AppSettings.shared.editorFont
        if controller.configuration.appearance.font != font { controller.configuration.appearance.font = font }
    }

    /// Moves the cursor to `line` (1-based), now if the editor is on screen, otherwise once it appears.
    /// With `column` (0-based, UTF-16) the text from there is selected, e.g. a search hit.
    func reveal(line: Int, column: (column: Int, length: Int)? = nil) {
        pendingLine = (line, column)
        if _controller?.view.window != nil {
            applyPendingLine()
        }
    }

    func applyPendingLine() {
        guard let (line, column) = pendingLine, let controller = _controller else { return }
        pendingLine = nil
        if let column, let textLine = controller.textView.layoutManager.textLineForIndex(line - 1) {
            let location = min(textLine.range.location + column.column, NSMaxRange(textLine.range))
            let length = min(column.length, NSMaxRange(textLine.range) - location)
            controller.setCursorPositions([CursorPosition(range: NSRange(location: location, length: length))], scrollToVisible: true)
        } else {
            controller.setCursorPositions([CursorPosition(line: line, column: 1)], scrollToVisible: true)
        }
    }

    /// Whether keyboard focus is in this document's editor.
    var hasKeyboardFocus: Bool {
        guard let textView = _controller?.textView,
              let responder = textView.window?.firstResponder as? NSView else { return false }
        return responder === textView || responder.isDescendant(of: textView)
    }

    /// Where the cursor is and what is selected, with 1-based lines, for tools working with the editor.
    var cursorContext: (line: Int, column: Int, selection: String?, selectionLines: ClosedRange<Int>?)? {
        guard let controller = _controller, let range = controller.cursorPositions.first?.range else { return nil }
        let text = controller.text as NSString
        func line(at location: Int) -> (line: Int, column: Int) {
            let prefix = text.substring(to: min(location, text.length))
            let lines = prefix.components(separatedBy: "\n")
            return (lines.count, (lines.last?.count ?? 0) + 1)
        }
        let start = line(at: range.location)
        guard range.length > 0, NSMaxRange(range) <= text.length else { return (start.line, start.column, nil, nil) }
        let end = line(at: NSMaxRange(range))
        return (start.line, start.column, text.substring(with: range), start.line...end.line)
    }

    /// The selected text, if the selection is on a single line (for prefilling searches).
    var selectedSingleLineText: String? {
        guard let controller = _controller, let range = controller.cursorPositions.first?.range, range.length > 0,
              range.length < 200 else { return nil }
        let text = (controller.text as NSString).substring(with: range)
        return text.contains("\n") ? nil : text
    }

    func save() throws {
        guard loadError == nil, isDirty || diskState == .deletedOnDisk else { return }
        // Plain (non-atomic) write keeps the file's inode, so permissions such as +x survive.
        let contents = text
        try Data(contents.utf8).write(to: url)
        isDirty = false
        diskState = .inSync
        rememberDiskVersion(contents)
    }

    // MARK: Change marks

    /// Fetches the file's version in git's index, then marks the lines that differ from it.
    func reloadGitBase() {
        guard let repository, _controller != nil else { return }
        Task { [weak self, url] in
            let base = await repository.indexText(ofFile: url)
            guard let self else { return }
            if base != baseText || base == nil {
                baseText = base
                scheduleLineDiff(delay: false)
            }
        }
    }

    private func scheduleLineDiff(delay: Bool = true) {
        lineDiffTask?.cancel()
        guard let base = baseText else {
            gutter.marksView.changes = LineChanges()
            return
        }
        lineDiffTask = Task { [weak self] in
            if delay { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let text = self?.text else { return }
            let changes = await Task.detached(priority: .userInitiated) { LineChanges.compute(base: base, current: text) }.value
            guard !Task.isCancelled else { return }
            self?.gutter.marksView.changes = changes
        }
    }

    // MARK: Changes made by other programs

    /// Compares the tab with the file on disk. Clean tabs pick up the new contents silently;
    /// tabs with unsaved edits are flagged so the user can choose.
    func checkDisk() {
        guard loadError == nil else { return }
        if isRasterImage {
            guard let modified = Self.modificationDate(of: url) else {
                diskState = .deletedOnDisk
                return
            }
            diskState = .inSync
            if modified != knownModificationDate {
                knownModificationDate = modified
                image = NSImage(contentsOf: url)
            }
            return
        }
        guard let modified = Self.modificationDate(of: url) else {
            diskState = .deletedOnDisk
            return
        }
        guard modified != knownModificationDate else {
            if diskState == .deletedOnDisk { diskState = .inSync }
            return
        }
        guard let text = Self.readText(at: url) else { return }
        let contentChanged = text.hashValue != knownContentHash
        rememberDiskVersion(text)
        guard contentChanged else {
            if diskState == .deletedOnDisk { diskState = .inSync }
            return // only touched
        }
        if isDirty {
            diskState = .changedOnDisk
        } else {
            replaceText(with: text)
            diskState = .inSync
        }
    }

    /// Throws away unsaved edits and loads the file from disk.
    func reloadFromDisk() {
        guard let text = Self.readText(at: url) else { return }
        rememberDiskVersion(text)
        replaceText(with: text)
        isDirty = false
        diskState = .inSync
    }

    /// Keeps the edits in the tab; the next save overwrites the file on disk.
    func keepLocalVersion() {
        diskState = .inSync
    }

    private func rememberDiskVersion(_ text: String) {
        knownModificationDate = Self.modificationDate(of: url)
        knownContentHash = text.hashValue
    }

    /// The text as it is in the editor, including unsaved edits.
    var text: String {
        _controller?.text ?? initialText
    }

    private func replaceText(with text: String) {
        textVersion += 1
        if isImage { image = NSImage(data: Data(text.utf8)) }
        guard let controller = _controller else {
            initialText = text
            return
        }
        // Keep the caret and scroll position roughly where they were.
        let selection = controller.cursorPositions.first?.range.location ?? 0
        let scrollOrigin = controller.scrollView.contentView.bounds.origin
        controller.text = text
        let location = min(selection, (text as NSString).length)
        controller.setCursorPositions([CursorPosition(range: NSRange(location: location, length: 0))])
        controller.scrollView.contentView.scroll(to: scrollOrigin)
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        isDirty = false
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func load() {
        if isRasterImage {
            loadImage()
            return
        }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            if size > Self.maxFileSize {
                loadError = "Dosya çok büyük (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
                return
            }
            let data = try Data(contentsOf: url)
            if data.prefix(8000).contains(0) {
                loadError = "İkili (binary) dosya, metin olarak açılamıyor."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                loadError = "Dosya UTF-8 değil."
                return
            }
            initialText = text
            rememberDiskVersion(text)
            if isImage {
                image = NSImage(data: data)
                showsImage = image != nil
            }
            language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(512)))
            indentOption = Self.detectIndent(in: text, fileName: url.lastPathComponent, language: language)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadImage() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxImageSize else {
            loadError = "Görsel çok büyük (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            return
        }
        guard let image = NSImage(contentsOf: url) else {
            loadError = "Görsel açılamadı."
            return
        }
        self.image = image
        knownModificationDate = Self.modificationDate(of: url)
    }

    static func configuration(theme: EditorTheme, indentOption: IndentOption) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme,
                font: AppSettings.shared.editorFont,
                lineHeightMultiple: 1.3,
                wrapLines: false,
                tabWidth: 4
            ),
            behavior: .init(indentOption: indentOption),
            peripherals: .init(showMinimap: false)
        )
    }

    /// Guesses tabs vs. 2 or 4 spaces from the file itself, falling back to the language's convention.
    nonisolated static func detectIndent(in text: String, fileName: String, language: CodeLanguage) -> IndentOption {
        var tabLines = 0
        var spaceLines = 0
        var twoSpaceLines = 0

        for line in text.split(separator: "\n").prefix(2000) {
            if line.first == "\t" {
                tabLines += 1
            } else if line.first == " " {
                let count = line.prefix { $0 == " " }.count
                // Skip whitespace-only lines and block comment continuations (" * foo").
                guard count < line.count, line.dropFirst(count).first != "*" else { continue }
                spaceLines += 1
                // 2, 6, 10… spaces only happen with 2-space indentation (odd counts are alignment).
                if count % 4 == 2 { twoSpaceLines += 1 }
            }
        }

        if tabLines > 0 || spaceLines > 0 {
            if tabLines > spaceLines { return .tab }
            return twoSpaceLines > 0 && twoSpaceLines * 10 >= spaceLines ? .spaces(count: 2) : .spaces(count: 4)
        }

        if fileName == "Makefile" || fileName.hasSuffix(".mk") { return .tab }
        switch language.id {
        case .go, .goMod:
            return .tab
        case .dart, .javascript, .jsx, .typescript, .tsx, .json, .yaml, .html, .css, .ruby, .lua:
            return .spaces(count: 2)
        default:
            return .spaces(count: 4)
        }
    }
}

private final class ChangeTracker: TextViewCoordinator {
    var onChange: (() -> Void)?

    func prepareCoordinator(controller: TextViewController) {}

    func textViewDidChangeText(controller: TextViewController) {
        onChange?()
    }
}
