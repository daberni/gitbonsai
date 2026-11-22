import XCTest
import GitEngine
import GraphLayout

final class WorkingDirectoryRowTests: XCTestCase {
    private func commit(_ id: String, parents: [String] = []) -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: parents, authorName: "a", authorEmail: "a@x", authorDate: date, committerName: "c", committerEmail: "c@x", committerDate: date, subject: id, body: "")
    }

    /// F is a feature branch off A; M is main with B in between. Topological order: F, M, B, A.
    private var history: [Commit] {
        [commit("F", parents: ["A"]), commit("M", parents: ["B"]), commit("B", parents: ["A"]), commit("A")]
    }

    private func rows(pinned head: String?) -> [GraphRow] {
        var layout = GraphLayout(pinned: head)
        return history.map { layout.append($0) }
    }

    func testRowFollowsHeadIntoItsLaneWithAStrandThroughTheRowsAbove() {
        for head in ["F", "B"] {
            let original = rows(pinned: head)
            var rows = original
            let headIndex = rows.firstIndex { $0.commitID == head }!
            let headRow = rows[headIndex]
            let wip = WorkingDirectoryRow.insert(id: "WIP", into: &rows, headIndex: headIndex)

            XCTAssertEqual(rows.count, 5)
            XCTAssertEqual(rows[0].commitID, "WIP")
            XCTAssertEqual(rows[0].lane, headRow.lane, "head \(head)")
            XCTAssertEqual(rows[0].edges, [GraphEdge(fromLane: headRow.lane, toLane: headRow.lane, kind: .straight, color: headRow.color)])
            XCTAssertEqual(wip.lane, headRow.lane)
            XCTAssertEqual(wip.headRow, headIndex + 1)
            XCTAssertEqual(rows[wip.headRow], headRow)
            let through = GraphEdge(fromLane: headRow.lane, toLane: headRow.lane, kind: .passThrough, color: headRow.color)
            for above in 1..<wip.headRow { XCTAssertTrue(rows[above].edges.contains(through), "row \(above), head \(head)") }
            XCTAssertEqual(Array(rows[wip.headRow...]), Array(original[headIndex...]), "head \(head)")
        }
    }

    func testPinnedHeadPutsTheRowInTheLeftmostLane() {
        var rows = rows(pinned: "B")
        let wip = WorkingDirectoryRow.insert(id: "WIP", into: &rows, headIndex: 2)
        XCTAssertEqual(wip.lane, 0)
        XCTAssertEqual(rows[0].laneCount, 1)
    }

    func testRemovingRestoresTheLaidOutRows() {
        for head in ["F", "M", "B", "A"] {
            let original = rows(pinned: head)
            var rows = original
            let wip = WorkingDirectoryRow.insert(id: "WIP", into: &rows, headIndex: original.firstIndex { $0.commitID == head }!)
            wip.remove(from: &rows)
            XCTAssertEqual(rows, original, "head \(head)")
        }
    }
}
