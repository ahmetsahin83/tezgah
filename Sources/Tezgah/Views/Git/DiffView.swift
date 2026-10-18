import AppKit
import CodeEditSourceEditor
import SwiftUI

struct DiffView: View {
    let diff: ParsedDiff
    @Environment(\.colorScheme) private var colorScheme

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    static let numberWidth: CGFloat = 44
    static let markerWidth: CGFloat = 18

    var body: some View {
        if diff.lines.isEmpty {
            ContentUnavailableView("Fark yok", systemImage: "equal", description: Text("Gösterilecek bir değişiklik yok."))
        } else {
            GeometryReader { geometry in
                let contentWidth = Self.numberWidth * 2 + Self.markerWidth + CGFloat(diff.longestLine) * Self.characterWidth + 24
                let rowWidth = max(geometry.size.width, contentWidth)
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let theme = EditorThemes.theme(for: colorScheme)
                        ForEach(diff.lines) { line in
                            DiffLineRow(line: line, spans: diff.highlights[line.id], theme: theme)
                                .frame(width: rowWidth, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let spans: [DiffSpan]?
    let theme: EditorTheme

    var body: some View {
        switch line.kind {
        case .fileHeader:
            Text(line.text)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) { Divider() }
        case .hunkHeader:
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
        case .info:
            Text(line.text)
                .font(.system(size: 11))
                .italic()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
        case .context, .addition, .deletion:
            HStack(spacing: 0) {
                lineNumber(line.oldNumber)
                lineNumber(line.newNumber)
                Text(marker)
                    .foregroundStyle(markerColor)
                    .frame(width: DiffView.markerWidth)
                Text(styledText)
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
    }

    /// The line's code with syntax colors from the editor theme.
    private var styledText: AttributedString {
        var styled = AttributedString(line.text)
        guard let spans else { return styled }
        styled.foregroundColor = Color(nsColor: theme.text.color)
        for span in spans {
            let text = line.text
            let lower = String.Index(utf16Offset: span.range.lowerBound, in: text)
            let upper = String.Index(utf16Offset: span.range.upperBound, in: text)
            guard let range = Range(lower..<upper, in: styled) else { continue }
            let attribute = EditorThemes.attribute(for: span.capture, in: theme)
            styled[range].foregroundColor = Color(nsColor: attribute.color)
            if attribute.bold {
                styled[range].inlinePresentationIntent = .stronglyEmphasized
            } else if attribute.italic {
                styled[range].inlinePresentationIntent = .emphasized
            }
        }
        return styled
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: DiffView.numberWidth - 6, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: " "
        }
    }

    private var markerColor: Color {
        line.kind == .addition ? .green : .red
    }

    private var background: Color {
        switch line.kind {
        case .addition: Color.green.opacity(0.14)
        case .deletion: Color.red.opacity(0.14)
        default: .clear
        }
    }
}
