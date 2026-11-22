import XCTest
@testable import GitEngine

final class CheckoutTests: XCTestCase {
    private func currentBranch(_ fixture: FixtureRepo) throws -> String {
        try fixture.git("rev-parse", "--abbrev-ref", "HEAD")
    }

    func testRemoteBranchCreatesTrackingBranchOnceAndReusesItAfterwards() async throws {
        let upstream = try FixtureRepo(name: "upstream")
        defer { upstream.remove() }
        try upstream.commit("base")
        try upstream.git("switch", "-q", "-c", "feature/login")
        let remoteTip = try upstream.commit("feature work", file: "feature.txt")
        try upstream.git("switch", "-q", "main")

        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", upstream.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("switch", "-q", "-c", "main", "--track", "origin/main")
        let repo = Repository(path: fixture.path)

        try await repo.checkout(.remoteBranch(remote: "origin", branch: "feature/login"))
        XCTAssertEqual(try currentBranch(fixture), "feature/login")
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "feature/login@{upstream}"), "origin/feature/login")

        let localTip = try fixture.commit("local only", file: "local.txt")
        try await repo.checkout(.localBranch("main"))
        XCTAssertEqual(try currentBranch(fixture), "main")

        try await repo.checkout(.remoteBranch(remote: "origin", branch: "feature/login"))
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), localTip, "the existing local branch must be reused, not reset to the remote tip")

        try await repo.checkout(.commit(remoteTip))
        XCTAssertEqual(try currentBranch(fixture), "HEAD")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), remoteTip)
    }

    func testConflictingLocalChangesBlockCheckoutAndCanBeCarriedAlong() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "shared.txt", contents: "one\n")
        try fixture.write("other.txt", "keep\n")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "other")
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("feature edit", file: "shared.txt", contents: "two\n")
        try fixture.git("switch", "-q", "main")
        try fixture.write("other.txt", "edited locally\n")
        try fixture.write("shared.txt", "dirty\n")
        try fixture.write("untracked.txt", "new\n")
        let repo = Repository(path: fixture.path)

        do {
            try await repo.checkout(.localBranch("feature"))
            XCTFail("git must refuse to overwrite the edit in shared.txt")
        } catch let error as GitError {
            XCTAssertTrue(error.isBlockedByLocalChanges, error.stderr)
        }
        XCTAssertEqual(try currentBranch(fixture), "main")

        // Without the colliding edit the remaining changes travel along, untracked file included.
        try fixture.git("checkout", "--", "shared.txt")
        try await repo.checkoutCarryingChanges(.localBranch("feature"))
        XCTAssertEqual(try currentBranch(fixture), "feature")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("other.txt"), encoding: .utf8), "edited locally\n")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("untracked.txt"), encoding: .utf8), "new\n")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }
}
