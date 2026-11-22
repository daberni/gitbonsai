import XCTest
@testable import GitEngine
import GraphLayout

/// The decision an in-place refresh takes after a write, against the commits a fresh load had read before it.
final class HistoryRefreshTests: XCTestCase {
    private var repo: FixtureRepo!

    override func setUpWithError() throws {
        repo = try FixtureRepo(name: "refresh")
    }

    override func tearDown() {
        repo.remove()
    }

    /// The history as the app loads it: the log over all history refs plus the stash commits, without the stashes' index and untracked helper commits.
    private func loadHistory() async throws -> [Commit] {
        var options = LogOptions()
        let stashes = try await repo.repository.stashes().map(\.commitID)
        options.extraArguments = stashes
        let commits = try await repo.repository.collectLog(options)
        let helpers = Set(commits.filter { stashes.contains($0.id) }.flatMap { $0.parents.dropFirst() })
        return commits.filter { !helpers.contains($0.id) }
    }

    private func plan(after loaded: [Commit]) async throws -> HistoryRefresh {
        let repository = repo.repository
        let refs = try await repository.refs()
        let head = try await repository.status().branch.headSHA
        let stashes = try await repository.stashes().map(\.commitID)
        return HistoryRefresh.plan(loaded: loaded, tips: HistoryRefresh.tips(refs: refs, head: head, stashCommits: stashes))
    }

    func testResetDropsTheCommitNoRefReachesAnymore() async throws {
        for mode in ["--hard", "--mixed", "--soft"] {
            repo.remove()
            repo = try FixtureRepo(name: "refresh")
            let base = try repo.commit("base")
            let orphan = try repo.commit("orphan")
            let loaded = try await loadHistory()
            try repo.git("reset", "-q", mode, base)
            let plan = try await plan(after: loaded)
            XCTAssertEqual(plan, .keep(dropping: [orphan]), mode)
        }
    }

    func testResetKeepsACommitATagOrRemoteBranchStillReaches() async throws {
        let base = try repo.commit("base")
        try repo.commit("tagged")
        try repo.git("tag", "-a", "v1", "-m", "v1")
        let pushed = try repo.commit("pushed")
        try repo.git("update-ref", "refs/remotes/origin/main", pushed)
        let orphan = try repo.commit("orphan")
        let loaded = try await loadHistory()
        try repo.git("reset", "-q", "--hard", base)
        let plan = try await plan(after: loaded)
        XCTAssertEqual(plan, .keep(dropping: [orphan]))
    }

    func testDeletingABranchDropsTheCommitsOnlyItHad() async throws {
        try repo.commit("base")
        try repo.git("switch", "-q", "-c", "feature")
        let first = try repo.commit("feature 1", file: "feature.txt")
        let second = try repo.commit("feature 2", file: "feature.txt")
        try repo.git("switch", "-q", "main")
        let loaded = try await loadHistory()
        try repo.git("branch", "-q", "-D", "feature")
        let plan = try await plan(after: loaded)
        XCTAssertEqual(plan, .keep(dropping: [first, second]))
    }

    func testDroppingAStashDropsItsCommit() async throws {
        try repo.commit("base")
        try repo.write("file.txt", "changed\n")
        try repo.git("stash", "push", "-q")
        let stash = try repo.git("rev-parse", "stash@{0}")
        let loaded = try await loadHistory()
        XCTAssertTrue(loaded.contains { $0.id == stash })
        try repo.git("stash", "drop", "-q")
        let plan = try await plan(after: loaded)
        XCTAssertEqual(plan, .keep(dropping: [stash]))
    }

    /// The new commit is not loaded, so the log is read again and the pre-amend commit is no longer in it.
    func testAmendingNeedsTheLogAndLeavesThePreAmendCommitOut() async throws {
        try repo.commit("base")
        let before = try repo.commit("message")
        let loaded = try await loadHistory()
        try repo.git("commit", "-q", "--amend", "-m", "amended")
        let plan = try await plan(after: loaded)
        XCTAssertEqual(plan, .reload)
        let reloaded = try await loadHistory()
        XCTAssertFalse(reloaded.contains { $0.id == before })
    }

    func testRebaseOntoReplacesTheRewrittenCommits() async throws {
        let base = try repo.commit("base")
        try repo.git("switch", "-q", "-c", "feature")
        let old = try repo.commit("feature", file: "feature.txt")
        try repo.git("switch", "-q", "main")
        try repo.commit("main moves")
        try repo.git("switch", "-q", "feature")
        let loaded = try await loadHistory()
        try repo.git("rebase", "-q", "main")
        let plan = try await plan(after: loaded)
        XCTAssertEqual(plan, .reload)
        let reloaded = try await loadHistory()
        XCTAssertFalse(reloaded.contains { $0.id == old })
        XCTAssertTrue(reloaded.contains { $0.id == base })
    }

    func testMovingHeadToALoadedCommitKeepsEverything() async throws {
        let base = try repo.commit("base")
        try repo.commit("tip")
        let loaded = try await loadHistory()
        try repo.git("switch", "-q", "--detach", base)
        let plan = try await plan(after: loaded)
        XCTAssertEqual(plan, .keep(dropping: []))
    }
}
