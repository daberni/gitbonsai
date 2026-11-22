import XCTest
@testable import GitEngine

/// An interactive rebase onto any commit: in place on an ancestor of HEAD, otherwise `--onto` from the detected base.
final class InteractiveRebaseOntoTests: XCTestCase {
    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    /// main: base - m1; parent: base - p1 - p2; stacked: p2 - s1 - s2, checked out.
    private func stackedFixture() throws -> (fixture: FixtureRepo, main: String, parent: String) {
        let fixture = try FixtureRepo()
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "parent")
        try fixture.commit("p1", file: "p1.txt")
        let parent = try fixture.commit("p2", file: "p2.txt")
        try fixture.git("switch", "-q", "-c", "stacked")
        try fixture.commit("s1", file: "s1.txt")
        try fixture.commit("s2", file: "s2.txt")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "stacked")
        return (fixture, main, parent)
    }

    /// Detects, plans with s1 reworded and runs; returns the range for its checks.
    @discardableResult
    private func rebaseInteractively(_ fixture: FixtureRepo, branch: String = "stacked", onto target: String, targetRef: String?) async throws -> RebaseRange {
        let repo = fixture.repository
        let detection = await repo.detectRebaseBase(of: branch, onto: target, targetRef: targetRef)
        let range = try await repo.rebaseRange(onto: target, detection: detection)
        var plan = RebasePlan(range: range)
        if let first = plan.steps.firstIndex(where: { $0.commit?.subject == "s1" || $0.commit?.subject == "w1" }), let id = plan.steps[first].commit?.id {
            plan.steps[first].action = .reword
            plan.messages[id] = "reworded"
        }
        let outcome = try await repo.startInteractiveRebase(plan)
        XCTAssertEqual(outcome, .finished)
        return range
    }

    func testAncestorOfHeadIsRebasedInPlace() async throws {
        let (fixture, _, parent) = try stackedFixture()
        defer { fixture.remove() }

        let range = try await rebaseInteractively(fixture, onto: parent, targetRef: "parent")

        XCTAssertTrue(range.isInPlace)
        XCTAssertEqual(range.commits.map(\.subject), ["s1", "s2"])
        XCTAssertEqual(try subjects(fixture, "\(parent)..stacked"), ["s2", "reworded"])
    }

    func testStackedParentLeavesItsCommitsBehind() async throws {
        let (fixture, main, _) = try stackedFixture()
        defer { fixture.remove() }

        let range = try await rebaseInteractively(fixture, onto: main, targetRef: "main")

        XCTAssertEqual(range.commits.map(\.subject), ["s1", "s2"], "the sheet lists only the branch's own commits")
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "reworded"])
        let undo = await fixture.repository.finishedInteractiveRebase()
        XCTAssertNotNil(undo, "the rebase is undoable from the status line")
    }

    func testSquashMergedParentIsLeftOut() async throws {
        let (fixture, _, _) = try stackedFixture()
        defer { fixture.remove() }
        try fixture.git("switch", "-q", "main")
        try fixture.git("merge", "-q", "--squash", "parent")
        try fixture.git("commit", "-q", "-m", "squashed parent")
        let squash = try fixture.git("rev-parse", "HEAD")
        try fixture.git("branch", "-q", "-D", "parent")
        try fixture.git("switch", "-q", "stacked")

        let range = try await rebaseInteractively(fixture, onto: squash, targetRef: "main")

        XCTAssertEqual(range.commits.map(\.subject), ["s1", "s2"])
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "reworded"])
    }

    func testRewrittenRemoteTargetStartsAtTheForkPoint() async throws {
        let upstream = try FixtureRepo(name: "upstream")
        defer { upstream.remove() }
        try upstream.commit("base")
        try upstream.commit("t1", file: "t1.txt")
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", upstream.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("switch", "-q", "-c", "work", "origin/main")
        try fixture.commit("w1", file: "w1.txt")
        try fixture.commit("w2", file: "w2.txt")
        try upstream.write("t1.txt", "rewritten\n")
        try upstream.git("commit", "-q", "-a", "--amend", "-m", "t1 rewritten")
        try fixture.git("fetch", "-q", "origin")
        let rewritten = try fixture.git("rev-parse", "origin/main")

        let range = try await rebaseInteractively(fixture, branch: "work", onto: rewritten, targetRef: "origin/main")

        XCTAssertEqual(range.commits.map(\.subject), ["w1", "w2"])
        XCTAssertEqual(try subjects(fixture, "origin/main..work"), ["w2", "reworded"])
    }

    func testWithoutADetectedBaseTheRangeStartsAtTheMergeBaseAndAppliedCommitsStartAsDrops() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "work")
        try fixture.commit("w1", file: "w1.txt")
        let picked = try fixture.commit("w2", file: "w2.txt")
        try fixture.git("switch", "-q", "main")
        try fixture.git("cherry-pick", picked)
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "work")

        let range = try await rebaseInteractively(fixture, branch: "work", onto: main, targetRef: "main")

        XCTAssertEqual(range.commits.map(\.subject), ["w1", "w2"])
        XCTAssertEqual(range.alreadyOnTarget, [picked])
        XCTAssertEqual(RebasePlan(range: range).steps.map(\.action), [.pick, .drop])
        XCTAssertEqual(try subjects(fixture, "main..work"), ["reworded"])
    }

    /// A tie only happens with a merge in the branch; onto the target the merge is flattened like a plain `git rebase` does, and the chosen side stays behind.
    func testTiedBasesFlattenTheMergeOfTheOtherSide() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "x")
        let x = try fixture.commit("x1", file: "x.txt")
        try fixture.git("switch", "-q", "-c", "y", "main")
        try fixture.commit("y1", file: "y.txt")
        try fixture.git("switch", "-q", "-c", "work", "x")
        try fixture.git("merge", "-q", "--no-edit", "y")
        try fixture.commit("w1", file: "w1.txt")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "work")

        let range = try await fixture.repository.rebaseRange(from: x, onto: main)
        XCTAssertEqual(range.commits.map(\.subject), ["y1", "w1"])
        XCTAssertEqual(range.flattenedMerges, 1)
        let outcome = try await fixture.repository.startInteractiveRebase(RebasePlan(range: range))

        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(try subjects(fixture, "main..work"), ["w1", "y1"])
    }
}
