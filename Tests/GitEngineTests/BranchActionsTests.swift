import Foundation
import XCTest
@testable import GitEngine

final class BranchActionsTests: XCTestCase {
    private var fixture: FixtureRepo!

    override func setUpWithError() throws {
        fixture = try FixtureRepo()
        try fixture.commit("one")
    }

    override func tearDown() {
        fixture.remove()
    }

    private func branchExists(_ name: String) -> Bool {
        (try? fixture.git("rev-parse", "--verify", "-q", "refs/heads/\(name)")) != nil
    }

    /// A bare repository as `origin`, with main pushed and tracked.
    private func addOrigin() throws -> FixtureRepo {
        let remote = try FixtureRepo(name: "remote")
        try remote.git("init", "-q", "--bare", "origin.git")
        try fixture.git("remote", "add", "origin", remote.url.appendingPathComponent("origin.git").path)
        try fixture.git("push", "-q", "-u", "origin", "main")
        return remote
    }

    func testDeleteMergedBranch() async throws {
        try fixture.git("branch", "done")

        try await fixture.repository.deleteBranch("done", force: false)

        XCTAssertFalse(branchExists("done"))
    }

    func testDeleteUnmergedBranchNeedsForce() async throws {
        try fixture.git("switch", "-q", "-c", "work")
        try fixture.commit("unmerged")
        try fixture.git("switch", "-q", "main")

        do {
            try await fixture.repository.deleteBranch("work", force: false)
            XCTFail("an unmerged branch was deleted without force")
        } catch let error as GitError {
            XCTAssertTrue(error.isUnmergedBranch, error.stderr)
        }
        XCTAssertTrue(branchExists("work"))

        try await fixture.repository.deleteBranch("work", force: true)
        XCTAssertFalse(branchExists("work"))
    }

    func testBranchCheckedOutInWorktreeIsNotDeletedEvenWithForce() async throws {
        try fixture.git("worktree", "add", "-q", "-b", "elsewhere", fixture.url.appendingPathComponent("wt").path)

        do {
            try await fixture.repository.deleteBranch("elsewhere", force: true)
            XCTFail("a branch checked out in a worktree was deleted")
        } catch let error as GitError {
            XCTAssertFalse(error.isUnmergedBranch)
        }
        XCTAssertTrue(branchExists("elsewhere"))
    }

    func testRenameBranchKeepsUpstreamAndWorktree() async throws {
        let remote = try addOrigin()
        defer { remote.remove() }
        let worktree = fixture.url.appendingPathComponent("wt").path
        try fixture.git("worktree", "add", "-q", "-b", "old", worktree)
        try fixture.git("branch", "--set-upstream-to=origin/main", "old")

        try await fixture.repository.renameBranch("old", to: "new")

        XCTAssertFalse(branchExists("old"))
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "new@{upstream}"), "origin/main")
        let worktrees = try await fixture.repository.worktrees()
        XCTAssertTrue(worktrees.contains { $0.branchName == "new" })
    }

    func testRenameOntoExistingBranchFails() async throws {
        try fixture.git("branch", "a")
        try fixture.git("branch", "b")

        do {
            try await fixture.repository.renameBranch("a", to: "b")
            XCTFail("renamed onto an existing branch")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("already exists"), error.stderr)
        }
        XCTAssertTrue(branchExists("a"))
    }

    func testSetAndRemoveUpstream() async throws {
        let remote = try addOrigin()
        defer { remote.remove() }
        try fixture.git("branch", "topic")

        try await fixture.repository.setUpstream(of: "topic", to: "origin/main")
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "topic@{upstream}"), "origin/main")

        try await fixture.repository.setUpstream(of: "topic", to: nil)
        XCTAssertThrowsError(try fixture.git("rev-parse", "--abbrev-ref", "topic@{upstream}"))
    }

    func testSetUpstreamToMissingRemoteBranchFails() async throws {
        let remote = try addOrigin()
        defer { remote.remove() }

        do {
            try await fixture.repository.setUpstream(of: "main", to: "origin/missing")
            XCTFail("set a missing upstream")
        } catch is GitError {}
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "main@{upstream}"), "origin/main")
    }

    func testMergeFastForwards() async throws {
        try fixture.git("switch", "-q", "-c", "feature")
        let tip = try fixture.commit("feature work", file: "feature.txt")
        try fixture.git("switch", "-q", "main")

        try await fixture.repository.merge("feature")

        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), tip)
    }

    func testMergeConflictStopsAndIsReported() async throws {
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("theirs", contents: "theirs\n")
        try fixture.git("switch", "-q", "main")
        try fixture.commit("ours", contents: "ours\n")

        do {
            try await fixture.repository.merge("feature")
            XCTFail("a conflicting merge succeeded")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
            XCTAssertTrue(error.stderr.contains("file.txt"), error.stderr)
        }
        XCTAssertNoThrow(try fixture.git("rev-parse", "--verify", "MERGE_HEAD"))
    }

    func testMergeOfUnknownRefIsNoConflict() async throws {
        do {
            try await fixture.repository.merge("nothing")
            XCTFail("merged an unknown ref")
        } catch let error as GitError {
            XCTAssertFalse(error.stoppedOnConflict, error.stderr)
        }
    }

    func testDeleteRemoteBranch() async throws {
        let remote = try addOrigin()
        defer { remote.remove() }
        try fixture.git("push", "-q", "origin", "main:refs/heads/gone")

        try await fixture.repository.deleteRemoteBranch("gone", on: "origin")

        XCTAssertThrowsError(try remote.git("-C", "origin.git", "rev-parse", "--verify", "-q", "refs/heads/gone"))
        XCTAssertThrowsError(try fixture.git("rev-parse", "--verify", "-q", "refs/remotes/origin/gone"))
    }

    func testDeleteMissingRemoteBranchFails() async throws {
        let remote = try addOrigin()
        defer { remote.remove() }

        do {
            try await fixture.repository.deleteRemoteBranch("missing", on: "origin")
            XCTFail("deleted a missing remote branch")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("missing"), error.stderr)
        }
    }
}
