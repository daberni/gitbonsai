import XCTest
@testable import GitEngine

final class RemoteConfigTests: XCTestCase {
    /// A repository with branch main and a bare copy of it to add as a remote.
    private func repositoryAndBare() throws -> (local: FixtureRepo, bare: String, holder: FixtureRepo) {
        let local = try FixtureRepo(name: "remotes")
        try local.commit("one")
        let holder = try FixtureRepo(name: "remotes-bare")
        let bare = holder.path + "/bare repo.git"
        try holder.git("clone", "-q", "--bare", local.path, bare)
        return (local, bare, holder)
    }

    private func remoteRefs(_ fixture: FixtureRepo) throws -> [String] {
        try fixture.git("for-each-ref", "--format=%(refname:lstrip=2)", "refs/remotes").split(separator: "\n").map(String.init)
    }

    func testAddFetchRenameSetURLAndRemove() async throws {
        let (local, bare, holder) = try repositoryAndBare()
        defer { local.remove(); holder.remove() }
        let repo = local.repository

        try await repo.addRemote("upstream", url: bare)
        let added = try await repo.remotes()
        XCTAssertEqual(added, ["upstream"])
        XCTAssertEqual(try remoteRefs(local), [], "adding fetches nothing")
        try await repo.fetch(.remote("upstream", prune: false))
        try local.git("branch", "--set-upstream-to=upstream/main", "main")

        try await repo.renameRemote("upstream", to: "team/ü")
        let renamed = try await repo.remotes()
        XCTAssertEqual(renamed, ["team/ü"])
        XCTAssertEqual(try remoteRefs(local), ["team/ü/HEAD", "team/ü/main"])
        XCTAssertEqual(try local.git("config", "branch.main.remote"), "team/ü", "the upstream follows the rename")

        try await repo.setRemoteURL("team/ü", url: "https://example.invalid/other.git")
        let urls = try await repo.remoteURLs()
        XCTAssertEqual(urls.remotes, [RemoteURLs.Remote(name: "team/ü", url: "https://example.invalid/other.git")])

        try await repo.removeRemote("team/ü")
        let removed = try await repo.remotes()
        XCTAssertEqual(removed, [])
        XCTAssertEqual(try remoteRefs(local), [], "its remote-tracking branches go with it")
    }

    func testAddingAnExistingRemoteFailsAndLeavesItsURL() async throws {
        let (local, bare, holder) = try repositoryAndBare()
        defer { local.remove(); holder.remove() }
        let repo = local.repository
        try await repo.addRemote("origin", url: bare)

        do {
            try await repo.addRemote("origin", url: "https://example.invalid/x.git")
            XCTFail("git refuses a second remote of the same name")
        } catch is GitError {}
        XCTAssertEqual(try local.git("config", "remote.origin.url"), bare)
    }

    func testRemoteNameValidation() async throws {
        let fixture = try FixtureRepo(name: "remote-names")
        defer { fixture.remove() }
        let repo = fixture.repository
        for name in ["origin", "team/fork", "ü-remote"] {
            let valid = await repo.isValidRemoteName(name)
            XCTAssertTrue(valid, name)
        }
        for name in ["", "with space", "a..b", "-option", "trailing/", "x:y"] {
            let valid = await repo.isValidRemoteName(name)
            XCTAssertFalse(valid, name)
        }
    }

    /// Undoing a removal brings back every setting of the remote, the upstreams of the branches that tracked it and, by fetching, its remote-tracking branches.
    func testRestoringARemovedRemoteBringsBackConfigUpstreamsAndBranches() async throws {
        let (local, bare, holder) = try repositoryAndBare()
        defer { local.remove(); holder.remove() }
        let repo = local.repository
        try await repo.addRemote("team/ü", url: bare)
        try local.git("config", "--add", "remote.team/ü.fetch", "+refs/tags/*:refs/tags/*")
        try local.git("config", "remote.team/ü.pushurl", "https://example.invalid/push.git")
        try await repo.fetch(.remote("team/ü", prune: false))
        try local.git("branch", "--set-upstream-to=team/ü/main", "main")
        try local.git("branch", "other")
        let config = try local.git("config", "--local", "--get-regexp", "^(remote|branch)\\.")

        let removed = try await repo.removeRemoteKeepingConfig("team/ü")
        XCTAssertEqual(try remoteRefs(local), [])
        XCTAssertThrowsError(try local.git("config", "branch.main.remote"))

        try await repo.restoreRemote(removed)

        XCTAssertEqual(try local.git("config", "--local", "--get-regexp", "^(remote|branch)\\."), config)
        XCTAssertEqual(try remoteRefs(local), ["team/ü/HEAD", "team/ü/main"])
        XCTAssertEqual(try local.git("symbolic-ref", "refs/remotes/team/ü/HEAD"), "refs/remotes/team/ü/main")
        let again = await repo.canRestoreRemote(removed)
        XCTAssertFalse(again, "the remote exists again, so there is nothing left to undo")
    }
}
