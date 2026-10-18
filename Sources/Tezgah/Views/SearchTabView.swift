import SwiftUI

/// Find in project: a query with options on top, matches grouped by file below.
struct SearchTabView: View {
    @Environment(WorkspaceStore.self) private var store
    @Bindable var model: SearchModel
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Projede ara", text: $model.options.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isQueryFocused)
                        .onSubmit { model.searchNow() }
                    OptionToggle(isOn: $model.options.isCaseSensitive, label: "Aa", help: "Büyük/küçük harfe duyarlı")
                    OptionToggle(isOn: $model.options.isWholeWord, label: "ab", underlined: true, help: "Tam kelime")
                    OptionToggle(isOn: $model.options.isRegex, label: ".*", help: "Düzenli ifade (regex)")
                }
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.secondary)
                    TextField("Dosyalar (ör. *.swift, !Tests/**)", text: $model.options.include)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { model.searchNow() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
            statusBar
            Divider()

            if let error = model.error {
                ContentUnavailableView("Arama yapılamadı", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.output.files.isEmpty {
                EmptyState(symbol: "text.magnifyingglass", tint: Color(hex: 0x4C8DF6), title: emptyTitle, message: emptyDescription)
            } else {
                results
            }
        }
        .onAppear { isQueryFocused = true }
        .onChange(of: model.focusRequest) { isQueryFocused = true }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if model.isSearching {
                ProgressView().controlSize(.mini)
            }
            Text(statusText)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.output.files.isEmpty {
                Button(model.collapsedPaths.isEmpty ? "Tümünü Daralt" : "Tümünü Genişlet") {
                    model.collapsedPaths = model.collapsedPaths.isEmpty ? Set(model.output.files.map(\.path)) : []
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private var statusText: String {
        let output = model.output
        guard !model.searchedQuery.isEmpty, output.matchCount > 0 else { return model.isSearching ? "Aranıyor…" : "" }
        var text = "\(output.files.count) dosyada \(output.matchCount) sonuç"
        if output.isTruncated { text += " (ilk \(TextSearch.maxMatches) gösteriliyor)" }
        return text
    }

    private var emptyTitle: String {
        model.searchedQuery.isEmpty ? "Projede ara" : "Sonuç yok"
    }

    private var emptyDescription: String {
        if model.searchedQuery.isEmpty {
            return model.options.query.count == 1 ? "Tek harfle aramak için ↩ tuşuna bas." : "Aramak istediğin metni yaz. .gitignore'daki dosyalar atlanır."
        }
        return "“\(model.searchedQuery)” hiçbir dosyada bulunamadı."
    }

    private var results: some View {
        List {
            ForEach(model.output.files) { file in
                Section {
                    if !model.collapsedPaths.contains(file.path) {
                        ForEach(file.matches) { match in
                            MatchRow(match: match)
                                .contentShape(Rectangle())
                                .onTapGesture { open(file, match) }
                        }
                    }
                } header: {
                    FileHeader(file: file, isCollapsed: model.collapsedPaths.contains(file.path)) {
                        if model.collapsedPaths.contains(file.path) {
                            model.collapsedPaths.remove(file.path)
                        } else {
                            model.collapsedPaths.insert(file.path)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func open(_ file: TextSearch.FileResult, _ match: TextSearch.Match) {
        let url = model.rootURL.appendingPathComponent(file.path)
        let selection = match.ranges.first.map { (column: $0.location, length: $0.length) }
        // Ellipsis added in front of long lines shifts columns; fall back to the line alone.
        store.openFile(url, line: match.line, column: match.text.hasPrefix("…") ? nil : selection)
    }
}

private struct OptionToggle: View {
    @Binding var isOn: Bool
    let label: String
    var underlined = false
    let help: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underlined)
                .frame(width: 24, height: 20)
                .background(isOn ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct FileHeader: View {
    let file: TextSearch.FileResult
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
            FileTypeIcon(URL(fileURLWithPath: file.path))
            Text(name)
                .fontWeight(.medium)
            Text(folder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text("\(file.matches.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

private struct MatchRow: View {
    let match: TextSearch.Match

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(match.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 36, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
        }
    }

    private var highlighted: AttributedString {
        let text = match.text.trimmingLeadingWhitespace()
        let trimmed = (match.text as NSString).length - (text as NSString).length
        let attributed = NSMutableAttributedString(string: text)
        for range in match.ranges {
            let shifted = NSRange(location: range.location - trimmed, length: range.length)
            guard shifted.location >= 0, NSMaxRange(shifted) <= attributed.length else { continue }
            attributed.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35),
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            ], range: shifted)
        }
        return (try? AttributedString(attributed, including: \.appKit)) ?? AttributedString(text)
    }
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
