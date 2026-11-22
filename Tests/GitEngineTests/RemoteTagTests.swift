import XCTest
@testable import GitEngine

final class RemoteTagTests: XCTestCase {
    /// A bare remote with one commit, the clone under test, and a second clone that changes the remote's tags on its own.
    private struct Setup {
        let remote: FixtureRepo
        let local: FixtureRepo
        let other: FixtureRepo
        let base: String
        var bare: String { remote.path + "/bare.git" }

        func remove() { [remote, local, other].forEach { $0.remove() } }
    }

    private func setUpRemote() throws -> Setup {
        let remote = try FixtureRepo(name: "remote")
        let base = try remote.commit("base")
        let bare = remote.path + "/bare.git"
        try remote.git("clone", "-q", "--bare", remote.path, bare)
        let local = try FixtureRepo(name: "local")
        let other = try FixtureRepo(name: "other")
        for clone in [local, other] {
            try clone.git("remote", "add", "origin", bare)
            try clone.git("fetch", "-q", "origin")
            try clone.git("reset", "-q", "--hard", "origin/main")
        }
        return Setup(remote: remote, local: local, other: other, base: base)
    }

    private func states(of repository: Repository, against remote: String) async throws -> [String: TagSyncState] {
        Repository.compareTags(local: try await repository.localTagTargets(), remote: try await repository.remoteTags(on: remote))
    }

    func testEachTagGetsItsStateAgainstTheRemote() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let local = setup.local, other = setup.other
        let second = try other.commit("second")
        try other.git("push", "-q", "origin", "main")
        try local.git("fetch", "-q", "origin")

        try local.git("tag", "pushed-light", setup.base)
        try local.git("tag", "-a", "pushed-annotated", "-m", "pushed", setup.base)
        try local.git("tag", "moved-here", setup.base)
        try local.git("tag", "-a", "moved-there", "-m", "there", setup.base)
        try local.git("tag", "kind", setup.base)
        try local.git("push", "-q", "origin", "refs/tags/*")
        try local.git("tag", "local-only", setup.base)
        try local.git("tag", "-f", "moved-here", second)

        try other.git("fetch", "-q", "origin", "refs/tags/*:refs/tags/*")
        try other.git("tag", "-f", "-a", "moved-there", "-m", "moved", second)
        // Same name and commit, but an annotated tag object on the remote against a lightweight ref here.
        try other.git("tag", "-f", "-a", "kind", "-m", "annotated now", setup.base)
        try other.git("tag", "-a", "remote-only", "-m", "not fetched", second)
        try other.git("push", "-q", "-f", "origin", "refs/tags/*")

        let states = try await states(of: local.repository, against: "origin")
        XCTAssertEqual(states["pushed-light"], .same)
        XCTAssertEqual(states["pushed-annotated"], .same, "an annotated tag compares by its tag object, not by the peeled entry")
        XCTAssertEqual(states["local-only"], .localOnly)

        let annotatedHere = try local.git("rev-parse", "refs/tags/kind")
        let annotatedThere = try other.git("rev-parse", "refs/tags/kind")
        XCTAssertEqual(states["kind"], .differs(local: TagTarget(objectID: annotatedHere, commitID: setup.base), remote: TagTarget(objectID: annotatedThere, commitID: setup.base)))

        XCTAssertEqual(states["moved-here"], .differs(local: TagTarget(objectID: second, commitID: second), remote: TagTarget(objectID: setup.base, commitID: setup.base)))
        guard case .differs(let movedLocal, let movedRemote) = states["moved-there"] else { return XCTFail("moved-there: \(String(describing: states["moved-there"]))") }
        XCTAssertEqual(movedLocal.commitID, setup.base)
        XCTAssertEqual(movedRemote.commitID, second, "the remote's annotated tag is peeled to its commit")
        XCTAssertEqual(movedRemote.objectID, try other.git("rev-parse", "refs/tags/moved-there"))

        guard case .remoteOnly(let remoteOnly) = states["remote-only"] else { return XCTFail("remote-only: \(String(describing: states["remote-only"]))") }
        XCTAssertEqual(remoteOnly.commitID, second)
        XCTAssertEqual(states.count, 7)
    }

    func testATagOfATreeIsNotTakenForOneOnlyOnTheRemote() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let tree = try setup.local.git("rev-parse", "HEAD^{tree}")
        try setup.local.git("tag", "tree-tag", tree)
        try setup.local.git("push", "-q", "origin", "refs/tags/tree-tag")

        let states = try await states(of: setup.local.repository, against: "origin")
        XCTAssertEqual(states["tree-tag"], .same)
    }

    func testFetchTagBringsOnlyThatTag() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let second = try setup.other.commit("second")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.other.git("tag", "-a", "wanted", "-m", "wanted", second)
        try setup.other.git("tag", "unwanted", second)
        try setup.other.git("push", "-q", "origin", "refs/tags/*")
        let repo = setup.local.repository

        try await repo.fetchTag("wanted", from: "origin")
        XCTAssertEqual(try setup.local.git("tag"), "wanted")
        XCTAssertEqual(try setup.local.git("cat-file", "-t", "wanted"), "tag")
        XCTAssertEqual(try setup.local.git("rev-parse", "wanted^{commit}"), second)
        let states = try await states(of: repo, against: "origin")
        XCTAssertEqual(states["wanted"], .same)
    }

    func testFetchTagDoesNotOverwriteADifferingLocalTag() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let second = try setup.other.commit("second")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.other.git("tag", "v1", second)
        try setup.other.git("push", "-q", "origin", "refs/tags/v1")
        try setup.local.git("tag", "v1", setup.base)

        do {
            try await setup.local.repository.fetchTag("v1", from: "origin")
            XCTFail("fetching over a differing tag must fail")
        } catch is GitError {}
        XCTAssertEqual(try setup.local.git("rev-parse", "v1"), setup.base)
    }

    func testAMissingRemoteFailsInsteadOfReportingStates() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("first")
        try fixture.git("tag", "v1")
        try fixture.git("remote", "add", "gone", fixture.path + "/does-not-exist.git")

        do {
            _ = try await fixture.repository.remoteTags(on: "gone")
            XCTFail("an unreachable remote must not produce states")
        } catch let error as GitError {
            XCTAssertFalse(error.isTimeout)
        }
    }

    func testARemoteThatDoesNotAnswerTimesOutWithoutWaiting() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        // upload-pack keeps the connection open without saying anything, and its sleep holds git's stderr after git is stopped.
        try setup.local.git("config", "remote.origin.uploadpack", "sleep 5; git-upload-pack")

        let start = Date()
        do {
            _ = try await setup.local.repository.remoteTags(on: "origin", timeout: .milliseconds(300))
            XCTFail("a silent remote must time out")
        } catch let error as GitError {
            XCTAssertTrue(error.isTimeout, error.description)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
