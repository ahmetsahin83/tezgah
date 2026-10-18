import AppKit
import CodeEditSourceEditor
import SwiftUI

/// Feeds the editor's suggestion window from the connection's schema: tables after FROM,
/// columns of the tables in the statement, `alias.` members, joins along foreign keys, keywords.
final class SQLCompletionProvider: CodeSuggestionDelegate {
    weak var session: DatabaseSession?
    /// Candidates for the context the window was opened in; typing more only filters them.
    private var candidates: [SQLCompletionItem] = []
    private var openedContext: SQLCompletionContext?

    init(session: DatabaseSession) {
        self.session = session
    }

    func completionTriggerCharacters() -> Set<String> { ["."] }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        await MainActor.run { self.open(textView, at: cursorPosition) }
    }

    @MainActor
    private func open(_ textView: TextViewController, at position: CursorPosition) -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let session, let context = SQLCompletion.context(in: textView.text, cursor: position.range.location, dialect: session.config.kind) else {
            return nil
        }
        candidates = SQLCompletion.items(for: context, schema: session.schema, dialect: session.config.kind)
        openedContext = context
        let items = visibleItems(for: context)
        guard !items.isEmpty else { return nil }
        return (CursorPosition(range: NSRange(location: context.prefixRange.location, length: 0)), items)
    }

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        MainActor.assumeIsolated {
            guard let session, let opened = openedContext,
                  let context = SQLCompletion.context(in: textView.text, cursor: cursorPosition.range.location, dialect: session.config.kind),
                  context.prefixRange.location == opened.prefixRange.location, context.expectation == opened.expectation
            else {
                // Somewhere else now (a new word, after a dot…): close, and reopen with fresh candidates if typing.
                openedContext = nil
                return nil
            }
            let items = visibleItems(for: context)
            return items.isEmpty ? nil : items
        }
    }

    private func visibleItems(for context: SQLCompletionContext) -> [CodeSuggestionEntry] {
        let filtered = SQLCompletion.filter(candidates, prefix: context.prefix)
        // A fully typed keyword needs no window; Return should insert a newline.
        if filtered.count == 1, filtered[0].insertText.caseInsensitiveCompare(context.prefix) == .orderedSame {
            return []
        }
        return filtered.map(SQLSuggestionEntry.init)
    }

    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?) {
        MainActor.assumeIsolated {
            guard let entry = item as? SQLSuggestionEntry, let session else { return }
            // ⌘↩ while the list is open means "run", not "pick".
            if let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command) {
                session.run(event.modifierFlags.contains(.shift) ? .all : .current)
                return
            }
            let cursor = textView.cursorPositions.first?.range.location ?? cursorPosition?.range.location ?? 0
            guard let context = SQLCompletion.context(in: textView.text, cursor: cursor, dialect: session.config.kind) else { return }
            var range = context.prefixRange
            if let replace = entry.item.replaceRange {
                range = NSRange(location: replace.location, length: NSMaxRange(context.prefixRange) - replace.location)
            }
            let inserted = entry.item.insertText
            textView.textView.replaceCharacters(in: range, with: inserted)
            let caret = range.location + (inserted as NSString).length - entry.item.cursorBackOffset
            textView.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
            openedContext = nil
        }
    }

    func completionWindowDidClose() {
        openedContext = nil
    }
}

/// A completion item in the shape the suggestion window wants.
struct SQLSuggestionEntry: CodeSuggestionEntry {
    let item: SQLCompletionItem

    var label: String { item.label }
    var detail: String? { item.detail }
    var documentation: String? { item.kind == .join || item.kind == .snippet ? item.insertText : nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var deprecated: Bool { false }

    var image: Image {
        switch item.kind {
        case .column: Image(systemName: "line.3.horizontal")
        case .table: Image(systemName: "tablecells")
        case .view: Image(systemName: "eye")
        case .alias: Image(systemName: "character.cursor.ibeam")
        case .schema: Image(systemName: "folder")
        case .join: Image(systemName: "arrow.triangle.merge")
        case .function: Image(systemName: "function")
        case .keyword: Image(systemName: "textformat")
        case .snippet: Image(systemName: "asterisk")
        }
    }

    var imageColor: Color {
        switch item.kind {
        case .column: .blue
        case .table, .view, .alias: .orange
        case .schema: .brown
        case .join: .green
        case .function: .purple
        case .keyword, .snippet: .gray
        }
    }
}
