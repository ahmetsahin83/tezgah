import SwiftUI

/// Claude's task list pinned above the conversation: progress at a glance, the full list on click.
struct ClaudeTodoBar: View {
    let list: ClaudeTodoList
    @State private var isExpanded = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.28, bounce: 0.1)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ProgressRing(progress: progress, isFinished: list.isFinished)
                    Text("\(list.completedCount)/\(list.items.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Listeyi gizle" : "Claude'un yapılacaklar listesi")

            if isExpanded {
                Divider().opacity(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(list.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 10, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progress: Double {
        list.items.isEmpty ? 0 : Double(list.completedCount) / Double(list.items.count)
    }

    private var headline: String {
        if let current = list.current { return current.activeTitle ?? current.title }
        if list.isFinished { return "Hepsi tamamlandı" }
        return list.items.first { $0.status == .pending }.map { "Sırada: \($0.title)" } ?? ""
    }

    private func row(_ item: ClaudeTodoList.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                switch item.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .inProgress:
                    Image(systemName: "circle.dotted.circle").foregroundStyle(Color.claudeAccent)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            Text(item.status == .inProgress ? (item.activeTitle ?? item.title) : item.title)
                .font(.system(size: 12.5, weight: item.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(item.status == .completed ? .secondary : .primary)
                .strikethrough(item.status == .completed, color: .secondary.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}

private struct ProgressRing: View {
    let progress: Double
    let isFinished: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(isFinished ? Color.green : Color.claudeAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
        .frame(width: 15, height: 15)
    }
}
