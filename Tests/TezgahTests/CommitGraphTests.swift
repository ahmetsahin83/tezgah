import Foundation
import Testing
@testable import Tezgah

@Suite struct CommitGraphTests {
    private func commit(_ hash: String, _ parents: [String]) -> GitCommit {
        GitCommit(hash: hash, shortHash: hash, author: "a", date: .now, subject: hash, refs: [], parents: parents)
    }

    @Test func straightHistoryIsOneLane() {
        let graph = CommitGraph([commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        #expect(graph.rows.map(\.column) == [0, 0, 0])
        #expect(graph.maxWidth == 1)
        // The tip has no line above it, the root none below.
        #expect(!graph.rows[0].lines.contains { $0.half == .top })
        #expect(!graph.rows[2].lines.contains { $0.half == .bottom })
    }

    @Test func branchForksAndMergesBack() {
        // m merges b into a; both come from c.
        let graph = CommitGraph([commit("m", ["a", "b"]), commit("b", ["c"]), commit("a", ["c"]), commit("c", [])])
        let m = graph.rows[0], b = graph.rows[1], a = graph.rows[2], c = graph.rows[3]
        #expect(m.column == 0)
        #expect(m.lines.contains(.init(half: .bottom, from: 0, to: 1, color: 1))) // fork to the second parent
        #expect(b.column == 1 && b.color == 1)
        #expect(a.column == 0 && a.color == 0)
        #expect(c.column == 0)
        #expect(c.lines.contains(.init(half: .top, from: 1, to: 0, color: 1))) // the branch joins its base
        #expect(graph.maxWidth == 2)
    }

    @Test func twoTipsGetTheirOwnLanes() {
        // Local main and an incoming upstream commit on top of the same base.
        let graph = CommitGraph([commit("up", ["base"]), commit("local", ["base"]), commit("base", [])])
        #expect(graph.rows.map(\.column) == [0, 1, 0])
        #expect(graph.rows[1].color != graph.rows[0].color)
    }
}
