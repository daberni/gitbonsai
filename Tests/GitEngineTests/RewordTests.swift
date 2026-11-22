import XCTest
@testable import GitEngine

final class RewordTests: XCTestCase {
    /// main: base - a - b - c, each commit adding its own file.
    private func fixture() throws -> FixtureRepo {
        let fixture = try FixtureRepo(name: "reword")
        for name in ["base", "a", "b", "c"] { try fixture.commit(name, file: "\(name).txt") }
        return fixture
    }

    private func status(_ fixture: FixtureRepo) throws -> String {
        try fixture.git("status", "--porcelain=v1")
    }

    func testHeadWithStagedChangesKeepsThemStagedAndOutOfTheCommit() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let before = try fixture.git("rev-parse", "HEAD")
        let tree = try fixture.git("rev-parse", "HEAD^{tree}")
        try fixture.write("staged.txt", "staged\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("c.txt", "changed, not staged\n")

        let plan = try await repo.singleStepPlan(.reword(""), commit: before)
        XCTAssertTrue(plan.rewordsHeadAlone)
        let message = "Größe prüfen – 日本語 ✓\n\n# keine Kommentarzeile\nZweite Zeile 🌱"
        let outcome = try await repo.reword(plan, message: message)

        let after = try fixture.git("rev-parse", "HEAD")
        XCTAssertEqual(outcome, .rewritten(after))
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B"), message)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD^{tree}"), tree, "the staged file stays out of the commit")
        XCTAssertEqual(try status(fixture), " M c.txt\nA  staged.txt")

        let lastUndo = await repo.lastRebaseUndo()
        let undo = try XCTUnwrap(lastUndo, "the amend can be undone from the status line")
        XCTAssertEqual(undo.before, before)
        XCTAssertEqual(undo.after, after)
        try await repo.undoRebase(undo)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), before)
        // `git reset --keep` keeps the files but not what was staged: the new file is untracked again.
        XCTAssertEqual(try status(fixture), " M c.txt\n?? staged.txt")
    }

    func testHeadWithAnotherBranchOnItRewordsThroughTheRebaseAndMovesTheBranch() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let head = try fixture.git("rev-parse", "HEAD")
        try fixture.git("branch", "stacked")

        let plan = try await repo.singleStepPlan(.reword(""), commit: head)
        XCTAssertFalse(plan.rewordsHeadAlone, "an amend would leave stacked on the old commit")
        let outcome = try await repo.reword(plan, message: "c reworded")

        let after = try fixture.git("rev-parse", "HEAD")
        XCTAssertEqual(outcome, .rewritten(after))
        XCTAssertEqual(try fixture.git("rev-parse", "stacked"), after)
    }

    func testOlderCommitIsRewordedAndFoundBelowTheReplayedOnes() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let a = try fixture.git("rev-parse", "HEAD~2")
        try fixture.write("staged.txt", "staged\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("c.txt", "changed, not staged\n")

        var plan = try await repo.singleStepPlan(.reword(""), commit: a)
        XCTAssertFalse(plan.rewordsHeadAlone)
        XCTAssertEqual(plan.steps.count, 3)
        plan.autostash = true
        let outcome = try await repo.reword(plan, message: "a – überarbeitet\n\nmit Text")

        let rewritten = try fixture.git("rev-parse", "HEAD~2")
        XCTAssertEqual(outcome, .rewritten(rewritten))
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B", rewritten), "a – überarbeitet\n\nmit Text")
        XCTAssertEqual(try fixture.git("log", "--reverse", "--format=%s", "HEAD~3..HEAD"), "a – überarbeitet\nb\nc")
        XCTAssertEqual(try status(fixture), " M c.txt\nA  staged.txt", "the autostash brings the changes back with what was staged")
    }
}
