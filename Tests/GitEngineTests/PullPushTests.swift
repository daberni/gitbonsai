import XCTest
@testable import GitEngine

final class PullPushTests: XCTestCase {
    /// A bare remote with one commit on main, the clone under test, and a second clone that moves the remote on its own.
    private struct Setup {
        let remote: FixtureRepo
        let local: FixtureRepo
        let other: FixtureRepo
        var bare: String { remote.path + "/bare.git" }

        func remove() { [remote, local, other].forEach { $0.remove() } }
    }

    private func setUpRemote() throws -> Setup {
        let remote = try FixtureRepo(name: "remote")
        try remote.commit("base")
        let bare = remote.path + "/bare.git"
        try remote.git("clone", "-q", "--bare", remote.path, bare)
        let local = try FixtureRepo(name: "local")
        let other = try FixtureRepo(name: "other")
        for clone in [local, other] {
            try clone.git("remote", "add", "origin", bare)
            try clone.git("fetch", "-q", "origin")
            try clone.git("reset", "-q", "--hard", "origin/main")
            try clone.git("branch", "-q", "--set-upstream-to=origin/main", "main")
        }
        return Setup(remote: remote, local: local, other: other)
    }

    private func remoteHead(_ setup: Setup, _ branch: String = "main") throws -> String {
        try setup.remote.git("--git-dir", setup.bare, "rev-parse", branch)
    }

    func testFastForwardOnlyRefusesDivergedBranchesAndLeavesThemAlone() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "main")
        let mine = try setup.local.commit("mine", file: "mine.txt")

        do {
            try await setup.local.repository.pull(PullVariant(mode: .fastForwardOnly))
            XCTFail("a diverged pull must not succeed with --ff-only")
        } catch let error as GitError {
            XCTAssertTrue(error.isDivergedPull, error.stderr)
        }
        XCTAssertEqual(try setup.local.git("rev-parse", "HEAD"), mine)
        let progress = await setup.local.repository.operationInProgress()
        XCTAssertNil(progress)
    }

    func testFastForwardOnlyMovesABranchThatIsOnlyBehind() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "main")

        try await setup.local.repository.pull(PullVariant(mode: .fastForwardOnly))
        XCTAssertEqual(try setup.local.git("rev-parse", "HEAD"), try remoteHead(setup))
    }

    func testRebasePullReplaysLocalCommitsOnTopOfTheUpstream() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.local.commit("mine", file: "mine.txt")

        try await setup.local.repository.pull(PullVariant(mode: .rebase))
        XCTAssertEqual(try setup.local.git("log", "--format=%s", "-3"), "mine\ntheirs\nbase")
        XCTAssertEqual(try setup.local.git("rev-parse", "HEAD^"), try remoteHead(setup))
        XCTAssertEqual(try setup.local.git("rev-list", "--merges", "--count", "HEAD"), "0")
    }

    func testMergePullRecordsAMergeCommitAndAConflictLeavesTheMergeInProgress() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.local.commit("mine", file: "mine.txt")
        // A configured ff-only must not stop the explicit merge variant.
        try setup.local.git("config", "pull.ff", "only")

        try await setup.local.repository.pull(PullVariant(mode: .merge))
        XCTAssertEqual(try setup.local.git("rev-list", "--parents", "-1", "HEAD").split(separator: " ").count, 3)

        try setup.other.commit("theirs again", file: "shared.txt", contents: "theirs\n")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.local.commit("mine again", file: "shared.txt", contents: "mine\n")
        do {
            try await setup.local.repository.pull(PullVariant(mode: .merge))
            XCTFail("conflicting merge must throw")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
        }
        let progress = await setup.local.repository.operationInProgress()
        XCTAssertEqual(progress?.kind, .merge)
        XCTAssertEqual(progress?.commit, try remoteHead(setup))
        try await setup.local.repository.abortOperation(.merge)
        let after = await setup.local.repository.operationInProgress()
        XCTAssertNil(after)
    }

    /// Every variant carries a dirty working tree, including staged changes and untracked files, through the pull.
    func testEveryPullModeCarriesLocalChanges() async throws {
        for mode in PullMode.allCases {
            let setup = try setUpRemote()
            defer { setup.remove() }
            try setup.other.commit("theirs", file: "theirs.txt")
            try setup.other.git("push", "-q", "origin", "main")
            // A rebase and a merge need a local commit to do more than fast-forward; fast-forward only must not have one.
            if mode != .fastForwardOnly { try setup.local.commit("mine", file: "mine.txt") }
            try setup.local.write("file.txt", "edited\n")
            try setup.local.write("staged.txt", "staged\n")
            try setup.local.git("add", "staged.txt")
            try setup.local.write("untracked.txt", "new\n")

            let result = try await setup.local.repository.pull(PullVariant(mode: mode))

            XCTAssertFalse(result.localChangesConflicted, "\(mode)")
            XCTAssertEqual(try setup.local.git("merge-base", "--is-ancestor", try remoteHead(setup), "HEAD"), "", "\(mode) took the upstream")
            XCTAssertEqual(try setup.local.git("status", "--porcelain"), " M file.txt\nA  staged.txt\n?? untracked.txt", "\(mode)")
            XCTAssertEqual(try setup.local.git("stash", "list"), "", "\(mode) left no stash behind")
        }
    }

    /// Local changes that collide with the pulled commits: the pull itself succeeds, the conflicts are in the working tree and the stash stays.
    func testConflictingLocalChangesAreLeftInTheWorkingTreeWithTheStashKept() async throws {
        for mode in PullMode.allCases {
            let setup = try setUpRemote()
            defer { setup.remove() }
            try setup.other.commit("theirs", file: "file.txt", contents: "theirs\n")
            try setup.other.git("push", "-q", "origin", "main")
            if mode == .rebase { try setup.local.commit("mine", file: "mine.txt") }
            try setup.local.write("file.txt", "mine\n")

            let result = try await setup.local.repository.pull(PullVariant(mode: mode))

            XCTAssertTrue(result.localChangesConflicted, "\(mode)")
            XCTAssertEqual(try setup.local.git("merge-base", "--is-ancestor", try remoteHead(setup), "HEAD"), "", "\(mode) took the upstream")
            XCTAssertEqual(try setup.local.git("status", "--porcelain"), "UU file.txt", "\(mode)")
            XCTAssertTrue(try String(contentsOf: setup.local.url.appendingPathComponent("file.txt"), encoding: .utf8).contains("<<<<<<<"), "\(mode)")
            XCTAssertTrue(try setup.local.git("stash", "list").hasSuffix("autostash"), "\(mode)")
            let progress = await setup.local.repository.operationInProgress()
            XCTAssertNil(progress, "\(mode): the pull is finished, only the changes conflict")
        }
    }

    /// A refused fast-forward puts the local changes back as they were.
    func testRefusedPullRestoresLocalChanges() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.local.commit("mine", file: "mine.txt")
        try setup.local.write("file.txt", "edited\n")

        do {
            try await setup.local.repository.pull(PullVariant(mode: .fastForwardOnly))
            XCTFail("a diverged pull must not succeed with --ff-only")
        } catch let error as GitError {
            XCTAssertTrue(error.isDivergedPull, error.stderr)
        }
        XCTAssertEqual(try setup.local.git("status", "--porcelain"), " M file.txt")
        XCTAssertEqual(try setup.local.git("stash", "list"), "")
    }

    func testDefaultPullModeFollowsPullRebaseThenPullFF() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let repo = fixture.repository
        // Only values set here count: the developer's global configuration may set either key, and the local one wins.
        try fixture.git("config", "pull.rebase", "merges")
        var mode = await repo.defaultPullMode()
        XCTAssertEqual(mode, .rebase)
        try fixture.git("config", "pull.rebase", "false")
        try fixture.git("config", "pull.ff", "only")
        mode = await repo.defaultPullMode()
        XCTAssertEqual(mode, .fastForwardOnly)
        try fixture.git("config", "pull.ff", "true")
        mode = await repo.defaultPullMode()
        XCTAssertEqual(mode, .merge)
        try fixture.git("config", "--unset", "pull.ff")
        mode = await repo.defaultPullMode()
        XCTAssertEqual(mode, .merge)
    }

    /// The branch menu pushes a branch that is not checked out; the upstream goes to that branch, not to HEAD's.
    func testFirstPushOfABranchNotCheckedOutSetsItsUpstream() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let repo = setup.local.repository
        try setup.local.git("switch", "-q", "-c", "feature")
        let tip = try setup.local.commit("feature work", file: "feature.txt")
        try setup.local.git("switch", "-q", "-c", "elsewhere")

        try await repo.push(.branch("feature", remote: "origin", remoteBranch: "remote-feature", setUpstream: true, forceWithLease: false))

        XCTAssertEqual(try remoteHead(setup, "remote-feature"), tip)
        let pushed = await repo.upstream(of: "feature")
        XCTAssertEqual(pushed, Upstream(remote: "origin", branch: "remote-feature", ahead: 0, behind: 0))
        let current = await repo.upstream(of: "elsewhere")
        XCTAssertNil(current)
    }

    func testFirstPushSetsTheUpstreamAndCountsFollowCommits() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let repo = setup.local.repository
        try setup.local.git("switch", "-q", "-c", "feature")
        let tip = try setup.local.commit("feature work", file: "feature.txt")
        let none = await repo.upstream(of: "feature")
        XCTAssertNil(none)

        try await repo.push(.branch("feature", remote: "origin", remoteBranch: "feature", setUpstream: true, forceWithLease: false))
        XCTAssertEqual(try remoteHead(setup, "feature"), tip)
        let pushed = await repo.upstream(of: "feature")
        XCTAssertEqual(pushed, Upstream(remote: "origin", branch: "feature", ahead: 0, behind: 0))

        try setup.local.commit("two", file: "two.txt")
        try setup.local.commit("three", file: "three.txt")
        try setup.other.git("fetch", "-q", "origin")
        try setup.other.git("switch", "-q", "-c", "feature", "origin/feature")
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "feature")
        try await repo.fetch(.allRemotes)
        let diverged = await repo.upstream(of: "feature")
        XCTAssertEqual(diverged?.ahead, 2)
        XCTAssertEqual(diverged?.behind, 1)
    }

    func testRejectedPushIsRecognisedAndForceWithLeaseRefusesARemoteThatMovedSinceTheFetch() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        let repo = setup.local.repository
        try setup.other.commit("theirs", file: "theirs.txt")
        try setup.other.git("push", "-q", "origin", "main")
        try setup.local.commit("mine", file: "mine.txt")
        let push = PushVariant.branch("main", remote: "origin", remoteBranch: "main", setUpstream: false, forceWithLease: false)
        let force = PushVariant.branch("main", remote: "origin", remoteBranch: "main", setUpstream: false, forceWithLease: true)

        do {
            try await repo.push(push)
            XCTFail("a non-fast-forward push must be rejected")
        } catch let error as GitError {
            XCTAssertTrue(error.isRejectedNonFastForward, error.stderr)
        }
        // The remote moved past what the local remote-tracking branch knows, so the lease does not hold.
        let theirs = try remoteHead(setup)
        do {
            try await repo.push(force)
            XCTFail("the lease must refuse a remote branch that moved since the last fetch")
        } catch let error as GitError {
            XCTAssertTrue(error.isStaleLease, error.stderr)
        }
        XCTAssertEqual(try remoteHead(setup), theirs)

        // Once fetched, the lease names the remote's current commit and the push overwrites it.
        try await repo.fetch(.allRemotes)
        try await repo.push(force)
        XCTAssertEqual(try remoteHead(setup), try setup.local.git("rev-parse", "HEAD"))
    }

    func testPushTagsSendsLocalTags() async throws {
        let setup = try setUpRemote()
        defer { setup.remove() }
        try setup.local.git("tag", "v1")
        try await setup.local.repository.push(.tags(remote: "origin"))
        XCTAssertEqual(try setup.remote.git("--git-dir", setup.bare, "tag"), "v1")
    }
}
