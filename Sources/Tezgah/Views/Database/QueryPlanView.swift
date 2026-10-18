import SwiftUI

/// An execution plan as an indented tree: the expensive steps get a longer bar,
/// full table scans are marked.
struct QueryPlanView: View {
    let plan: QueryPlan

    var body: some View {
        let rows = plan.flattened
        let maxCost = plan.maxCost
        VStack(spacing: 0) {
            List {
                ForEach(rows, id: \.node.id) { row in
                    PlanRow(node: row.node, depth: row.depth, maxCost: maxCost)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            if plan.planningTime != nil || plan.executionTime != nil {
                Divider()
                HStack(spacing: 16) {
                    if let planning = plan.planningTime { Text("Planlama: \(milliseconds(planning))") }
                    if let execution = plan.executionTime { Text("Çalışma: \(milliseconds(execution))") }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(.bar)
            }
        }
    }
}

private struct PlanRow: View {
    let node: QueryPlanNode
    let depth: Int
    let maxCost: Double

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    if node.isFullScan {
                        Text("tam tarama")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("Tablonun bütün satırları okunuyor. Büyük tablolarda bir indeks gerekebilir.")
                    }
                }
                ForEach(node.details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if let cost = node.cost, maxCost > 0 {
                    CostBar(fraction: cost / maxCost)
                        .help(String(format: "Maliyet: %.2f", cost))
                }
                HStack(spacing: 8) {
                    if let rows = node.estimatedRows { Text("~\(Int(rows)) satır") }
                    if let actual = node.actualRows { Text("\(Int(actual)) gerçek") }
                    if let time = node.actualTime { Text(milliseconds(time)) }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 2)
    }
}

private struct CostBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15))
            Capsule()
                .fill(fraction > 0.6 ? Color.red.opacity(0.7) : fraction > 0.25 ? Color.orange.opacity(0.7) : Color.accentColor.opacity(0.6))
                .frame(width: max(3, 90 * min(max(fraction, 0), 1)))
        }
        .frame(width: 90, height: 6)
    }
}

private func milliseconds(_ value: Double) -> String {
    value < 1 ? String(format: "%.3f ms", value) : value < 1000 ? String(format: "%.1f ms", value) : String(format: "%.2f sn", value / 1000)
}
