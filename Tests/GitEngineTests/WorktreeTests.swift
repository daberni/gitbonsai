import Foundation
import XCTest
@testable import GitEngine

final class WorktreeTests: XCTestCase {
    func testMainAddedAndDetachedWorktrees() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("one")
        let second = try fixture.commit("two")
        let featurePath = fixture.url.appendingPathComponent("wt-feature").path
        let detachedPath = fixture.url.appendingPathComponent("wt-detached").path
        try fixture.git("worktree", "add", "-q", "-b", "feature", featurePath, first)
        try fixture.git("worktree", "add", "-q", "--detach", detachedPath, first)
        try fixture.git("worktree", "lock", "--reason", "keep me", detachedPath)

        let worktrees = try await fixture.repository.worktrees()

        XCTAssertEqual(worktrees.count, 3)
        let main = worktrees[0]
        XCTAssertTrue(main.isMain)
        XCTAssertEqual(URL(fileURLWithPath: main.path).standardizedFileURL.resolvingSymlinksInPath(), fixture.url.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(main.headSHA, second)
        XCTAssertEqual(main.branch, "refs/heads/main")
        XCTAssertEqual(main.branchName, "main")

        let feature = try XCTUnwrap(worktrees.first { $0.branchName == "feature" })
        XCTAssertFalse(feature.isMain)
        XCTAssertEqual(feature.headSHA, first)
        XCTAssertFalse(feature.isDetached)
        XCTAssertFalse(feature.isLocked)

        let detached = try XCTUnwrap(worktrees.first { $0.isDetached })
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.headSHA, first)
        XCTAssertTrue(detached.isLocked)
        XCTAssertEqual(detached.lockReason, "keep me")
    }

    func testPrunableWorktreeIsFlagged() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one")
        let gone = fixture.url.appendingPathComponent("wt-gone").path
        try fixture.git("worktree", "add", "-q", "--detach", gone)
        try FileManager.default.removeItem(atPath: gone)

        let worktrees = try await fixture.repository.worktrees()

        XCTAssertTrue(try XCTUnwrap(worktrees.last).isPrunable)
    }
}
