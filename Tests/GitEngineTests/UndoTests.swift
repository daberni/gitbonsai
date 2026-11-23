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
}
