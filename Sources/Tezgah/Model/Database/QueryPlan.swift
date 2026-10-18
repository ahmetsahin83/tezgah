import Foundation

/// One step of an execution plan.
struct QueryPlanNode: Identifiable, Equatable {
    var id = UUID()
    /// "Seq Scan on users u", "Hash Join", "SCAN orders"…
    var title: String
    var details: [String] = []
    /// The planner's total cost (Postgres) or estimated rows (MySQL), for comparing steps.
    var cost: Double?
    var estimatedRows: Double?
    /// EXPLAIN ANALYZE: milliseconds for all loops, and rows produced.
    var actualTime: Double?
    var actualRows: Double?
    /// Reads the whole table: usually the thing to look at first.
    var isFullScan = false
    var children: [QueryPlanNode] = []

    /// This node and everything under it, depth first, with depths.
    func flattened(depth: Int = 0) -> [(node: QueryPlanNode, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

struct QueryPlan: Equatable {
    var nodes: [QueryPlanNode]
    var planningTime: Double?
    var executionTime: Double?

    var flattened: [(node: QueryPlanNode, depth: Int)] { nodes.flatMap { $0.flattened() } }
    var maxCost: Double { flattened.compactMap(\.node.cost).max() ?? 0 }

    static func == (lhs: QueryPlan, rhs: QueryPlan) -> Bool {
        lhs.nodes == rhs.nodes && lhs.planningTime == rhs.planningTime && lhs.executionTime == rhs.executionTime
    }
}

enum QueryPlanner {
    /// The EXPLAIN statement for a query. ANALYZE (Postgres only) really runs it.
    static func explainSQL(for statement: String, dialect: DatabaseConfig.Kind, analyze: Bool) -> String {
        var body = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast() }
        switch dialect {
        case .postgres: return (analyze ? "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " : "EXPLAIN (FORMAT JSON) ") + body
        case .mysql: return "EXPLAIN " + body
        case .sqlite: return "EXPLAIN QUERY PLAN " + body
        }
    }

    static func parse(_ result: QueryResult, dialect: DatabaseConfig.Kind) -> QueryPlan? {
        switch dialect {
        case .postgres: return parsePostgres(result)
        case .mysql: return parseMySQL(result)
        case .sqlite: return parseSQLite(result)
        }
    }

    // MARK: Postgres (FORMAT JSON)

    private static func parsePostgres(_ result: QueryResult) -> QueryPlan? {
        let text = result.rows.compactMap { $0.first ?? nil }.joined(separator: "\n")
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let top = array.first, let root = top["Plan"] as? [String: Any] else { return nil }
        return QueryPlan(
            nodes: [postgresNode(root)],
            planningTime: top["Planning Time"] as? Double,
            executionTime: top["Execution Time"] as? Double
        )
    }

    private static func postgresNode(_ plan: [String: Any]) -> QueryPlanNode {
        let type = plan["Node Type"] as? String ?? "?"
        var title = type
        if let join = plan["Join Type"] as? String, type.hasSuffix("Join") || type == "Nested Loop" { title += " (\(join))" }
        if let index = plan["Index Name"] as? String { title += " using \(index)" }
        if let relation = plan["Relation Name"] as? String {
            title += " on \(relation)"
            if let alias = plan["Alias"] as? String, alias != relation { title += " \(alias)" }
        } else if let cte = plan["CTE Name"] as? String {
            title += " on \(cte)"
        }

        var details: [String] = []
        for key in ["Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter", "One-Time Filter"] {
            if let value = plan[key] as? String { details.append("\(key): \(value)") }
        }
        for key in ["Sort Key", "Group Key", "Presorted Key"] {
            if let value = plan[key] as? [String] { details.append("\(key): \(value.joined(separator: ", "))") }
        }
        if let removed = plan["Rows Removed by Filter"] as? Double, removed > 0 {
            details.append("Filtreyle elenen satır: \(Int(removed))")
        }
        if let method = plan["Sort Method"] as? String { details.append("Sort Method: \(method)") }
        if let hit = plan["Shared Hit Blocks"] as? Double, let read = plan["Shared Read Blocks"] as? Double, hit + read > 0 {
            details.append("Bloklar: \(Int(hit)) önbellekten, \(Int(read)) diskten")
        }

        let loops = plan["Actual Loops"] as? Double ?? 1
        return QueryPlanNode(
            title: title,
            details: details,
            cost: plan["Total Cost"] as? Double,
            estimatedRows: plan["Plan Rows"] as? Double,
            actualTime: (plan["Actual Total Time"] as? Double).map { $0 * loops },
            actualRows: (plan["Actual Rows"] as? Double).map { $0 * loops },
            isFullScan: type == "Seq Scan",
            children: (plan["Plans"] as? [[String: Any]] ?? []).map(postgresNode)
        )
    }

    // MARK: MySQL / MariaDB (tabular EXPLAIN)

    private static func parseMySQL(_ result: QueryResult) -> QueryPlan? {
        guard result.returnsRows else { return nil }
        let index = Dictionary(result.columns.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func value(_ row: [String?], _ name: String) -> String? {
            index[name].flatMap { row.indices.contains($0) ? row[$0] : nil }
        }
        let nodes = result.rows.map { row -> QueryPlanNode in
            let access = value(row, "type") ?? "?"
            var title = value(row, "table") ?? "(tablo yok)"
            title += " — \(access)"
            if let selectType = value(row, "select_type"), selectType != "SIMPLE" { title = "\(selectType): " + title }
            var details: [String] = []
            if let key = value(row, "key") { details.append("Anahtar: \(key)") }
            if let possible = value(row, "possible_keys") { details.append("Olası anahtarlar: \(possible)") }
            if let ref = value(row, "ref") { details.append("ref: \(ref)") }
            if let filtered = value(row, "filtered") { details.append("filtered: %\(filtered)") }
            if let extra = value(row, "extra"), !extra.isEmpty { details.append(extra) }
            let rows = value(row, "rows").flatMap(Double.init)
            return QueryPlanNode(title: title, details: details, cost: rows, estimatedRows: rows, isFullScan: access == "ALL")
        }
        return QueryPlan(nodes: nodes)
    }

    // MARK: SQLite (EXPLAIN QUERY PLAN)

    private static func parseSQLite(_ result: QueryResult) -> QueryPlan? {
        guard result.columns.count >= 4 else { return nil }
        struct Row { let id: Int; let parent: Int; let detail: String }
        let rows = result.rows.compactMap { row -> Row? in
            guard let id = row[0].flatMap(Int.init), let parent = row[1].flatMap(Int.init) else { return nil }
            return Row(id: id, parent: parent, detail: row[3] ?? "")
        }
        func children(of parent: Int) -> [QueryPlanNode] {
            rows.filter { $0.parent == parent }.map { row in
                let isScan = row.detail.hasPrefix("SCAN ") && !row.detail.contains("INDEX")
                return QueryPlanNode(title: row.detail, isFullScan: isScan, children: children(of: row.id))
            }
        }
        return QueryPlan(nodes: children(of: 0))
    }
}
