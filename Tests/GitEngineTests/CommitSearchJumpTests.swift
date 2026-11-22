import Foundation
import XCTest
@testable import GitEngine

final class CommitSearchJumpTests: XCTestCase {
    private func commit(_ id: String, subject: String) -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: [], authorName: "Ada", authorEmail: "ada@example.com", authorDate: date, committerName: "Ada", committerEmail: "ada@example.com", committerDate: date, subject: subject, body: "")
    }

    func testJumpsToTheTopmostMatchOnce() throws {
        let search = try XCTUnwrap(CommitSearch("parser"))
        var jump = CommitSearchJump(search: search, refines: true, selected: commit("c1", subject: "Update docs"))
        XCTAssertEqual(jump.target(among: ["c5", "c9"]), "c5")
        XCTAssertNil(jump.target(among: ["c20"]), "matches streaming in later keep the chosen row")
    }

    func testWithoutSelectionJumpsToo() throws {
        var jump = CommitSearchJump(search: try XCTUnwrap(CommitSearch("parser")), refines: true, selected: nil)
        XCTAssertEqual(jump.target(among: ["c3"]), "c3")
    }

    /// Refining "pars" to "parser" while a lower match is selected keeps that row instead of going back up.
    func testRefiningKeepsASelectionThatStillMatches() throws {
        let selected = commit("c40", subject: "Fix the parser")
        var jump = CommitSearchJump(search: try XCTUnwrap(CommitSearch("parser")), refines: true, selected: selected)
        XCTAssertNil(jump.target(among: ["c2", "c40"]))
    }

    /// Typing the first character of a new search jumps even when the selected row matches it.
    func testANewSearchJumpsEvenFromAMatchingSelection() throws {
        var jump = CommitSearchJump(search: try XCTUnwrap(CommitSearch("c")), refines: false, selected: commit("c40", subject: "Fix the parser"))
        XCTAssertEqual(jump.target(among: ["c1", "c40"]), "c1")
    }

    func testSelectionMatchingOnlyByRefNameIsKept() throws {
        var jump = CommitSearchJump(search: try XCTUnwrap(CommitSearch("release")), refines: true, selected: commit("c7", subject: "Bump"), refNames: ["release/2.0"])
        XCTAssertNil(jump.target(among: ["c1"]))
    }

    /// The first chunks of a large history can hold no match; the jump waits for the first one found.
    func testWaitsThroughChunksWithoutMatches() throws {
        var jump = CommitSearchJump(search: try XCTUnwrap(CommitSearch("parser")), refines: true, selected: commit("c1", subject: "Update docs"))
        XCTAssertNil(jump.target(among: []))
        XCTAssertTrue(jump.isPending)
        XCTAssertEqual(jump.target(among: ["c30001"]), "c30001")
    }

    func testAUserChoiceEndsTheJump() throws {
        var jump = CommitSearchJump(search: try XCTUnwrap(CommitSearch("parser")), refines: true, selected: nil)
        jump.cancel()
        XCTAssertNil(jump.target(among: ["c3"]))
    }
}
