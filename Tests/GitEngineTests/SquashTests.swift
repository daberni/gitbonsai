import XCTest
@testable import GitEngine

final class SquashTests: XCTestCase {
    /// main: base - a - b - c - d, each commit adding its own file.
    private func linearFixture() throws -> (fixture: FixtureRepo, ids: [String: String]) {
        let fixture = try FixtureRepo(name: "squash")
        var ids = ["base": try fixture.commit("base", file: "base.txt")]
        for name in ["a", "b", "c", "d"] { ids[name] = try fixture.commit(name, file: "\(name).txt") }
        return (fixture, ids)
    }

    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--reverse", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    private func squash(_ repo: Repository, _ commits: [String], message: String? = nil) async throws {
        var plan = try await repo.squashPlan(commits)
        if let message, let head = plan.steps.first?.commit?.id { plan.messages[head] = message }
        let outcome = try await repo.startInteractiveRebase(plan)
        XCTAssertEqual(outcome, .finished)
    }

    func testSquashInTheMiddleReplaysTheCommitsAboveAndKeepsTheOldestAuthor() async throws {
        let (fixture, ids) = try linearFixture()
        defer { fixture.remove() }
        try fixture.git("commit", "-q", "--amend", "--no-edit", "--author=Other <other@example.com>")
        let repo = fixture.repository
        // Selection order does not matter.
        try await squash(repo, [ids["c"]!, ids["b"]!])

        XCTAssertEqual(try subjects(fixture, "\(ids["base"]!)..main"), ["a", "b", "d"])
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B", "main~1").trimmingCharacters(in: .whitespacesAndNewlines), "b\n\nc")
        XCTAssertEqual(try fixture.git("ls-tree", "--name-only", "main~1").split(separator: "\n"), ["a.txt", "b.txt", "base.txt", "c.txt"])
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%an", "main"), "Other", "d is replayed with its own author")

        let undo = await repo.finishedInteractiveRebase()
        try await repo.undoRebase(try XCTUnwrap(undo))
        XCTAssertEqual(try subjects(fixture, "\(ids["base"]!)..main"), ["a", "b", "c", "d"])
    }

    func testSquashAtTheTipTakesTheEditedMessageAndTheOldestAuthor() async throws {
        let fixture = try FixtureRepo(name: "squash")
        defer { fixture.remove() }
        let base = try fixture.commit("base", file: "base.txt")
        try fixture.write("x.txt", "x")
        try fixture.git("add", "x.txt")
        try fixture.git("commit", "-q", "-m", "x", "--author=Oldest <oldest@example.com>")
        try fixture.commit("y", file: "y.txt")
        let tip = try fixture.commit("z", file: "z.txt")
        let repo = fixture.repository

        try await squash(repo, [tip, try fixture.git("rev-parse", "HEAD~1"), try fixture.git("rev-parse", "HEAD~2")], message: "xyz\n\n# kept")

        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["xyz"])
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B", "main").trimmingCharacters(in: .whitespacesAndNewlines), "xyz\n\n# kept")
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%an", "main"), "Oldest")
    }

    func testTrailersAreDeduplicatedAtTheEnd() {
        let commits = [
            RebaseCommit(id: "1", parents: [], subject: "one", message: "one\n\nBody one.\n\nCo-Authored-By: A <a@x>"),
            RebaseCommit(id: "2", parents: [], subject: "two", message: "two\n\nCo-Authored-By: A <a@x>\nCo-Authored-By: B <b@x>"),
            RebaseCommit(id: "3", parents: [], subject: "three", message: "three\n\nNot: a trailer block\nbecause of this line"),
        ]
        XCTAssertEqual(Repository.squashMessage(commits), "one\n\nBody one.\n\ntwo\n\nthree\n\nNot: a trailer block\nbecause of this line\n\nCo-Authored-By: A <a@x>\nCo-Authored-By: B <b@x>")
        XCTAssertEqual(Repository.squashMessage([RebaseCommit(id: "1", parents: [], subject: "Fix: thing", message: "Fix: thing")]), "Fix: thing", "a subject is never a trailer")
    }

    func testTrailersSurviveTheRun() async throws {
        let fixture = try FixtureRepo(name: "squash")
        defer { fixture.remove() }
        let base = try fixture.commit("base", file: "base.txt")
        let a = try fixture.commit("a\n\nCo-Authored-By: A <a@x>", file: "a.txt")
        let b = try fixture.commit("b\n\nCo-Authored-By: A <a@x>", file: "b.txt")
        try await squash(fixture.repository, [a, b])
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B", "main").trimmingCharacters(in: .whitespacesAndNewlines), "a\n\nb\n\nCo-Authored-By: A <a@x>")
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a"])
    }

    func testRefusedSelections() async throws {
        let (fixture, ids) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        await assertRefused(repo, [ids["a"]!, ids["c"]!], .notConsecutive)
        await assertRefused(repo, [ids["a"]!], .tooFewCommits)
        await assertRefused(repo, [ids["base"]!, ids["a"]!], .rootCommit)

        try fixture.git("switch", "-q", "-c", "side", ids["b"]!)
        let side = try fixture.commit("side", file: "side.txt")
        try fixture.git("switch", "-q", "main")
        await assertRefused(repo, [side, ids["d"]!], .notOnCurrentBranch)
        try fixture.git("merge", "-q", "--no-edit", "side")
        let merge = try fixture.git("rev-parse", "HEAD")
        await assertRefused(repo, [ids["d"]!, merge], .containsMerge)
        await assertRefused(repo, [ids["c"]!, ids["d"]!], .containsMerge, "a merge above would be flattened")
    }

    private func assertRefused(_ repo: Repository, _ commits: [String], _ expected: RebasePlanError, _ message: String = "", line: UInt = #line) async {
        do {
            _ = try await repo.squashPlan(commits)
            XCTFail("expected \(expected) \(message)", line: line)
        } catch {
            XCTAssertEqual(error as? RebasePlanError, expected, message, line: line)
        }
    }

    func testCommandRule() {
        let state = RepositoryCommandState(branch: "main", headSHA: "d")
        let line: [(id: String, parentCount: Int)] = [("d", 1), ("m", 2), ("c", 1), ("b", 1), ("a", 0)]
        XCTAssertNil(CommandRules.squash(state, selected: ["c", "b"], line: Array(line.dropFirst(2))))
        XCTAssertEqual(CommandRules.squash(state, selected: ["c", "b"], line: line), .mergeAbove)
        XCTAssertEqual(CommandRules.squash(state, selected: ["d", "m"], line: line), .containsMerge)
        XCTAssertEqual(CommandRules.squash(state, selected: ["d", "c"], line: line), .notConsecutive)
        XCTAssertEqual(CommandRules.squash(state, selected: ["d", "x"], line: line), .notOnCurrentBranch)
        XCTAssertEqual(CommandRules.squash(state, selected: ["d"], line: line), .tooFewCommits)
        XCTAssertEqual(CommandRules.squash(state, selected: ["b", "a"], line: Array(line.dropFirst(2))), .rootCommit)
        XCTAssertEqual(CommandRules.squash(RepositoryCommandState(headSHA: "d"), selected: ["c", "b"], line: line), .detachedHead)
    }
}
