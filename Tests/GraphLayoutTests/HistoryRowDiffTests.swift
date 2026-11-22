import XCTest
import GitEngine
import GraphLayout

final class HistoryRowDiffTests: XCTestCase {
    private func commit(_ id: String, parents: [String] = []) -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: parents, authorName: "a", authorEmail: "a@x", authorDate: date, committerName: "c", committerEmail: "c@x", committerDate: date, subject: id, body: "")
    }

    /// Main M3–M1 with a feature branch F2–F1 off M1; HEAD is M3. Topological order: F2, M3, F1, M2, M1.
    private var history: [Commit] {
        [commit("F2", parents: ["F1"]), commit("M3", parents: ["M2"]), commit("F1", parents: ["M1"]), commit("M2", parents: ["M1"]), commit("M1")]
    }

    /// Lays commits out as the history does: HEAD pinned, stashes as side strands with their base parent only.
    private func rows(_ commits: [Commit], head: String = "M3", stashes: Set<String> = []) -> [GraphRow] {
        var layout = GraphLayout(pinned: head)
        return commits.map { layout.append($0, isSideStrand: stashes.contains($0.id)) }
    }

    func testNewCommitsOnTopAreInsertedAndOnlyTheirNeighbourRedraws() {
        let old = rows(history)
        let new = rows([commit("M5", parents: ["M4"]), commit("M4", parents: ["M3"])] + history, head: "M5")
        let diff = HistoryRowDiff.between(old, new)
        XCTAssertEqual(diff?.removed, [])
        XCTAssertEqual(diff?.inserted, [0, 1])
        // F2 now has M4 above it, and M3 changed from the pinned tip to a commit with children; the rest draws as before.
        XCTAssertEqual(diff?.changed, [2, 3], "\(diff!.changed.map { new[$0].commitID })")
        XCTAssertEqual(Array(old[3...]), Array(new[5...]))
    }

    func testRemovedWorkingDirectoryRowRedrawsTheRowsItsStrandPassed() {
        let old = rows(history)
        var withWIP = old
        let wip = WorkingDirectoryRow.insert(id: "WIP", into: &withWIP, headIndex: 1)
        let diff = HistoryRowDiff.between(withWIP, old)
        XCTAssertEqual(diff?.removed, [0])
        XCTAssertEqual(diff?.inserted, [])
        // F2 loses the strand from the WIP row, M3 the row above it; everything from F1 down stays.
        XCTAssertEqual(diff?.changed, [0, 1])
        XCTAssertEqual(wip.headRow, 2)
    }

    func testStashAppearingAndDisappearingLeavesTheOtherStrandsAlone() {
        // A stash on HEAD sits right above it; here HEAD is the newest commit, F2 the older feature tip.
        let commits = [commit("M3", parents: ["M2"]), commit("F2", parents: ["F1"]), commit("M2", parents: ["M1"]), commit("F1", parents: ["M1"]), commit("M1")]
        let without = rows(commits)
        let with = rows([commit("S", parents: ["M3"])] + commits, stashes: ["S"])
        XCTAssertEqual(with[0].color, GraphLayout.sideStrandColor)
        // Below HEAD the stash's lane is free again and every row draws as before.
        XCTAssertEqual(Array(with[2...]), Array(without[1...]))

        let appeared = HistoryRowDiff.between(without, with)
        XCTAssertEqual(appeared, HistoryRowDiff(inserted: [0], changed: [1, 2]))
        let disappeared = HistoryRowDiff.between(with, without)
        XCTAssertEqual(disappeared, HistoryRowDiff(removed: [0], changed: [0, 1]))
    }

    func testStashTakesNoColorFromTheBranchesBelowIt() {
        // Without the side strand the stash took color 1 and every branch below moved one color on.
        let with = rows([commit("S", parents: ["M3"])] + history, stashes: ["S"])
        let without = rows(history)
        let colors = { (rows: [GraphRow]) in rows.filter { $0.commitID != "S" }.map(\.color) }
        XCTAssertEqual(colors(with), colors(without))
    }

    func testReorderedLanesRedrawTheRowsWhoseStrandsMoved() {
        let old = rows(history)
        // The same commits laid out around another HEAD: F2's strand takes the leftmost lane.
        let new = rows(history, head: "F2")
        let diff = HistoryRowDiff.between(old, new)
        XCTAssertEqual(diff?.removed, [])
        XCTAssertEqual(diff?.inserted, [])
        let moved = IndexSet(new.indices.filter { old[$0] != new[$0] })
        XCTAssertFalse(moved.isEmpty)
        XCTAssertTrue(diff!.changed.isSuperset(of: moved))
    }

    func testRowsThatChangeTheirOrderAskForAWholeReload() {
        let old = rows(history)
        let swapped = rows([history[1], history[0]] + history[2...])
        XCTAssertNil(HistoryRowDiff.between(old, swapped))
    }

    func testIdenticalRowsChangeNothing() {
        let old = rows(history)
        XCTAssertEqual(HistoryRowDiff.between(old, old), HistoryRowDiff())
    }
}
