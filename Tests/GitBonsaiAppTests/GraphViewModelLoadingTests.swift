import GitEngine
import XCTest
@testable import GitBonsaiApp

/// Loading and refreshing a tab's view model against real repositories, without a window.
@MainActor
final class GraphViewModelLoadingTests: XCTestCase {
    private var fixture: MenuFixtureRepo!
    private var tab: TabFixture!

    override func setUp() async throws {
        fixture = try MenuFixtureRepo()
        tab = TabFixture(fixture.repo)
    }

    override func tearDown() async throws {
        tab.context.lifecycle.close()
        fixture.remove()
    }

    /// The first load reads commits of every branch, the stash as a row of its own, refs and worktrees.
    func testLoadReadsHistoryRefsStashAndWorktrees() async throws {
        try await tab.load()
        let model = tab.model
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertEqual(model.headSHA, fixture.head)
        for sha in [fixture.root, fixture.tagged, fixture.head, fixture.feature] {
            XCTAssertNotNil(model.rowIndex(of: sha), "commit \(sha) not loaded")
        }
        XCTAssertEqual(model.kinds.filter { $0 == .stash }.count, 1)
        XCTAssertTrue(Set(model.refs.map(\.name)).isSuperset(of: ["main", "feature", "other", "origin/main", "origin/feature", "v1"]))
        XCTAssertEqual(model.worktrees.count, 2)
    }

    /// A reconcile while the first load runs leaves the work to the load, which reads everything anyway.
    func testReconcileDuringTheFirstLoadDefersToIt() async throws {
        tab.model.load()
        let result = await tab.model.reconcile()
        XCTAssertEqual(result, .loading)
        try await waitUntil { !self.tab.model.isLoading }
    }

    /// A commit made outside the app shows after a refresh, as the new HEAD at the top of its branch.
    func testRefreshShowsACommitMadeOutside() async throws {
        try await tab.load()
        let outside = try fixture.repo.commit("outside", file: "outside.txt")
        await tab.model.refresh(note: nil, focus: .followHead)
        XCTAssertEqual(tab.model.headSHA, outside)
        let row = try XCTUnwrap(tab.model.rowIndex(of: outside))
        XCTAssertLessThan(row, try XCTUnwrap(tab.model.rowIndex(of: fixture.head)))
        XCTAssertEqual(tab.model.commits[row].parents, [fixture.head])
    }

    /// Commits that no ref reaches any more leave the history on a refresh, without a reload from scratch.
    func testRefreshDropsCommitsOfABranchDeletedOutside() async throws {
        try await tab.load()
        try fixture.repo.git("branch", "-D", "feature")
        try fixture.repo.git("update-ref", "-d", "refs/remotes/origin/feature")
        await tab.model.refresh(note: nil)
        XCTAssertFalse(tab.model.refs.contains { $0.name == "feature" })
        XCTAssertNil(tab.model.rowIndex(of: fixture.feature))
        XCTAssertNotNil(tab.model.rowIndex(of: fixture.root))
    }

    /// A refresh after a commit outside keeps the stash row; the stash still holds its changes.
    func testRefreshKeepsTheStashRow() async throws {
        try await tab.load()
        try fixture.repo.commit("outside", file: "outside.txt")
        await tab.model.refresh(note: nil)
        XCTAssertEqual(tab.model.kinds.filter { $0 == .stash }.count, 1)
        XCTAssertEqual(tab.model.stashes.count, 1)
    }
}
