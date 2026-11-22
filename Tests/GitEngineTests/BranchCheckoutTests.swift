import XCTest
@testable import GitEngine

/// What a history row offers to check out when remote branches have local counterparts elsewhere in the history.
final class BranchCheckoutTests: XCTestCase {
    private var remote: URL!
    private var fixture: FixtureRepo!
    private var base = ""

    /// A bare remote with `main` and `feature`; the clone tracks `main` and works on `work`, so `main` is not HEAD.
    override func setUpWithError() throws {
        let seed = try FixtureRepo(name: "seed")
        defer { seed.remove() }
        base = try seed.commit("base")
        try seed.git("branch", "feature")
        remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-remote-\(UUID().uuidString).git", isDirectory: true)
        try seed.git("clone", "-q", "--bare", seed.path, remote.path)

        fixture = try FixtureRepo()
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("switch", "-q", "-c", "main", "--track", "origin/main")
        try fixture.git("switch", "-q", "-c", "work")
    }

    override func tearDown() {
        fixture?.remove()
        if let remote { try? FileManager.default.removeItem(at: remote) }
    }

    /// Moves `branch` on the remote one commit ahead and fetches it.
    @discardableResult
    private func advanceRemote(_ branch: String) throws -> String {
        let other = try FixtureRepo(name: "other")
        defer { other.remove() }
        try other.git("remote", "add", "origin", remote.path)
        try other.git("fetch", "-q", "origin")
        try other.git("switch", "-q", "-C", branch, "origin/\(branch)")
        let tip = try other.commit("remote work on \(branch)", file: "remote.txt")
        try other.git("push", "-q", "origin", branch)
        try fixture.git("fetch", "-q", "origin")
        return tip
    }

    private func choices(at commit: String) async throws -> [BranchCheckout] {
        BranchCheckout.choices(at: commit, refs: try await Repository(path: fixture.path).refs())
    }

    func testLocalBranchEqualToItsRemoteIsOfferedOnce() async throws {
        try fixture.git("remote", "add", "fork", remote.path)
        try fixture.git("fetch", "-q", "fork")
        try fixture.git("switch", "-q", "main")
        try fixture.git("branch", "-D", "work")
        try fixture.git("switch", "-q", "--no-track", "-c", "work", "origin/feature")
        try fixture.commit("own", file: "own.txt")
        // The row of `base` carries main, origin/main, fork/main, origin/feature and fork/feature.
        let atBase = try await choices(at: base)
        XCTAssertEqual(atBase, [
            BranchCheckout(branch: "main", kind: .local),
            BranchCheckout(branch: "feature", kind: .createTracking(remote: "origin")),
        ])
    }

    func testLocalBranchBehindItsRemoteIsFastForwarded() async throws {
        let tip = try advanceRemote("main")
        let atTip = try await choices(at: tip)
        XCTAssertEqual(atTip, [BranchCheckout(branch: "main", kind: .fastForward(from: "origin/main"))])
    }

    func testDivergedLocalBranchIsCheckedOutAsItIs() async throws {
        try fixture.git("switch", "-q", "main")
        try fixture.commit("local work", file: "local.txt")
        try fixture.git("switch", "-q", "work")
        let tip = try advanceRemote("main")
        let atTip = try await choices(at: tip)
        XCTAssertEqual(atTip, [BranchCheckout(branch: "main", kind: .diverged(from: "origin/main", localCommits: 1))])
    }

    func testTrackingBranchWithAnotherNameIsTheCounterpart() async throws {
        try fixture.git("branch", "--track", "login", "origin/feature")
        let tip = try advanceRemote("feature")
        let atTip = try await choices(at: tip)
        XCTAssertEqual(atTip, [BranchCheckout(branch: "login", kind: .fastForward(from: "origin/feature"))])
    }

    func testRemoteBranchWithoutLocalCounterpartCreatesTrackingBranch() async throws {
        let tip = try advanceRemote("feature")
        let atTip = try await choices(at: tip)
        XCTAssertEqual(atTip, [BranchCheckout(branch: "feature", kind: .createTracking(remote: "origin"))])
    }

    func testCurrentBranchBehindItsRemoteOffersOnlyTheFastForward() async throws {
        try fixture.git("switch", "-q", "main")
        try fixture.git("branch", "-D", "work")
        let atBase = try await choices(at: base)
        XCTAssertEqual(atBase, [BranchCheckout(branch: "feature", kind: .createTracking(remote: "origin"))], "the current branch at its remote has nothing to check out")
        let tip = try advanceRemote("main")
        let atTip = try await choices(at: tip)
        XCTAssertEqual(atTip, [BranchCheckout(branch: "main", kind: .fastForward(from: "origin/main"))])
    }

    func testFastForwardSwitchesAndMovesTheBranch() async throws {
        let tip = try advanceRemote("main")
        try await Repository(path: fixture.path).checkout(.fastForward(branch: "main", to: "origin/main"))
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "HEAD"), "main")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), tip)
    }
}
