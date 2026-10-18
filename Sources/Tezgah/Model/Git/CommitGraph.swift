import Foundation

/// Lanes for drawing history as a graph, the way VS Code's source control graph does: each
/// commit sits in a lane, lines run down to its parents, branches fork off and merge back.
///
/// Commits must come in topological order (children before parents), as `git log --topo-order`
/// gives them.
struct CommitGraph: Equatable {
    /// A line through one row: from a lane at the top (or middle) to a lane at the middle (or bottom).
    struct Line: Equatable {
        enum Half: Equatable { case top, bottom }
        let half: Half
        let from: Int
        let to: Int
        let color: Int
    }

    struct Row: Equatable {
        /// The commit's lane.
        let column: Int
        let color: Int
        let lines: [Line]
        /// Lanes the row spans, for its width.
        let width: Int
    }

    let rows: [Row]
    /// Widest row, for lining up the text after the graph.
    let maxWidth: Int

    init(_ commits: [GitCommit]) {
        struct Lane { let hash: String; let color: Int }
        var lanes: [Lane?] = []
        var nextColor = 0
        var rows: [Row] = []

        func freeSlot(avoiding taken: Int? = nil) -> Int {
            if let index = lanes.indices.first(where: { lanes[$0] == nil && $0 != taken }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            let before = lanes
            var lines: [Line] = []

            // The commit's lane: the first lane waiting for it, or a new one (a branch tip).
            let column: Int
            let color: Int
            if let index = lanes.firstIndex(where: { $0?.hash == commit.hash }) {
                column = index
                color = lanes[index]!.color
            } else {
                column = freeSlot()
                color = nextColor
                nextColor += 1
            }

            // Top half: lanes coming down. Those waiting for this commit join it here.
            for (index, lane) in before.enumerated() {
                guard let lane else { continue }
                if lane.hash == commit.hash {
                    lines.append(Line(half: .top, from: index, to: column, color: lane.color))
                    if index != column { lanes[index] = nil }
                } else {
                    lines.append(Line(half: .top, from: index, to: index, color: lane.color))
                }
            }

            // Bottom half: on to the parents. The first parent keeps the lane and its color.
            var startedHere: Set<Int> = []
            if let first = commit.parents.first {
                lanes[column] = Lane(hash: first, color: color)
                lines.append(Line(half: .bottom, from: column, to: column, color: color))
            } else {
                lanes[column] = nil
            }
            for parent in commit.parents.dropFirst() {
                if let index = lanes.firstIndex(where: { $0?.hash == parent }) {
                    lines.append(Line(half: .bottom, from: column, to: index, color: lanes[index]!.color))
                } else {
                    let index = freeSlot(avoiding: column)
                    lanes[index] = Lane(hash: parent, color: nextColor)
                    lines.append(Line(half: .bottom, from: column, to: index, color: nextColor))
                    startedHere.insert(index)
                    nextColor += 1
                }
            }
            for (index, lane) in lanes.enumerated() {
                guard let lane, index != column, !startedHere.contains(index) else { continue }
                lines.append(Line(half: .bottom, from: index, to: index, color: lane.color))
            }

            while lanes.last.map({ $0 == nil }) == true { lanes.removeLast() }
            rows.append(Row(column: column, color: color, lines: lines, width: max(before.count, lanes.count, column + 1)))
        }
        self.rows = rows
        maxWidth = rows.map(\.width).max() ?? 1
    }
}
