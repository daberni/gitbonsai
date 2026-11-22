import XCTest
@testable import GitEngine

final class RebaseBaseTests: XCTestCase {
    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    /// main: base - m1; parent: base - p1 - p2; stacked: p2 - s1 - s2.
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

    func testStackedBranchStopsAtTheParentBranchTip() async throws {
        let (fixture, main, parent) = try stackedFixture()
        defer { fixture.remove() }

        let detection = await fixture.repository.detectRebaseBase(of: "stacked", onto: main, targetRef: "main")

        XCTAssertEqual(detection, .detected(RebaseBase(commit: parent, reason: .branch("parent"), moving: 2)))
    }

    func testParentThatMovedOnIsFoundThroughItsReflog() async throws {
        let (fixture, _, parent) = try stackedFixture()
        defer { fixture.remove() }
        try fixture.git("switch", "-q", "parent")
        try fixture.git("commit", "-q", "--amend", "-m", "p2 amended")
        let amended = try fixture.git("rev-parse", "HEAD")
        try fixture.git("switch", "-q", "stacked")

        let detection = await fixture.repository.detectRebaseBase(of: "stacked", onto: amended, targetRef: "parent")

        XCTAssertEqual(detection, .detected(RebaseBase(commit: parent, reason: .branch("parent"), moving: 2)))
        try await fixture.repository.rebase(onto: amended, from: parent, branch: "stacked")
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "s1", "p2 amended", "p1"], "the old p2 is gone, s1 and s2 sit on the amended one")
    }

    func testSquashMergedAndDeletedParentIsFoundByPatchID() async throws {
        let (fixture, _, parent) = try stackedFixture()
        defer { fixture.remove() }
        try fixture.git("switch", "-q", "main")
        try fixture.git("merge", "-q", "--squash", "parent")
        try fixture.git("commit", "-q", "-m", "squashed parent")
        let squash = try fixture.git("rev-parse", "HEAD")
        try fixture.git("branch", "-q", "-D", "parent")
        try fixture.git("switch", "-q", "stacked")

        let detection = await fixture.repository.detectRebaseBase(of: "stacked", onto: squash, targetRef: "main")

        XCTAssertEqual(detection, .detected(RebaseBase(commit: parent, reason: .squashed(into: squash), moving: 2)))
        try await fixture.repository.rebase(onto: squash, from: parent, branch: "stacked")
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "s1"])
    }

    func testRewrittenRemoteTargetUsesItsForkPoint() async throws {
        let upstream = try FixtureRepo(name: "upstream")
        defer { upstream.remove() }
        try upstream.commit("base")
        let old = try upstream.commit("t1", file: "t1.txt")
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", upstream.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("switch", "-q", "-c", "work", "origin/main")
        try fixture.commit("w1", file: "w1.txt")
        try fixture.commit("w2", file: "w2.txt")
        // A different content keeps the squash rule from matching the old t1 by patch-id.
        try upstream.write("t1.txt", "rewritten\n")
        try upstream.git("commit", "-q", "-a", "--amend", "-m", "t1 rewritten")
        try fixture.git("fetch", "-q", "origin")
        let rewritten = try fixture.git("rev-parse", "origin/main")

        let detection = await fixture.repository.detectRebaseBase(of: "work", onto: rewritten, targetRef: "origin/main")

        XCTAssertEqual(detection, .detected(RebaseBase(commit: old, reason: .forkPoint("origin/main"), moving: 2)))
        try await fixture.repository.rebase(onto: rewritten, from: old, branch: "work")
        XCTAssertEqual(try subjects(fixture, "origin/main..work"), ["w2", "w1"], "the old t1 is not replayed")
    }

    func testNothingDetectableFallsBackToAPlainRebase() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "work")
        try fixture.commit("w1", file: "w1.txt")
        try fixture.commit("w2", file: "w2.txt")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "work")

        let detection = await fixture.repository.detectRebaseBase(of: "work", onto: main, targetRef: "main")

        XCTAssertEqual(detection, .plain(moving: 2))
    }

    /// x and y each sit on one side of a merge in the branch, both two commits below its tip.
    func testEquallyNearParentsOnBothSidesOfAMergeTie() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "x")
        let x = try fixture.commit("x1", file: "x.txt")
        try fixture.git("switch", "-q", "-c", "y", "main")
        let y = try fixture.commit("y1", file: "y.txt")
        try fixture.git("switch", "-q", "-c", "work", "x")
        try fixture.git("merge", "-q", "--no-edit", "y")
        try fixture.commit("w1", file: "w1.txt")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "work")

        let detection = await fixture.repository.detectRebaseBase(of: "work", onto: main, targetRef: "main")

        let expected = [RebaseBase(commit: x, reason: .branch("x"), moving: 3), RebaseBase(commit: y, reason: .branch("y"), moving: 3)].sorted { $0.commit < $1.commit }
        XCTAssertEqual(detection, .tie(expected))
    }
}
