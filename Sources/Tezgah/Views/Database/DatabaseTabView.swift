import AppKit
import CodeEditSourceEditor
import SwiftUI

/// A database tab: tables on the left, SQL editor on top, results below.
struct DatabaseTabView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let session: DatabaseSession
    let project: Project
    @State private var isEditingConnection = false
    @State private var isShowingHistory = false

    var body: some View {
        HSplitView {
            SchemaSidebar(session: session)
                .frame(minWidth: 170, idealWidth: 230, maxWidth: 420, maxHeight: .infinity)
            VSplitView {
                VStack(spacing: 0) {
                    header
                    Divider()
                    let theme = EditorThemes.theme(for: colorScheme)
                    SQLEditorRepresentable(controller: session.controller(theme: theme), theme: theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 90, idealHeight: 220, maxHeight: .infinity)
                ResultsPane(session: session)
                    .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 400, maxHeight: .infinity)
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Split views size themselves from their content; without this the tab starts out small
        // and only fills the window once a result grid (which is greedy) appears.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { session.connectIfNeeded() }
        .sheet(isPresented: $isEditingConnection) {
            ConnectionSheet(project: project, existing: session.config) { config, password in
                store.saveDatabase(config, password: password, in: project)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .help(statusHelp)
            Text(session.config.name)
                .fontWeight(.medium)
            Text(session.config.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if session.inTransaction {
                transactionControls
            }
            Spacer(minLength: 8)
            if session.isRunning {
                if let started = session.runStartedAt {
                    TimelineView(.periodic(from: started, by: 0.1)) { context in
                        Text(elapsed(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    session.cancel()
                } label: {
                    Label("Durdur", systemImage: "stop.fill")
                }
                .help("Çalışan sorguyu iptal et (⌘.)")
            } else {
                Button {
                    session.run(.current)
                } label: {
                    Label("Çalıştır", systemImage: "play.fill")
                }
                .help("Seçimi ya da imlecin bulunduğu ifadeyi çalıştır (⌘↩)")
                Button {
                    session.run(.all)
                } label: {
                    Label("Tümü", systemImage: "forward.fill")
                }
                .help("Bütün ifadeleri sırayla çalıştır (⇧⌘↩)")
            }
            Menu {
                Button("Planı Göster (EXPLAIN)") { session.explain() }
                if session.dialect == .postgres {
                    Button("Çalıştırarak Ölç (EXPLAIN ANALYZE)") { session.explain(analyze: true) }
                }
            } label: {
                Label("Plan", systemImage: "list.bullet.indent")
            } primaryAction: {
                session.explain()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("İmlecin bulunduğu sorgunun çalışma planı")
            .disabled(session.isRunning || session.state != .connected)
            Button {
                session.formatSQL()
            } label: {
                Image(systemName: "text.alignleft")
            }
            .help("Seçimi ya da imlecin bulunduğu ifadeyi biçimlendir (⌥⌘L)")
            .accessibilityLabel("Seçimi ya da imlecin bulunduğu ifadeyi biçimlendir (⌥⌘L)")
            Button {
                isShowingHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Sorgu geçmişi")
            .accessibilityLabel("Sorgu geçmişi")
            .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
                QueryHistoryView(session: session) { isShowingHistory = false }
            }
            Menu {
                Toggle("Otomatik Commit", isOn: Binding(
                    get: { session.autoCommit },
                    set: { enabled in
                        session.setAutoCommit(enabled)
                        store.updateDatabaseConfig(session.config, in: project)
                    }
                ))
                Divider()
                Button("Yeniden Bağlan") { session.update(session.config) }
                Button("Bağlantı Ayarları…") { isEditingConnection = true }
                Divider()
                Button("Bağlantıyı Kapat") {
                    if session.confirmClosing() { session.disconnect() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Diğer işlemler")
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    private var transactionControls: some View {
        HStack(spacing: 4) {
            Text(session.autoCommit ? "İşlem açık" : "İşlem açık (elle commit)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .help("Değişiklikler commit edilene kadar başka bağlantılar tarafından görülmez.")
            Button("Commit") { session.commit() }
                .disabled(session.isRunning)
            Button("Geri Al") { session.rollback() }
                .disabled(session.isRunning)
                .help("ROLLBACK")
        }
        .labelStyle(.titleOnly)
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f sn", seconds) : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private var statusHelp: String {
        switch session.state {
        case .connected: "Bağlı"
        case .connecting: "Bağlanıyor…"
        case .failed(let message): "Bağlanamadı: \(message)"
        case .disconnected: "Bağlı değil"
        }
    }
}

private struct SchemaSidebar: View {
    @Bindable var session: DatabaseSession

    var body: some View {
        VStack(spacing: 0) {
            switch session.state {
            case .connected:
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tablo ara", text: $session.tableFilter)
                        .textFieldStyle(.plain)
                    Button {
                        Task { await session.reloadSchema() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Şemayı yenile")
                    .accessibilityLabel("Şemayı yenile")
                }
                .font(.system(size: 12))
                .padding(8)
                Divider()
                tableList
            case .connecting:
                ProgressView("Bağlanıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Bağlanamadı", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Tekrar Dene") { session.connect() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .disconnected:
                ContentUnavailableView {
                    Label("Bağlı değil", systemImage: "cylinder")
                } actions: {
                    Button("Bağlan") { session.connect() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var tableList: some View {
        let tables = session.filteredTables
        let schemas = Array(Set(tables.map(\.schema))).sorted { lhs, rhs in
            // Keep the server's order (public / current database first).
            (tables.firstIndex { $0.schema == lhs } ?? 0) < (tables.firstIndex { $0.schema == rhs } ?? 0)
        }
        return List {
            if tables.isEmpty {
                Text(session.tableFilter.isEmpty ? "Tablo yok" : "Eşleşen tablo yok")
                    .foregroundStyle(.secondary)
            }
            ForEach(schemas, id: \.self) { schema in
                Section(schemas.count > 1 ? schema : "") {
                    ForEach(tables.filter { $0.schema == schema }) { table in
                        TableRow(table: table, session: session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct TableRow: View {
    let table: SchemaTable
    let session: DatabaseSession

    var body: some View {
        Label(table.name, systemImage: table.isView ? "eye" : "tablecells")
            .lineLimit(1)
            .help(table.isView ? "Görünüm (view): \(table.id)" : "Tablo: \(table.id) — tıkla: satırları göster")
            .contentShape(Rectangle())
            .onTapGesture { session.showRows(of: table) }
            .contextMenu {
                Button("Satırları Göster") { session.showRows(of: table) }
                Button("Yapıyı Göster") { session.showStructure(of: table) }
                Divider()
                Button("Adını Editöre Ekle") { session.insert(session.dialect.identifier(table.name)) }
                Button("SELECT Yaz") {
                    let columns = session.schema.columns(of: table).map { session.dialect.identifier($0.name) }
                    let list = columns.isEmpty ? "*" : columns.joined(separator: ", ")
                    let name = session.dialect == .sqlite ? session.dialect.identifier(table.name)
                        : session.dialect.identifier(table.schema) + "." + session.dialect.identifier(table.name)
                    session.insert("SELECT \(list)\nFROM \(name)\nLIMIT 100;\n")
                }
                Button("Adını Kopyala") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.name, forType: .string)
                }
            }
    }
}

private struct ResultsPane: View {
    @Bindable var session: DatabaseSession

    var body: some View {
        VStack(spacing: 0) {
            if session.results.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(session.results) { item in
                            ResultChip(item: item, isSelected: item.id == session.selectedResult?.id) {
                                session.selectedResultID = item.id
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                Divider()
            }
            if let item = session.selectedResult {
                content(for: item)
            } else if session.isRunning {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "tablecells", tint: Color(hex: 0x00A8A8), title: "Sonuç yok",
                           message: "⌘↩ imlecin bulunduğu ifadeyi (ya da seçimi), ⇧⌘↩ bütün ifadeleri çalıştırır. Soldan bir tabloya tıklayınca satırları gelir; çift tıklayıp düzenleyebilirsin.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for item: DatabaseSession.ResultItem) -> some View {
        if let error = item.error {
            ScrollView {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        if item.errorLocation != nil {
                            Button("Hatanın Yerine Git") { session.goToError(item) }
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = item.plan {
            QueryPlanView(plan: plan)
        } else if let result = item.result {
            if item.isBrowse, let browse = session.browse {
                BrowseToolbar(session: session, browse: browse)
                Divider()
                ResultGridView(result: result, browsing: browsing(for: result))
                if !session.edits.isEmpty {
                    Divider()
                    EditsBar(session: session)
                }
                Divider()
                footer(browse.rangeText(shownRows: result.rows.count) + (session.browsePrimaryKey.isEmpty ? readOnlyReason(browse) : ""),
                       duration: item.duration)
            } else if result.returnsRows {
                ResultGridView(result: result)
                Divider()
                footer(rowsText(result), duration: item.duration)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.green)
                    Text(result.affectedRows.map { "\($0) satır etkilendi" } ?? "Tamamlandı")
                    Text(item.title).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer("", duration: item.duration)
            }
        }
    }

    private func readOnlyReason(_ browse: TableBrowse) -> String {
        browse.table.isView ? " · görünüm, salt okunur" : " · birincil anahtar yok, salt okunur"
    }

    private func browsing(for result: QueryResult) -> GridBrowsing {
        let browse = session.browse
        let keys = session.browsePrimaryKey
        let types = Dictionary(session.browseColumns.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        let editable = keys.isEmpty ? Set<Int>() : Set(result.columns.indices.filter { index in
            TableEditSQL.isEditable(nil, type: types[result.columns[index]] ?? "")
        })
        return GridBrowsing(
            edits: session.edits,
            editableColumns: editable,
            keyColumns: keys,
            sortColumn: browse?.sortColumn,
            sortDescending: browse?.sortDescending ?? false,
            incomingKeys: session.incomingKeys(),
            outgoingKey: { session.foreignKey(forColumn: $0) },
            onSort: { column in session.updateBrowse { $0.toggleSort(column) } },
            onSet: { session.setCell(row: $0, column: $1, value: $2) },
            onDelete: { session.deleteRows($0) },
            onAddRow: { session.addRow() },
            onRevert: { session.revertRows($0) },
            onFollow: { session.follow($0, value: $1, outgoing: $2) }
        )
    }

    private func rowsText(_ result: QueryResult) -> String {
        if result.isTruncated { return "İlk \(result.rows.count) satır gösteriliyor (daha fazlası var — LIMIT ekleyebilirsin)" }
        return "\(result.rows.count) satır"
    }

    private func footer(_ text: String, duration: TimeInterval) -> some View {
        HStack {
            Text(text)
            Spacer()
            Text(duration < 1 ? "\(Int(duration * 1000)) ms" : String(format: "%.2f sn", duration))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }
}

/// WHERE filter, paging and "add row" above a browsed table.
private struct BrowseToolbar: View {
    let session: DatabaseSession
    let browse: TableBrowse
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("WHERE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("ör. status = 'active' AND id > 10", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(apply)
            if !browse.filter.isEmpty {
                Button {
                    filter = ""
                    apply()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .help("Filtreyi kaldır")
                .accessibilityLabel("Filtreyi kaldır")
            }
            Divider().frame(height: 14)
            if !session.browsePrimaryKey.isEmpty {
                Button {
                    session.addRow()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Satır ekle")
                .accessibilityLabel("Satır ekle")
            }
            Button {
                session.updateBrowse { $0.totalCount = nil }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Yenile")
            .accessibilityLabel("Yenile")
            Button {
                session.updateBrowse { $0.offset = max(0, $0.offset - $0.pageSize) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browse.hasPreviousPage)
            .help("Önceki sayfa")
            .accessibilityLabel("Önceki sayfa")
            Button {
                session.updateBrowse { $0.offset += $0.pageSize }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browse.hasNextPage(shownRows: session.selectedResult?.result?.rows.count ?? 0))
            .help("Sonraki sayfa")
            .accessibilityLabel("Sonraki sayfa")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .onAppear { filter = browse.filter }
        .onChange(of: browse.table) { filter = browse.filter }
        .onChange(of: browse.filter) { filter = browse.filter }
    }

    private func apply() {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != browse.filter else { return }
        session.updateBrowse {
            $0.filter = text
            $0.offset = 0
            $0.totalCount = nil
        }
    }
}

/// Unsaved grid edits: what they are and Save / Discard.
private struct EditsBar: View {
    let session: DatabaseSession
    @State private var isShowingSQL = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
            Text("\(session.edits.count) değişiklik kaydedilmedi")
            Spacer()
            Button("SQL'i Göster") { isShowingSQL.toggle() }
                .popover(isPresented: $isShowingSQL, arrowEdge: .top) {
                    ScrollView {
                        Text(session.editStatements().map { $0 + ";" }.joined(separator: "\n"))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(width: 560, height: 220)
                }
            Button("Geri Al") { session.discardEdits() }
            Button("Kaydet") { session.saveEdits() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isRunning)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.orange.opacity(0.08))
    }
}

/// Statements run on this connection, searchable; click to put one in the editor.
private struct QueryHistoryView: View {
    let session: DatabaseSession
    let dismiss: () -> Void
    @State private var query = ""
    @State private var source = Source.all

    /// Whose queries the list shows.
    enum Source: Hashable {
        case all, agents, mine
    }

    var body: some View {
        let entries = session.history.search(query).filter { entry in
            switch source {
            case .all: true
            case .agents: entry.agent != nil
            case .mine: entry.agent == nil
            }
        }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Geçmişte ara", text: $query)
                    .textFieldStyle(.plain)
                Picker("Kimin", selection: $source) {
                    Text("Hepsi").tag(Source.all)
                    Text("Ajanlar").tag(Source.agents)
                    Text("Benim").tag(Source.mine)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            .padding(8)
            Divider()
            if entries.isEmpty {
                Text(query.isEmpty && source == .all ? "Henüz sorgu çalıştırılmadı" : "Eşleşen sorgu yok")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            session.insertFromHistory(entry)
                            dismiss()
                        }
                        .contextMenu {
                            Button("Editöre Ekle") {
                                session.insertFromHistory(entry)
                                dismiss()
                            }
                            Button("Çalıştır") {
                                session.run([DatabaseSession.Statement(sql: entry.sql)])
                                dismiss()
                            }
                            Button("Kopyala") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.sql, forType: .string)
                            }
                            Divider()
                            Button("Geçmişten Sil") { session.history.remove(entry) }
                        }
                }
                .listStyle(.plain)
            }
            Divider()
            HStack {
                Text("\(session.history.entries.count) sorgu")
                Spacer()
                Button("Geçmişi Temizle") { session.history.clear() }
                    .disabled(session.history.entries.isEmpty)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
        .frame(width: 560, height: 440)
        .onAppear { session.history.loadIfNeeded() }
    }
}

private struct HistoryRow: View {
    let entry: QueryHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.sql.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(3)
            HStack(spacing: 8) {
                if let agent = entry.agent {
                    Label(agent, systemImage: "sparkle")
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .help("Bu sorguyu \(agent) çalıştırdı")
                }
                if entry.error != nil {
                    Label("hata", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .help(entry.error ?? "")
                } else if let rows = entry.rowCount {
                    Text("\(rows) satır")
                }
                Text(entry.duration < 1 ? "\(Int(entry.duration * 1000)) ms" : String(format: "%.2f sn", entry.duration))
                Spacer()
                Text(entry.date, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
    }
}

private struct ResultChip: View {
    let item: DatabaseSession.ResultItem
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(item.error != nil ? .red : .secondary)
                Text(item.title)
                    .lineLimit(1)
                    .frame(maxWidth: 220)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private var symbol: String {
        if item.error != nil { return "xmark.octagon.fill" }
        if item.plan != nil { return "list.bullet.indent" }
        return item.result?.returnsRows == true ? "tablecells" : "checkmark"
    }
}

private struct SQLEditorRepresentable: NSViewControllerRepresentable {
    let controller: TextViewController
    let theme: EditorTheme

    func makeNSViewController(context: Context) -> TextViewController {
        DispatchQueue.main.async { [controller] in
            controller.view.window?.makeFirstResponder(controller.textView)
        }
        return controller
    }

    func updateNSViewController(_ controller: TextViewController, context: Context) {
        if controller.configuration.appearance.theme != theme {
            controller.configuration.appearance.theme = theme
        }
    }
}
