import XCTest
import GitEngine
@testable import GraphLayout

final class GraphLayoutTests: XCTestCase {
    private func commit(_ id: String, parents: [String] = []) -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: parents, authorName: "a", authorEmail: "a@x", authorDate: date, committerName: "c", committerEmail: "c@x", committerDate: date, subject: id, body: "")
    }

    private func layout(_ commits: [Commit]) -> GraphLayout {
        var layout = GraphLayout()
        layout.append(contentsOf: commits)
        return layout
    }

    private func edges(_ row: GraphRow, _ kind: EdgeKind) -> [GraphEdge] {
        row.edges.filter { $0.kind == kind }
    }

    func testLinearHistoryStaysInLaneZero() {
        let layout = layout([commit("C", parents: ["B"]), commit("B", parents: ["A"]), commit("A")])
        XCTAssertEqual(layout.rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(layout.rows[0].edges, [GraphEdge(fromLane: 0, toLane: 0, kind: .straight, color: 0)])
        XCTAssertEqual(layout.rows[1].edges, [GraphEdge(fromLane: 0, toLane: 0, kind: .straight, color: 0)])
        XCTAssertTrue(layout.rows[2].edges.isEmpty)
        XCTAssertEqual(layout.maxLaneCount, 1)
        XCTAssertEqual(Set(layout.rows.map(\.color)).count, 1)
    }

    func testBranchAndMerge() {
        let layout = layout([
            commit("D", parents: ["B", "C"]),
            commit("C", parents: ["A"]),
            commit("B", parents: ["A"]),
            commit("A"),
        ])
        let d = layout.rows[0], c = layout.rows[1], b = layout.rows[2], a = layout.rows[3]

        XCTAssertEqual(d.lane, 0)
        XCTAssertTrue(d.isMerge)
        XCTAssertEqual(d.edges, [
            GraphEdge(fromLane: 0, toLane: 0, kind: .straight, color: 0),
            GraphEdge(fromLane: 0, toLane: 1, kind: .toParent, color: 1),
        ])

        XCTAssertEqual(c.lane, 1)
        XCTAssertEqual(c.color, 1)
        XCTAssertEqual(edges(c, .passThrough), [GraphEdge(fromLane: 0, toLane: 0, kind: .passThrough, color: 0)])
        XCTAssertEqual(edges(c, .straight), [GraphEdge(fromLane: 1, toLane: 1, kind: .straight, color: 1)])

        XCTAssertEqual(b.lane, 0)
        XCTAssertEqual(edges(b, .passThrough), [GraphEdge(fromLane: 1, toLane: 1, kind: .passThrough, color: 1)])

        XCTAssertEqual(a.lane, 0)
        XCTAssertEqual(a.edges, [GraphEdge(fromLane: 1, toLane: 0, kind: .fromChild, color: 1)])
        XCTAssertEqual(a.laneCount, 2)
        XCTAssertEqual(layout.maxLaneCount, 2)
    }

    func testOctopusMergeOpensThreeLanes() {
        let layout = layout([
            commit("M", parents: ["A", "B", "C"]),
            commit("A"), commit("B"), commit("C"),
        ])
        let m = layout.rows[0]
        XCTAssertEqual(edges(m, .toParent).map(\.toLane), [1, 2])
        XCTAssertEqual(m.laneCount, 3)
        XCTAssertEqual(layout.rows.map(\.lane), [0, 0, 1, 2])
        XCTAssertEqual(layout.maxLaneCount, 3)
    }

    func testIndependentRootGetsOwnLane() {
        let layout = layout([
            commit("B", parents: ["A"]),
            commit("X"),
            commit("A"),
        ])
        XCTAssertEqual(layout.rows[1].lane, 1)
        XCTAssertNotEqual(layout.rows[1].color, layout.rows[0].color)
        XCTAssertEqual(edges(layout.rows[1], .passThrough).map(\.fromLane), [0])
        XCTAssertEqual(layout.rows[2].lane, 0)
        XCTAssertEqual(layout.rows[2].laneCount, 1)
    }

    func testFreedLaneIsReused() {
        let layout = layout([
            commit("M", parents: ["A", "F"]),
            commit("F"),
            commit("A", parents: ["Z"]),
            commit("N", parents: ["Z", "G"]),
            commit("G"),
            commit("Z"),
        ])
        XCTAssertEqual(layout.rows[1].lane, 1)
        XCTAssertEqual(layout.rows[1].laneCount, 2)
        XCTAssertEqual(layout.rows[2].laneCount, 1)
        XCTAssertEqual(layout.rows[3].lane, 1)
        XCTAssertEqual(layout.rows[4].lane, 2)
        XCTAssertEqual(layout.rows[5].lane, 0)
        XCTAssertEqual(layout.rows[5].edges, [GraphEdge(fromLane: 1, toLane: 0, kind: .fromChild, color: layout.rows[3].color)])
        XCTAssertEqual(layout.maxLaneCount, 3)
    }

    func testChildrenWaitingForSameParentCollapse() {
        let layout = layout([
            commit("B", parents: ["A"]),
            commit("C", parents: ["A"]),
            commit("D", parents: ["A"]),
            commit("A"),
        ])
        XCTAssertEqual(layout.rows.map(\.lane), [0, 1, 2, 0])
        let a = layout.rows[3]
        XCTAssertEqual(a.edges.map(\.kind), [.fromChild, .fromChild])
        XCTAssertEqual(a.edges.map(\.fromLane), [1, 2])
        XCTAssertEqual(a.edges.map(\.toLane), [0, 0])
        XCTAssertEqual(a.laneCount, 3)
    }

    func testMergeIntoExistingStrandReusesItsLane() {
        let layout = layout([
            commit("C", parents: ["B"]),
            commit("M", parents: ["X", "B"]),
            commit("B"),
            commit("X"),
        ])
        let m = layout.rows[1]
        XCTAssertEqual(m.lane, 1)
        XCTAssertEqual(edges(m, .toParent), [GraphEdge(fromLane: 1, toLane: 0, kind: .toParent, color: 0)])
        XCTAssertEqual(layout.maxLaneCount, 2)
    }

    func testPinnedCommitOwnsLaneZeroBelowNewerBranches() {
        // feature (F2, F1) is ahead of the checked-out commit M2; an unrelated tip X sits on top.
        var layout = GraphLayout(pinned: "M2")
        layout.append(contentsOf: [commit("X", parents: ["M1"]), commit("F2", parents: ["F1"]), commit("F1", parents: ["M2"]), commit("M2", parents: ["M1"]), commit("M1")])
        let rows = layout.rows
        XCTAssertEqual(rows.map(\.lane), [1, 2, 2, 0, 0])
        XCTAssertEqual(rows[3].color, 0)
        XCTAssertEqual(edges(rows[3], .fromChild).map(\.fromLane), [2], "the child strand joins the pinned commit from its own lane")
        for row in rows[0..<3] {
            XCTAssertFalse(row.edges.contains { $0.fromLane == 0 || $0.toLane == 0 }, "nothing is drawn in the held lane above the pinned commit")
        }
        XCTAssertEqual(edges(rows[4], .fromChild).map(\.fromLane), [1])
    }

    func testMergeIntoPinnedCommitMakesTheHeldLaneVisible() {
        var layout = GraphLayout(pinned: "P")
        layout.append(contentsOf: [commit("M", parents: ["A", "P"]), commit("A", parents: ["R"]), commit("P", parents: ["R"]), commit("R")])
        let rows = layout.rows
        XCTAssertEqual(edges(rows[0], .toParent).map(\.toLane), [0])
        XCTAssertEqual(edges(rows[1], .passThrough).map(\.fromLane), [0], "the merge strand keeps running down to the pinned commit")
        XCTAssertEqual(rows[2].lane, 0)
    }

    func testDuplicateCommitIsIgnored() {
        var layout = GraphLayout()
        let first = layout.append(commit("B", parents: ["A"]))
        let repeated = layout.append(commit("B", parents: ["A"]))
        layout.append(commit("A"))
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.row(for: "A")?.lane, 0)
    }

    func testDeterministicRows() {
        let commits = syntheticHistory(count: 2_000, strands: 5)
        XCTAssertEqual(layout(commits).rows, layout(commits).rows)
    }

    func testPerformanceHundredThousandCommits() {
        let commits = syntheticHistory(count: 100_000, strands: 8)
        let start = ContinuousClock.now
        let result = layout(commits)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(result.rows.count, commits.count)
        XCTAssertLessThan(result.maxLaneCount, 20)
        XCTAssertLessThan(elapsed, .seconds(3), "100k commits took \(elapsed)")
    }

    /// Deterministic history in topological order: `strands` interleaved branches that periodically
    /// merge main in and get merged back, mirroring scripts/make-synthetic-repo.sh.
    private func syntheticHistory(count: Int, strands: Int) -> [Commit] {
        var heads: [String: String] = [:]
        var commits: [Commit] = []
        commits.reserveCapacity(count)
        func add(_ branch: String, _ parents: [String], _ index: Int) {
            let id = "c\(index)"
            commits.append(commit(id, parents: parents))
            heads[branch] = id
        }
        add("main", [], 0)
        for i in 1..<count {
            let branch = i % 10 == 0 ? "main" : "feature/\(i % strands)"
            guard let head = heads[branch] else {
                add(branch, [heads["main"]!], i)
                continue
            }
            if branch != "main", i % 97 == 0 {
                add(branch, [head, heads["main"]!], i)
            } else if branch == "main", i % 500 == 0, let feature = heads["feature/\((i / 500) % strands)"] {
                add("main", [head, feature], i)
            } else {
                add(branch, [head], i)
            }
        }
        return commits.reversed()
    }
}
