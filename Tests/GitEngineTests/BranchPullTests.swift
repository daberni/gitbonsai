import XCTest
@testable import GitEngine

/// Pulling a local branch that is not checked out in the working tree, against a local bare remote.
final class BranchPullTests: XCTestCase {
    /// `local` has main checked out and a `feature` branch that tracks origin/feature; `other` moves the remote's feature on its own.
    private struct Setup {
        let remote: FixtureRepo
        let local: FixtureRepo
        let other: FixtureRepo
        var bare: String { remote.path + "/bare.git" }

        func remove() { [remote, local, other].forEach { $0.remove() } }

        /// A new commit on the remote's feature branch, pushed from `other`.
        @discardableResult
        func advanceRemoteFeature(_ message: String = "theirs") throws -> String {
            try other.git("switch", "-q", "feature")
            let sha = try other.commit(message, file: "\(message).txt")
            try other.git("push", "-q", "origin", "feature")
            return sha
        }
    }

    private func makeSetup() throws -> Setup {
        let remote = try FixtureRepo(name: "remote")
        try remote.commit("base")
        try remote.git("branch", "feature")
        let bare = remote.path + "/bare.git"
        try remote.git("clone", "-q", "--bare", remote.path, bare)
        let local = try FixtureRepo(name: "local")
        let other = try FixtureRepo(name: "other")
        for clone in [local, other] {
            try clone.git("remote", "add", "origin", bare)
            try clone.git("fetch", "-q", "origin")
            try clone.git("reset", "-q", "--hard", "origin/main")
            try clone.git("branch", "-q", "--set-upstream-to=origin/main", "main")
            try clone.git("branch", "-q", "--track", "feature", "origin/feature")
        }
        return Setup(remote: remote, local: local, other: other)
    }

    func testFastForwardsABranchThatIsCheckedOutNowhere() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        let head = try setup.local.git("rev-parse", "HEAD")
        let theirs = try setup.advanceRemoteFeature()

        let result = try await setup.local.repository.fastForwardBranch("feature")

        XCTAssertEqual(result.place, .ref)
        XCTAssertEqual(result.outcome, .fastForwarded(commits: 1))
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), theirs)
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/remotes/origin/feature"), theirs, "the fetch updates the remote-tracking branch too")
        XCTAssertEqual(try setup.local.git("rev-parse", "HEAD"), head)
        XCTAssertEqual(try setup.local.git("symbolic-ref", "--short", "HEAD"), "main")
    }

    func testPullsABranchCheckedOutInALinkedWorktreeInsideThatWorktree() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        let worktree = setup.local.path + "-feature"
        try setup.local.git("worktree", "add", "-q", worktree, "feature")
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        let theirs = try setup.advanceRemoteFeature()

        let result = try await setup.local.repository.fastForwardBranch("feature")

        guard case .worktree(let path) = result.place else { return XCTFail("expected the worktree, got \(result.place)") }
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path)
        XCTAssertEqual(result.outcome, .fastForwarded(commits: 1))
        XCTAssertTrue(result.commandLine.contains("pull --no-rebase --ff-only"), result.commandLine)
        // The worktree's files moved with the branch, which a bare ref update would not do.
        XCTAssertEqual(try FixtureRepo(existing: URL(fileURLWithPath: worktree)).git("rev-parse", "HEAD"), theirs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/theirs.txt"))
        XCTAssertEqual(try setup.local.git("status", "--porcelain", "--untracked-files=no"), "")
    }

    func testRefusesADivergedBranchAndReportsBothCounts() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        try setup.advanceRemoteFeature("one")
        try setup.advanceRemoteFeature("two")
        try setup.local.git("switch", "-q", "feature")
        let mine = try setup.local.commit("mine", file: "mine.txt")
        try setup.local.git("switch", "-q", "main")

        let result = try await setup.local.repository.fastForwardBranch("feature")

        XCTAssertEqual(result.outcome, .diverged(ahead: 1, behind: 2))
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), mine)
        XCTAssertEqual(try setup.local.git("rev-list", "--merges", "--count", "refs/heads/feature"), "0")
    }

    func testRefusesADivergedBranchInALinkedWorktree() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        try setup.advanceRemoteFeature()
        let worktree = setup.local.path + "-feature"
        try setup.local.git("worktree", "add", "-q", worktree, "feature")
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        let mine = try FixtureRepo(existing: URL(fileURLWithPath: worktree)).commit("mine", file: "mine.txt")

        let result = try await setup.local.repository.fastForwardBranch("feature")

        XCTAssertEqual(result.outcome, .diverged(ahead: 1, behind: 1))
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), mine)
    }

    func testABranchWithNothingNewIsUpToDateAlsoWhenItIsAhead() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        let before = try setup.local.git("rev-parse", "refs/heads/feature")
        let unchanged = try await setup.local.repository.fastForwardBranch("feature")
        XCTAssertEqual(unchanged.outcome, .upToDate(ahead: 0))
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), before)

        try setup.local.git("switch", "-q", "feature")
        let mine = try setup.local.commit("mine", file: "mine.txt")
        try setup.local.git("switch", "-q", "main")
        let ahead = try await setup.local.repository.fastForwardBranch("feature")
        XCTAssertEqual(ahead.outcome, .upToDate(ahead: 1))
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), mine, "a branch ahead of its upstream must not be rewound")
    }

    func testABranchWithoutUpstreamIsRefused() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        try setup.local.git("branch", "-q", "loose")
        do {
            _ = try await setup.local.repository.fastForwardBranch("loose")
            XCTFail("a branch without upstream has nothing to pull")
        } catch let error as BranchPullError {
            XCTAssertEqual(error, .noUpstream(branch: "loose"))
        }
    }

    func testTheCheckedOutBranchIsLeftToTheNormalPull() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        let place = try await setup.local.repository.pullPlace(of: "main")
        XCTAssertEqual(place, .current)
        do {
            _ = try await setup.local.repository.fastForwardBranch("main")
            XCTFail("the current branch must go through the normal pull")
        } catch let error as BranchPullError {
            XCTAssertEqual(error, .isCurrentBranch(branch: "main"))
        }
        // Seen from a linked worktree, main is checked out elsewhere and feature is the current branch.
        let worktree = setup.local.path + "-feature"
        try setup.local.git("worktree", "add", "-q", worktree, "feature")
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        let linked = Repository(path: worktree)
        let current = try await linked.pullPlace(of: "feature")
        let elsewhere = try await linked.pullPlace(of: "main")
        XCTAssertEqual(current, .current)
        guard case .worktree = elsewhere else { return XCTFail("main is checked out in the main worktree, got \(elsewhere)") }
    }

    func testResetToUpstreamDropsLocalCommitsOnlyWhenTheBranchHasNotMoved() async throws {
        let setup = try makeSetup()
        defer { setup.remove() }
        let theirs = try setup.advanceRemoteFeature()
        try setup.local.git("switch", "-q", "feature")
        let mine = try setup.local.commit("mine", file: "mine.txt")
        try setup.local.git("switch", "-q", "main")
        _ = try await setup.local.repository.fastForwardBranch("feature")

        do {
            try await setup.local.repository.resetBranchToUpstream("feature", expecting: theirs)
            XCTFail("a stale expected position must refuse the reset")
        } catch is GitError {}
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), mine)

        try await setup.local.repository.resetBranchToUpstream("feature", expecting: mine)
        XCTAssertEqual(try setup.local.git("rev-parse", "refs/heads/feature"), theirs)
    }
}
