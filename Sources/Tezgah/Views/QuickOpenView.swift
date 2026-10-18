import AppKit
import Observation
import SwiftUI

struct QuickOpenResult: Identifiable {
    /// For commands, the title stands in for the path.
    let entry: FileEntry
    let positions: Set<Int>
    var command: PaletteCommand?

    var id: String { command.map { "command:\($0.id)" } ?? entry.path }
}

/// An action offered in the command palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var shortcut: String?
    var symbol = "command"
    let action: @MainActor () -> Void
}

@MainActor
@Observable
final class QuickOpenModel {
    let project: Project
    var query = ""
    var selection = 0
    private(set) var results: [QuickOpenResult] = []
    /// "file:42" → 42. A bare ":42" jumps within the current file.
    private(set) var line: Int?
    private(set) var fileQuery = ""

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Supplies the palette's commands; set by the view.
    @ObservationIgnored var commands: () -> [PaletteCommand] = { [] }
    /// Sends the query to Claude; set by the view. Offered for anything typed that is not a command or a line jump.
    @ObservationIgnored var askClaude: ((String) -> Void)?

    init(project: Project, query: String = "") {
        self.project = project
        self.query = query
    }

    /// A query starting with ">" lists commands instead of files.
    var isCommandMode: Bool { query.hasPrefix(">") }

    var selectedResult: QuickOpenResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + offset + results.count) % results.count
    }

    func search() {
        searchTask?.cancel()
        if isCommandMode {
            fileQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            line = nil
            results = Self.match(fileQuery, in: commands())
            selection = 0
            return
        }
        (fileQuery, line) = Self.parse(query)

        if fileQuery.isEmpty {
            // Recently opened files, most recent first, without the one already in front.
            let current = project.selectedDocument.map { project.relativePath(of: $0.url) }
            results = project.recentFiles
                .filter { $0 != current }
                .map { QuickOpenResult(entry: FileEntry(path: $0), positions: []) }
            selection = 0
            return
        }

        let text = fileQuery
        results = withAskClaude([])
        selection = 0
        let entries = project.fileIndex.entries
        searchTask = Task { [weak self] in
            // Runs off the main actor as a child task, so cancelling the search cancels it too.
            async let search = FuzzyMatcher.search(text, in: entries)
            let found = await search
            guard !Task.isCancelled, let self, self.fileQuery == text else { return }
            self.results = self.withAskClaude(found.map { QuickOpenResult(entry: $0.entry, positions: Set($0.match.positions)) })
            self.selection = 0
        }
    }

    /// Adds "Claude'a sor" to file results: first when the query reads like a sentence, else last.
    private func withAskClaude(_ files: [QuickOpenResult]) -> [QuickOpenResult] {
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let askClaude, line == nil, !prompt.isEmpty else { return files }
        let ask = QuickOpenResult(
            entry: FileEntry(path: "Claude'a sor: \(prompt.replacingOccurrences(of: "/", with: "∕"))"),
            positions: [],
            command: PaletteCommand(id: "claude.ask", title: "Claude'a sor", shortcut: "↩", symbol: "sparkle") { askClaude(prompt) }
        )
        return prompt.contains(" ") ? [ask] + files : files + [ask]
    }

    /// Fuzzy-matches command titles; an empty query keeps the given order.
    static func match(_ query: String, in commands: [PaletteCommand]) -> [QuickOpenResult] {
        let results = commands.map { command in
            QuickOpenResult(entry: FileEntry(path: command.title), positions: [], command: command)
        }
        let needle = FuzzyMatcher.lowercased(Array(query.replacingOccurrences(of: " ", with: "").utf16))
        guard !needle.isEmpty else { return results }
        return results
            .compactMap { result -> (QuickOpenResult, Int)? in
                guard let match = FuzzyMatcher.match(needle, in: result.entry) else { return nil }
                let matched = QuickOpenResult(entry: result.entry, positions: Set(match.positions), command: result.command)
                return (matched, match.score)
            }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
    }

    nonisolated static func parse(_ query: String) -> (file: String, line: Int?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.lastIndex(of: ":"),
           let line = Int(trimmed[trimmed.index(after: colon)...]), line > 0 {
            return (String(trimmed[..<colon]), line)
        }
        return (trimmed, nil)
    }
}

struct QuickOpenView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var model: QuickOpenModel

    private static let rowHeight: CGFloat = 28
    private static let maxVisibleRows = 12

    init(project: Project, query: String = "") {
        _model = State(initialValue: QuickOpenModel(project: project, query: query))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                QuickOpenField(
                    text: $model.query,
                    placeholder: model.isCommandMode ? "Komut ara…" : "Dosya ara, Claude'a sor… (main.go:42 satıra gider · > komutlar)",
                    onMove: { model.move($0) },
                    onSubmit: submit,
                    onCancel: { store.hideQuickOpen() }
                )
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            if model.results.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                QuickOpenRow(result: result, isSelected: index == model.selection)
                                    .frame(height: Self.rowHeight)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selection = index
                                        submit()
                                    }
                                    .id(index)
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: CGFloat(min(model.results.count, Self.maxVisibleRows)) * Self.rowHeight + 8)
                    .onChange(of: model.selection) {
                        proxy.scrollTo(model.selection)
                    }
                }
            }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onChange(of: model.query) { model.search() }
        .task {
            model.commands = { [store, project = model.project] in store.paletteCommands(for: project) }
            model.askClaude = { [store, project = model.project] prompt in store.askClaude(prompt, in: project) }
            model.search()
            await model.project.fileIndex.refresh()
            model.search()
        }
    }

    private var emptyMessage: String {
        if model.isCommandMode {
            return "“\(model.fileQuery)” ile eşleşen komut yok."
        }
        if model.fileQuery.isEmpty {
            if let line = model.line {
                return model.project.selectedDocument == nil ? "Satıra gitmek için önce bir dosya aç." : "↩ ile \(line). satıra git"
            }
            return "Dosya adı yaz. Satıra gitmek için dosya:42 ya da sadece :42 yazabilirsin."
        }
        return "“\(model.fileQuery)” ile eşleşen dosya yok."
    }

    private func submit() {
        if let command = model.selectedResult?.command {
            store.hideQuickOpen()
            if command.id != "claude.ask" { store.noteCommandUsed(command.id) }
            // After the panel is gone, so alerts and focus changes land in the right place.
            DispatchQueue.main.async { command.action() }
            return
        }
        if let result = model.selectedResult {
            store.hideQuickOpen(restoreFocus: false)
            store.openFile(model.project.url.appendingPathComponent(result.entry.path), line: model.line)
        } else if model.fileQuery.isEmpty, let line = model.line, let document = model.project.selectedDocument {
            store.hideQuickOpen()
            document.reveal(line: line)
        }
    }
}

private struct QuickOpenRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    var body: some View {
        let entry = result.entry
        let name = String(entry.path.utf16.dropFirst(entry.nameStart)) ?? entry.path
        let folder = entry.nameStart > 0 ? String(entry.path.utf16.prefix(entry.nameStart - 1)) ?? "" : ""

        HStack(spacing: 8) {
            if let command = result.command {
                Image(systemName: command.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(highlighted(entry.path, startingAt: 0))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                FileTypeIcon(URL(fileURLWithPath: entry.path))
                Text(highlighted(name, startingAt: entry.nameStart))
                    .lineLimit(1)
                Text(highlighted(folder, startingAt: 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    /// Bolds the matched characters. `offset` is the UTF-16 offset of `text` within the path.
    private func highlighted(_ text: String, startingAt offset: Int) -> AttributedString {
        var attributed = AttributedString()
        var position = offset
        for character in text {
            var piece = AttributedString(String(character))
            let length = character.utf16.count
            if (position..<position + length).contains(where: result.positions.contains) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            attributed += piece
            position += length
        }
        return attributed
    }
}

/// A borderless search field that forwards ↑ ↓ ↩ and Esc instead of handling them itself.
private struct QuickOpenField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenField

        init(_ parent: QuickOpenField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}
