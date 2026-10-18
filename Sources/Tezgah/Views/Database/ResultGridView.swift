import AppKit
import SwiftUI

/// What the grid can do when it shows a table being browsed: sort by header click, edit cells,
/// add and delete rows, jump along foreign keys.
struct GridBrowsing {
    var edits: TableEdits
    /// Data columns that can be edited; empty means read-only (a view, or no primary key).
    var editableColumns: Set<Int>
    /// Primary key columns; a row whose key value is shortened in the grid cannot be edited.
    var keyColumns: [Int]
    var sortColumn: String?
    var sortDescending: Bool
    var incomingKeys: [ForeignKey]
    var outgoingKey: (String) -> ForeignKey?
    var onSort: (String) -> Void
    var onSet: (_ row: Int, _ column: Int, _ value: String?) -> Void
    var onDelete: ([Int]) -> Void
    var onAddRow: () -> Void
    var onRevert: ([Int]) -> Void
    var onFollow: (_ key: ForeignKey, _ value: String, _ outgoing: Bool) -> Void

    var isEditable: Bool { !editableColumns.isEmpty }
}

/// A query result as a spreadsheet-like table: row numbers, NULLs in grey, copying as TSV.
struct ResultGridView: NSViewRepresentable {
    let result: QueryResult
    var browsing: GridBrowsing?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = CopyingTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 20
        tableView.style = .plain
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.coordinator = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.show(result, browsing: browsing, in: tableView)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        private(set) var result = QueryResult()
        private var browsing: GridBrowsing?
        private var shownResult: QueryResult?
        private var shownEdits: TableEdits?
        private static let numberColumn = NSUserInterfaceItemIdentifier("#")
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let italicFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular).withTraits(.italic)
        /// The cell being typed into.
        private var editingCell: (row: Int, column: Int)?
        private var editCancelled = false
        weak var tableView: NSTableView?

        func show(_ result: QueryResult, browsing: GridBrowsing?, in tableView: NSTableView) {
            self.tableView = tableView
            self.browsing = browsing
            if result != shownResult {
                shownResult = result
                shownEdits = browsing?.edits
                self.result = result
                rebuildColumns(in: tableView)
                tableView.reloadData()
                tableView.scrollRowToVisible(0)
            } else if browsing?.edits != shownEdits {
                shownEdits = browsing?.edits
                let selection = tableView.selectedRowIndexes
                tableView.reloadData()
                tableView.selectRowIndexes(selection, byExtendingSelection: false)
            }
            updateSortIndicators(in: tableView)
        }

        private func rebuildColumns(in tableView: NSTableView) {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }

            let numbers = NSTableColumn(identifier: Self.numberColumn)
            numbers.title = ""
            numbers.width = max(32, CGFloat(String(result.rows.count).count) * 8 + 14)
            numbers.isEditable = false
            tableView.addTableColumn(numbers)

            for (index, name) in result.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                column.title = name
                column.headerToolTip = name
                column.minWidth = 40
                column.width = width(ofColumn: index, title: name)
                tableView.addTableColumn(column)
            }
        }

        private func updateSortIndicators(in tableView: NSTableView) {
            for column in tableView.tableColumns {
                guard let index = Int(column.identifier.rawValue), let browsing else {
                    tableView.setIndicatorImage(nil, in: column)
                    continue
                }
                let image: NSImage? = browsing.sortColumn == result.columns[safe: index]
                    ? NSImage(named: browsing.sortDescending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator")
                    : nil
                if tableView.indicatorImage(in: column) != image { tableView.setIndicatorImage(image, in: column) }
            }
        }

        /// Wide enough for the header and the first rows, up to a limit.
        private func width(ofColumn index: Int, title: String) -> CGFloat {
            let sample = result.rows.prefix(60).map { ($0[index] ?? "NULL").prefix(60).count }
            let characters = max(title.count + 2, sample.max() ?? 4)
            return min(max(CGFloat(characters) * 7.4 + 16, 60), 360)
        }

        private var rowCount: Int {
            result.rows.count + (browsing?.edits.insertedRows.count ?? 0)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowCount
        }

        /// The value shown in a cell, with pending edits applied.
        private func cell(row: Int, column: Int) -> (value: String?, isChanged: Bool, isDefault: Bool) {
            if let edits = browsing?.edits {
                return edits.value(row: row, column: column, original: result.rows)
            }
            return (result.rows[safe: row]?[safe: column] ?? nil, false, false)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                field.cell?.truncatesLastVisibleLine = true
                field.delegate = self
                return field
            }()
            field.isEditable = false
            field.drawsBackground = false
            field.backgroundColor = nil
            let isNew = row >= result.rows.count
            let isDeleted = browsing?.edits.deletedRows.contains(row) ?? false

            if tableColumn.identifier == Self.numberColumn {
                field.stringValue = isNew ? "+" : "\(row + 1)"
                field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                field.textColor = isNew ? .systemGreen : isDeleted ? .systemRed : .tertiaryLabelColor
                field.alignment = .right
                field.toolTip = isNew ? "Yeni satır (kaydedilmedi)" : isDeleted ? "Silinecek (kaydedilmedi)" : nil
                return field
            }
            let index = Int(tableColumn.identifier.rawValue) ?? 0
            let shown = cell(row: row, column: index)
            field.alignment = .left
            var attributes: [NSAttributedString.Key: Any] = [:]
            if shown.isDefault {
                field.stringValue = "‹varsayılan›"
                field.font = italicFont
                field.textColor = .tertiaryLabelColor
                field.toolTip = "Kaydedince sütunun varsayılan değeri kullanılır"
            } else if let value = shown.value {
                // One line per cell; newlines would make rows unreadable.
                field.stringValue = value.replacingOccurrences(of: "\n", with: "⏎ ")
                field.font = font
                field.textColor = .labelColor
                field.toolTip = value.count > 40 ? value : nil
            } else {
                field.stringValue = "NULL"
                field.font = italicFont
                field.textColor = .tertiaryLabelColor
                field.toolTip = nil
            }
            if isDeleted {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                field.textColor = .systemRed
            }
            if !attributes.isEmpty {
                attributes[.font] = field.font
                attributes[.foregroundColor] = field.textColor
                field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: attributes)
            }
            if isNew || shown.isChanged {
                field.drawsBackground = true
                field.backgroundColor = (isNew ? NSColor.systemGreen : NSColor.systemYellow).withAlphaComponent(0.18)
            }
            return field
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let browsing, let index = Int(tableColumn.identifier.rawValue), let name = result.columns[safe: index] else { return }
            browsing.onSort(name)
        }

        // MARK: Editing

        private func canEdit(row: Int, column: Int) -> Bool {
            guard let browsing, browsing.editableColumns.contains(column) else { return false }
            if browsing.edits.deletedRows.contains(row) { return false }
            if row >= result.rows.count { return true }
            // Shortened values cannot be edited, and the key must be shown in full to find the row again.
            return TableEditSQL.isEditable(result.rows[row][column], type: "")
                && browsing.keyColumns.allSatisfy { TableEditSQL.isEditable(result.rows[row][$0], type: "") }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let column = sender.clickedColumn
            guard row >= 0, column >= 0, let index = Int(sender.tableColumns[column].identifier.rawValue) else { return }
            beginEditing(row: row, column: index, tableColumn: column, in: sender)
        }

        private func beginEditing(row: Int, column: Int, tableColumn: Int, in tableView: NSTableView) {
            guard canEdit(row: row, column: column) else {
                if browsing?.isEditable == false, row < result.rows.count {
                    NSSound.beep()
                }
                return
            }
            let value = cell(row: row, column: column).value
            // Long or multi-line values get a bigger editor.
            if let value, value.contains("\n") || value.count > 200 {
                editInSheet(row: row, column: column, value: value)
                return
            }
            guard let field = tableView.view(atColumn: tableColumn, row: row, makeIfNecessary: true) as? NSTextField else { return }
            editingCell = (row, column)
            editCancelled = false
            field.isEditable = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.textColor = .labelColor
            field.font = font
            field.stringValue = value ?? ""
            field.placeholderString = value == nil ? "NULL" : nil
            tableView.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                control.abortEditing()
                finishEditing(control as? NSTextField)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing(notification.object as? NSTextField)
        }

        private func finishEditing(_ field: NSTextField?) {
            guard let (row, column) = editingCell else { return }
            editingCell = nil
            field?.isEditable = false
            field?.placeholderString = nil
            let original = cell(row: row, column: column).value
            if !editCancelled, let text = field?.stringValue {
                // Leaving a NULL cell empty keeps it NULL; "NULL Yap" in the menu sets one.
                let value: String? = original == nil && text.isEmpty ? nil : text
                if value != original { browsing?.onSet(row, column, value) }
            }
            if let tableView {
                tableView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
                tableView.window?.makeFirstResponder(tableView)
            }
        }

        private func editInSheet(row: Int, column: Int, value: String?) {
            let alert = NSAlert()
            alert.messageText = result.columns[safe: column] ?? ""
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 240)
            scroll.borderType = .bezelBorder
            let textView = scroll.documentView as! NSTextView
            textView.font = font
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.string = value ?? ""
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Tamam")
            alert.addButton(withTitle: "Vazgeç").keyEquivalent = "\u{1b}"
            alert.window.initialFirstResponder = textView
            guard alert.runModal() == .alertFirstButtonReturn, textView.string != value else { return }
            browsing?.onSet(row, column, textView.string)
        }

        func deleteSelectedRows(_ tableView: NSTableView) {
            guard browsing?.isEditable == true else { return }
            let rows = Array(tableView.selectedRowIndexes)
            if !rows.isEmpty { browsing?.onDelete(rows) }
        }

        // MARK: Context menu

        private var menuRow = -1
        private var menuColumn: Int?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            menuRow = tableView.clickedRow
            menuColumn = tableView.clickedColumn >= 0 ? Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue) : nil
            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
                item.target = self
            }

            add("Hücreyi Kopyala", #selector(copyCell(_:)), enabled: menuRow >= 0 && menuColumn != nil)
            add("Satırları Kopyala (TSV)", #selector(copyRows(_:)))
            add("Satırları JSON Olarak Kopyala", #selector(copyJSON(_:)))
            menu.addItem(.separator())
            add("Tümünü CSV Olarak Kaydet…", #selector(exportCSV(_:)))

            guard let browsing else { return }
            if browsing.isEditable {
                menu.addItem(.separator())
                if menuRow >= 0, let column = menuColumn, canEdit(row: menuRow, column: column) {
                    add("Değeri Düzenle", #selector(editCell(_:)))
                    add("NULL Yap", #selector(setNull(_:)))
                }
                add("Satır Ekle", #selector(addRow(_:)))
                if !rows(in: tableView).isEmpty {
                    add("Satırları Sil", #selector(deleteRows(_:)))
                    add("Satırdaki Değişiklikleri Geri Al", #selector(revertRows(_:)))
                }
            }

            // Foreign keys: from this cell to the row it points at, and from this row to rows pointing here.
            guard menuRow >= 0, menuRow < result.rows.count else { return }
            var links: [NSMenuItem] = []
            if let column = menuColumn, let name = result.columns[safe: column], let key = browsing.outgoingKey(name),
               let value = result.rows[menuRow][column] {
                let item = NSMenuItem(title: "→ \(key.referencedTable) (\(key.referencedColumns[0]) = \(value.prefix(40)))",
                                      action: #selector(followLink(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = LinkTarget(key: key, value: value, outgoing: true)
                links.append(item)
            }
            for key in browsing.incomingKeys {
                guard let column = result.columns.firstIndex(of: key.referencedColumns[0]), let value = result.rows[menuRow][column] else { continue }
                let item = NSMenuItem(title: "← \(key.table).\(key.columns[0]) = \(value.prefix(40))", action: #selector(followLink(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = LinkTarget(key: key, value: value, outgoing: false)
                links.append(item)
            }
            if !links.isEmpty {
                menu.addItem(.separator())
                links.forEach(menu.addItem)
            }
        }

        private final class LinkTarget {
            let key: ForeignKey
            let value: String
            let outgoing: Bool
            init(key: ForeignKey, value: String, outgoing: Bool) {
                self.key = key
                self.value = value
                self.outgoing = outgoing
            }
        }

        @objc private func followLink(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? LinkTarget else { return }
            browsing?.onFollow(target.key, target.value, target.outgoing)
        }

        @objc private func editCell(_ sender: NSMenuItem) {
            guard let tableView, let column = menuColumn,
                  let tableColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "\(column)" }) else { return }
            beginEditing(row: menuRow, column: column, tableColumn: tableColumn, in: tableView)
        }

        @objc private func setNull(_ sender: NSMenuItem) {
            guard let column = menuColumn, menuRow >= 0 else { return }
            browsing?.onSet(menuRow, column, nil)
        }

        @objc private func addRow(_ sender: NSMenuItem) {
            browsing?.onAddRow()
        }

        @objc private func deleteRows(_ sender: NSMenuItem) {
            guard let tableView else { return }
            browsing?.onDelete(rows(in: tableView))
        }

        @objc private func revertRows(_ sender: NSMenuItem) {
            guard let tableView else { return }
            browsing?.onRevert(rows(in: tableView))
        }

        // MARK: Copying

        private func rows(in tableView: NSTableView) -> [Int] {
            var rows = Array(tableView.selectedRowIndexes)
            if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) { rows = [tableView.clickedRow] }
            return rows.sorted()
        }

        /// Existing rows only; new rows have nothing to copy yet.
        private func dataRows(in tableView: NSTableView) -> [Int] {
            rows(in: tableView).filter { $0 < result.rows.count }
        }

        /// Columns in their on-screen order (they can be dragged around).
        private func dataColumns(in tableView: NSTableView) -> [Int] {
            tableView.tableColumns.compactMap { Int($0.identifier.rawValue) }
        }

        func copyRowsAsTSV(_ tableView: NSTableView) {
            let columns = dataColumns(in: tableView)
            let header = columns.map { result.columns[$0] }.joined(separator: "\t")
            let lines = dataRows(in: tableView).map { row in
                columns.map { result.rows[row][$0] ?? "" }.joined(separator: "\t")
            }
            let includeHeader = lines.count > 1
            copy(((includeHeader ? [header] : []) + lines).joined(separator: "\n"))
        }

        @objc private func copyCell(_ sender: NSMenuItem) {
            guard menuRow >= 0, let column = menuColumn else { return }
            copy(cell(row: menuRow, column: column).value ?? "NULL")
        }

        @objc private func copyRows(_ sender: NSMenuItem) {
            guard let tableView else { return }
            copyRowsAsTSV(tableView)
        }

        @objc private func copyJSON(_ sender: NSMenuItem) {
            guard let tableView else { return }
            let columns = dataColumns(in: tableView)
            let objects: [[String: Any]] = dataRows(in: tableView).map { row in
                Dictionary(columns.map { (result.columns[$0], result.rows[row][$0] as Any? ?? NSNull()) }, uniquingKeysWith: { a, _ in a })
            }
            guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]) else { return }
            copy(String(decoding: data, as: UTF8.self))
        }

        @objc private func exportCSV(_ sender: NSMenuItem) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "sonuc.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            func field(_ value: String?) -> String {
                guard let value else { return "" }
                return value.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }
            let lines = [result.columns.map(field).joined(separator: ",")] + result.rows.map { $0.map(field).joined(separator: ",") }
            do {
                try Data((lines.joined(separator: "\r\n") + "\r\n").utf8).write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }

        private func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// ⌘C copies the selected rows, Delete marks them for deletion while editing a table.
private final class CopyingTableView: NSTableView {
    weak var coordinator: ResultGridView.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copyRowsAsTSV(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            coordinator?.deleteSelectedRows(self)
            return
        }
        super.keyDown(with: event)
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
