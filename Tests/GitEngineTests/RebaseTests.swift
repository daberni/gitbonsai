import XCTest
@testable import GitEngine

final class RebaseTests: XCTestCase {
    /// main: base - m1 (touches shared.txt); parent: base - p1; stacked: p1 - s1 - s2 (s2 touches shared.txt when `clash`).
    private func stackedFixture(clash: Bool) throws -> (fixture: FixtureRepo, base: String, main: String, parent: String) {
        let fixture = try FixtureRepo()
        let base = try fixture.commit("base", file: "shared.txt", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "parent")
        let parent = try fixture.commit("p1", file: "parent.txt")
        try fixture.git("switch", "-q", "-c", "stacked")
        try fixture.commit("s1", file: "s1.txt")
        try fixture.commit("s2", file: clash ? "shared.txt" : "s2.txt", contents: "stacked\n")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "shared.txt", contents: "main\n")
        try fixture.git("switch", "-q", "stacked")
        return (fixture, base, main, parent)
    }

    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    func testOntoMovesExactlyTheCommitsAfterTheOldBase() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: false)
        defer { fixture.remove() }
        let repo = fixture.repository

        let moving = try await repo.commitCount(from: parent, to: "stacked")
        XCTAssertEqual(moving, 2)
        try await repo.rebase(onto: main, from: parent, branch: "stacked")

        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "s1"], "p1 stays behind, only s1 and s2 move")
        XCTAssertEqual(try fixture.git("rev-parse", "stacked~2"), main)
        XCTAssertEqual(try fixture.git("rev-parse", "parent"), parent, "the old base branch is untouched")
        let progress = await repo.operationInProgress()
        XCTAssertNil(progress)
    }

    func testConflictStaysInProgressWithItsStepAndContinueFinishesAfterResolving() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: true)
        defer { fixture.remove() }
        let repo = fixture.repository

        do {
            try await repo.rebase(onto: main, from: parent, branch: "stacked")
            XCTFail("s2 conflicts with m1")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
        }
        let progress = await repo.operationInProgress()
        XCTAssertEqual(progress, OperationProgress(kind: .rebase, step: 2, total: 2, branch: "stacked", onto: main, commit: nil))
        let status = try await repo.status()
        XCTAssertEqual(status.conflicted.map(\.path), ["shared.txt"])

        try fixture.write("shared.txt", "resolved\n")
        try fixture.git("add", "shared.txt")
        try await repo.continueOperation(.rebase)

        let after = await repo.operationInProgress()
        XCTAssertNil(after)
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "s1"])
        XCTAssertEqual(try fixture.git("show", "stacked:shared.txt"), "resolved")
    }

    func testAbortRestoresTheBranchAndSkipDropsTheStoppedCommit() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: true)
        defer { fixture.remove() }
        let repo = fixture.repository
        let before = try fixture.git("rev-parse", "stacked")

        try? await repo.rebase(onto: main, from: parent, branch: "stacked")
        try await repo.abortOperation(.rebase)
        XCTAssertEqual(try fixture.git("rev-parse", "stacked"), before)
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "HEAD"), "stacked")
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
        let aborted = await repo.operationInProgress()
        XCTAssertNil(aborted)

        try? await repo.rebase(onto: main, from: parent, branch: "stacked")
        try await repo.skipOperation(.rebase)
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s1"])
    }

    func testCherryPickAndRevertConflictsAreReported() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "other")
        let picked = try fixture.commit("other", contents: "other\n")
        try fixture.git("switch", "-q", "main")
        try fixture.commit("main", contents: "main\n")
        let repo = fixture.repository
        let commits = try await repo.collectLog()

        try? await repo.cherryPick(try XCTUnwrap(commits.first { $0.id == picked }))
        let picking = await repo.operationInProgress()
        XCTAssertEqual(picking, OperationProgress(kind: .cherryPick, step: nil, total: nil, branch: nil, onto: nil, commit: picked))
        try await repo.abortOperation(.cherryPick)

        let reverted = try fixture.git("rev-parse", "HEAD~1")
        try? await repo.revert(try XCTUnwrap(commits.first { $0.id == reverted }))
        let reverting = await repo.operationInProgress()
        XCTAssertEqual(reverting?.kind, .revert)
        XCTAssertEqual(reverting?.commit, reverted)
        try await repo.abortOperation(.revert)
        let none = await repo.operationInProgress()
        XCTAssertNil(none)
    }

    func testApplyBackendProgressAndProgressInALinkedWorktree() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: true)
        defer { fixture.remove() }
        let linked = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-linked-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try fixture.git("switch", "-q", "main")
        try fixture.git("worktree", "add", "-q", linked, "stacked")
        let repo = Repository(path: linked)

        _ = try? await repo.runner.runWrite(["-c", "rebase.updateRefs=false", "rebase", "--apply", "--onto", main, parent, "stacked"])
        let progress = await repo.operationInProgress()
        XCTAssertEqual(progress?.kind, .rebase)
        XCTAssertEqual(progress?.step, 2)
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.branch, "stacked")
        let mainWorktree = await fixture.repository.operationInProgress()
        XCTAssertNil(mainWorktree, "the rebase belongs to the linked worktree only")
    }

    func testResolveCommitAcceptsRefsAndShasOnly() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let head = try fixture.commit("one")
        try fixture.git("tag", "-a", "v1", "-m", "v1")
        let repo = fixture.repository

        let byTag = await repo.resolveCommit("v1")
        let byPrefix = await repo.resolveCommit(String(head.prefix(7)))
        let unknown = await repo.resolveCommit("nope")
        let option = await repo.resolveCommit("--all")
        XCTAssertEqual(byTag, head, "an annotated tag is peeled to its commit")
        XCTAssertEqual(byPrefix, head)
        XCTAssertNil(unknown)
        XCTAssertNil(option)
    }
}
