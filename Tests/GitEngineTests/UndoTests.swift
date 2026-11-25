import Foundation
import XCTest
@testable import GitEngine

final class UndoTests: XCTestCase {
    private var fixture: FixtureRepo!
    private var first = ""
    private var second = ""

    override func setUpWithError() throws {
        fixture = try FixtureRepo()
        first = try fixture.commit("one")
        second = try fixture.commit("two")
    }

    override func tearDown() {
        fixture.remove()
    }

    private func sha(_ revision: String) -> String? { try? fixture.git("rev-parse", "--verify", "-q", revision) }

    func testUndoMixedResetRestoresBranchAndIndex() async throws {
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: [], headRestore: .mixed)
        try await repository.resetCurrentBranch(to: first, mode: .mixed)
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)

        try await repository.undo(done)

        XCTAssertEqual(sha("HEAD"), second)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
    }

    func testUndoSoftResetKeepsNothingStaged() async throws {
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: [], headRestore: .soft)
        try await repository.resetCurrentBranch(to: first, mode: .soft)
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)

        try await repository.undo(done)

        XCTAssertEqual(sha("HEAD"), second)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
    }

    func testUndoBranchDeletionRecreatesIt() async throws {
        try fixture.git("branch", "done", first)
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: ["refs/heads/done"])
        try await repository.deleteBranch("done", force: true)
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)

        try await repository.undo(done)

        XCTAssertEqual(sha("refs/heads/done"), first)
    }

    func testUndoCheckoutSwitchesBackAndKeepsChanges() async throws {
        try fixture.git("branch", "other", first)
        try fixture.write("notes.txt", "local\n")
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: [])
        try fixture.git("switch", "-q", "other")
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)

        try await repository.undo(done)

        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD"), "main")
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "?? notes.txt")
    }

    func testNoUndoOnceTheBranchMovedOn() async throws {
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: [])
        try await repository.resetCurrentBranch(to: first, mode: .mixed)
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)
        try fixture.commit("three")

        let possible = await repository.canUndo(done)
        XCTAssertFalse(possible)
    }

    func testNothingToUndoWhenNothingMoved() async throws {
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: ["refs/heads/main"])
        let done = await repository.finishUndoPoint(point)
        XCTAssertNil(done)
    }
}

extension UndoTests {
    func testUndoCheckoutOfRemoteBranchRemovesTheNewBranch() async throws {
        try fixture.git("remote", "add", "origin", fixture.path)
        try fixture.git("update-ref", "refs/remotes/origin/topic", first)
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: ["refs/heads/topic"])
        try await repository.checkout(.remoteBranch(remote: "origin", branch: "topic"), stashMessage: "test")
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)

        try await repository.undo(done)

        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD"), "main")
        XCTAssertNil(sha("refs/heads/topic"))
    }

    /// A checkout of a remote branch that also moved `other`, so the undo switches back and moves two refs.
    private func checkoutMovingOther() async throws -> UndoPoint {
        try fixture.git("remote", "add", "origin", fixture.path)
        try fixture.git("update-ref", "refs/remotes/origin/topic", first)
        try fixture.git("branch", "other", second)
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: ["refs/heads/topic", "refs/heads/other"])
        try await repository.checkout(.remoteBranch(remote: "origin", branch: "topic"), stashMessage: "test")
        try fixture.git("branch", "-f", "other", first)
        let finished = await repository.finishUndoPoint(point)
        return try XCTUnwrap(finished)
    }

    /// A lock on another ref the undo moves makes its transaction fail: HEAD must not have switched back before that.
    func testAnUndoWhoseRefsCannotMoveChangesNothing() async throws {
        let done = try await checkoutMovingOther()
        try "".write(to: fixture.url.appendingPathComponent(".git/refs/heads/other.lock"), atomically: true, encoding: .utf8)

        do {
            try await fixture.repository.undo(done)
            XCTFail("the locked ref cannot move")
        } catch is GitError {}

        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD"), "topic", "HEAD stays where the operation left it")
        XCTAssertEqual(sha("refs/heads/other"), first)
    }

    /// The branch HEAD leaves can only go after the switch; when that fails, HEAD and the other refs are back and the branch merely stays.
    func testAnUndoWhoseLeftBranchCannotGoKeepsItAndRestoresTheRest() async throws {
        let done = try await checkoutMovingOther()
        try "".write(to: fixture.url.appendingPathComponent(".git/refs/heads/topic.lock"), atomically: true, encoding: .utf8)

        do {
            try await fixture.repository.undo(done)
            XCTFail("the locked branch cannot be deleted")
        } catch is GitError {}

        XCTAssertEqual(try fixture.git("symbolic-ref", "--short", "HEAD"), "main")
        XCTAssertEqual(sha("refs/heads/other"), second)
        XCTAssertEqual(sha("refs/heads/topic"), first)
    }

    /// An annotated tag comes back as the same tag object with its message, not as a lightweight tag on its commit.
    func testUndoTagDeletionRestoresTheAnnotatedTagObject() async throws {
        try fixture.git("tag", "-a", "v1", "-m", "Release one", first)
        let tagObject = sha("refs/tags/v1")
        let repository = fixture.repository
        let point = await repository.undoPoint(watching: ["refs/tags/v1"])
        try await repository.deleteTag("v1")
        let finished = await repository.finishUndoPoint(point)
        let done = try XCTUnwrap(finished)

        try await repository.undo(done)

        XCTAssertEqual(sha("refs/tags/v1"), tagObject)
        XCTAssertEqual(try fixture.git("cat-file", "-t", "v1"), "tag")
        XCTAssertEqual(sha("HEAD"), second, "HEAD stays")
    }
}
