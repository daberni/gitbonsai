import Foundation
import XCTest
@testable import GitEngine

final class WorktreeActionsTests: XCTestCase {
    private var fixture: FixtureRepo!
    private var worktree: String { fixture.url.appendingPathComponent("wt").path }

    override func setUpWithError() throws {
        fixture = try FixtureRepo()
        try fixture.commit("one")
    }

    override func tearDown() {
        fixture.remove()
    }

    private func linked() async throws -> Worktree? {
        try await fixture.repository.worktrees().first { !$0.isMain }
    }

    func testAddWorktreeForExistingBranch() async throws {
        try fixture.git("branch", "topic")

        try await fixture.repository.addWorktree(at: worktree, branch: "topic")

        let added = try await linked()
        XCTAssertEqual(added?.branchName, "topic")
    }

    func testAddWorktreeForBranchCheckedOutElsewhereFails() async throws {
        do {
            try await fixture.repository.addWorktree(at: worktree, branch: "main")
            XCTFail("checked out main twice")
        } catch is GitError {}
        let added = try await linked()
        XCTAssertNil(added)
    }

    func testRemoveCleanWorktree() async throws {
        try fixture.git("worktree", "add", "-q", "--detach", worktree)

        try await fixture.repository.removeWorktree(at: worktree, force: false)

        let remaining = try await linked()
        XCTAssertNil(remaining)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    func testRemoveDirtyWorktreeNeedsForce() async throws {
        try fixture.git("worktree", "add", "-q", "--detach", worktree)
        try "new\n".write(toFile: worktree + "/untracked.txt", atomically: true, encoding: .utf8)

        do {
            try await fixture.repository.removeWorktree(at: worktree, force: false)
            XCTFail("removed a dirty worktree without force")
        } catch let error as GitError {
            XCTAssertTrue(error.isDirtyWorktree, error.stderr)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))

        try await fixture.repository.removeWorktree(at: worktree, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    func testLockedWorktreeIsKeptUntilUnlocked() async throws {
        try fixture.git("worktree", "add", "-q", "--detach", worktree)

        try await fixture.repository.lockWorktree(at: worktree, reason: "external disk")
        let locked = try await linked()
        XCTAssertEqual(locked?.isLocked, true)
        XCTAssertEqual(locked?.lockReason, "external disk")

        do {
            try await fixture.repository.removeWorktree(at: worktree, force: true)
            XCTFail("removed a locked worktree")
        } catch let error as GitError {
            XCTAssertFalse(error.isDirtyWorktree, error.stderr)
        }

        try await fixture.repository.unlockWorktree(at: worktree)
        let unlocked = try await linked()
        XCTAssertEqual(unlocked?.isLocked, false)
        try await fixture.repository.removeWorktree(at: worktree, force: false)
    }

    func testUnlockOfUnlockedWorktreeFails() async throws {
        try fixture.git("worktree", "add", "-q", "--detach", worktree)

        do {
            try await fixture.repository.unlockWorktree(at: worktree)
            XCTFail("unlocked a worktree that was not locked")
        } catch is GitError {}
    }

    func testPruneForgetsMissingFoldersButKeepsLockedOnes() async throws {
        let locked = fixture.url.appendingPathComponent("wt-locked").path
        try fixture.git("worktree", "add", "-q", "--detach", worktree)
        try fixture.git("worktree", "add", "-q", "--detach", locked)
        try fixture.git("worktree", "lock", locked)
        try FileManager.default.removeItem(atPath: worktree)
        try FileManager.default.removeItem(atPath: locked)

        try await fixture.repository.pruneWorktrees()

        let paths = try await fixture.repository.worktrees().filter { !$0.isMain }.map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(paths, ["wt-locked"])
    }
}
