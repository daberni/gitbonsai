import XCTest
@testable import GitEngine

/// Moving to parents and children, and when the commands are disabled.
final class CommitRelativesTests: XCTestCase {
    private func commit(_ id: String, _ parents: [String]) -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: parents, authorName: "", authorEmail: "", authorDate: date, committerName: "", committerEmail: "", committerDate: date, subject: id, body: "", trailers: [])
    }

    func testOctopusParentsMarkTheFirst() {
        let parents = CommitRelatives.parents(of: commit("m", ["a", "b", "c"]))
        XCTAssertEqual(parents.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(parents.map(\.isFirstParent), [true, false, false])
    }

    func testChildrenAreTheLoadedCommitsNamingItInHistoryOrder() {
        let history = [commit("m", ["x", "base"]), commit("x", ["base"]), commit("y", ["base"]), commit("base", [])]
        let children = CommitRelatives.children(of: "base", in: history)
        XCTAssertEqual(children.map(\.id), ["m", "x", "y"])
        XCTAssertEqual(children.map(\.isFirstParent), [false, true, true])
        XCTAssertEqual(CommitRelatives.children(of: "m", in: history), [])
    }

    func testRules() {
        XCTAssertEqual(CommandRules.goToParent(parentCount: nil), .noCommitSelected)
        XCTAssertEqual(CommandRules.goToParent(parentCount: 0), .rootCommit)
        XCTAssertNil(CommandRules.goToParent(parentCount: 1))
        XCTAssertNil(CommandRules.goToParent(parentCount: 3))
        XCTAssertEqual(CommandRules.goToChild(childCount: nil), .noCommitSelected)
        XCTAssertEqual(CommandRules.goToChild(childCount: 0), .noChildren)
        XCTAssertNil(CommandRules.goToChild(childCount: 2))
    }
}
