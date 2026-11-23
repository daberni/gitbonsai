import XCTest
@testable import GitEngine

final class FetchTests: XCTestCase {
    /// A bare remote with branches main and gone and tag v1, and a clone of it whose origin knows both branches.
    private func cloneWithRemote() throws -> (remote: FixtureRepo, clone: FixtureRepo) {
        let source = try FixtureRepo(name: "source")
        defer { source.remove() }
        try source.commit("one")
        try source.git("branch", "gone")
        let remote = try FixtureRepo(name: "remote")
        try remote.git("clone", "-q", "--bare", source.path, remote.path + "/bare.git")
        let clone = try FixtureRepo(name: "clone")
        try clone.git("remote", "add", "origin", remote.path + "/bare.git")
        try clone.git("fetch", "-q", "origin")
        return (remote, clone)
    }

    private func remoteBranches(_ fixture: FixtureRepo) throws -> [String] {
        try fixture.git("for-each-ref", "--format=%(refname:lstrip=2)", "refs/remotes").split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    func testPruneRemovesABranchThatIsGoneOnTheRemoteAndPlainFetchKeepsIt() async throws {
        let (remote, clone) = try cloneWithRemote()
        defer { remote.remove(); clone.remove() }
        try remote.git("--git-dir", remote.path + "/bare.git", "branch", "-D", "gone")
        let repo = clone.repository

        try await repo.fetch(.remote("origin", prune: false))
        XCTAssertEqual(try remoteBranches(clone), ["origin/gone", "origin/main"])
        try await repo.fetch(.remote("origin", prune: true))
        XCTAssertEqual(try remoteBranches(clone), ["origin/main"])
    }

    func testFetchOneRemoteLeavesTheOthersAndTagsFetchesTags() async throws {
        let (remote, clone) = try cloneWithRemote()
        defer { remote.remove(); clone.remove() }
        try clone.git("remote", "add", "second", remote.path + "/bare.git")
        try remote.git("--git-dir", remote.path + "/bare.git", "tag", "v1", "main")
        let repo = clone.repository

        let remotes = try await repo.remotes()
        XCTAssertEqual(remotes, ["origin", "second"])
        try await repo.fetch(.remote("origin", prune: false))
        XCTAssertFalse(try remoteBranches(clone).contains { $0.hasPrefix("second/") })
        try await repo.fetch(.allRemotes)
        XCTAssertTrue(try remoteBranches(clone).contains("second/main"))
        XCTAssertEqual(try clone.git("tag"), "v1", "a tag on a fetched commit comes along by default")

        // v2 points at a commit no branch contains, so only an explicit tag fetch brings it.
        let bare = ["--git-dir", remote.path + "/bare.git"]
        let tree = try remote.git(bare + ["rev-parse", "main^{tree}"])
        let orphan = try remote.git(bare + ["commit-tree", tree, "-p", "main", "-m", "tagged only"])
        try remote.git(bare + ["tag", "v2", orphan])
        try await repo.fetch(.allRemotes)
        XCTAssertEqual(try clone.git("tag"), "v1")
        try await repo.fetch(.tags)
        XCTAssertEqual(try clone.git("tag"), "v1\nv2")
    }
}

/// A fetch waits on the network; staging in the same working tree must not wait for it.
final class FetchQueueTests: XCTestCase {
    func testStagingDoesNotWaitForASlowFetch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-fetch-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let origin = try FixtureRepo(at: base.appendingPathComponent("origin"))
        try origin.commit("one")
        let local = try FixtureRepo(at: base.appendingPathComponent("local"))
        try local.commit("local")
        try local.git("remote", "add", "origin", origin.path)
        try local.git("config", "remote.origin.uploadpack", "sleep 3; git-upload-pack")
        let repository = local.repository

        let fetch = Task { try await repository.fetch(.remote("origin", prune: false)) }
        try await Task.sleep(for: .milliseconds(200))
        try local.write("new.txt", "new\n")
        let started = Date()
        try await repository.stage(["new.txt"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await fetch.value
    }
}
