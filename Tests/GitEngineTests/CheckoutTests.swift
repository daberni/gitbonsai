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

        try await repo.checkout(.remoteBranch(remote: "origin", branch: "feature/login"), stashMessage: "carried by the test")
        XCTAssertEqual(try currentBranch(fixture), "feature/login")
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "feature/login@{upstream}"), "origin/feature/login")

        let localTip = try fixture.commit("local only", file: "local.txt")
        try await repo.checkout(.localBranch("main"), stashMessage: "carried by the test")
        XCTAssertEqual(try currentBranch(fixture), "main")

        try await repo.checkout(.remoteBranch(remote: "origin", branch: "feature/login"), stashMessage: "carried by the test")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), localTip, "the existing local branch must be reused, not reset to the remote tip")

        try await repo.checkout(.commit(remoteTip), stashMessage: "carried by the test")
        XCTAssertEqual(try currentBranch(fixture), "HEAD")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), remoteTip)
    }

    private func contents(_ fixture: FixtureRepo, _ path: String) throws -> String {
        try String(contentsOf: fixture.url.appendingPathComponent(path), encoding: .utf8)
    }

    func testLocalChangesComeAlongEvenWhereGitAloneWouldRefuse() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "shared.txt", contents: "one\ntwo\nthree\n")
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("feature edit", file: "shared.txt", contents: "one\ntwo\nthree\nfour\n")
        try fixture.git("switch", "-q", "main")
        try fixture.write("shared.txt", "ONE\ntwo\nthree\n")
        try fixture.write("staged.txt", "staged\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("untracked.txt", "new\n")
        let repo = Repository(path: fixture.path)

        try await repo.checkout(.localBranch("feature"), stashMessage: "carried by the test")
        XCTAssertEqual(try currentBranch(fixture), "feature")
        XCTAssertEqual(try contents(fixture, "shared.txt"), "ONE\ntwo\nthree\nfour\n", "the edit merges onto the target's version")
        XCTAssertEqual(try contents(fixture, "untracked.txt"), "new\n")
        XCTAssertEqual(try fixture.git("diff", "--cached", "--name-only"), "staged.txt", "staged changes stay staged")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    func testConflictingCarriedChangesStayInTheStash() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "shared.txt", contents: "one\n")
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("feature edit", file: "shared.txt", contents: "two\n")
        try fixture.git("switch", "-q", "main")
        try fixture.write("shared.txt", "dirty\n")
        let repo = Repository(path: fixture.path)

        do {
            try await repo.checkout(.localBranch("feature"), stashMessage: "carried to feature")
            XCTFail("popping the edit onto feature's version must conflict")
        } catch let conflict as CarriedChangesConflict {
            XCTAssertEqual(try currentBranch(fixture), "feature", "the switch itself happened")
            XCTAssertEqual(try fixture.git("stash", "list", "--format=%gs"), "On main: \(conflict.stashMessage)")
            XCTAssertEqual(conflict.stashMessage, "carried to feature")
            XCTAssertEqual(conflict.conflictedPaths, ["shared.txt"])
            XCTAssertTrue(try contents(fixture, "shared.txt").contains("<<<<<<<"), "the conflict is in the working tree")
        }
    }

    func testFailedSwitchRestoresTheChanges() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.write("file.txt", "dirty\n")
        let repo = Repository(path: fixture.path)

        do {
            try await repo.checkout(.localBranch("missing"), stashMessage: "carried by the test")
            XCTFail("there is no branch to switch to")
        } catch is GitError {}
        XCTAssertEqual(try currentBranch(fixture), "main")
        XCTAssertEqual(try contents(fixture, "file.txt"), "dirty\n")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    func testDivergedBranchIsResetToItsRemoteAndKeepsChanges() async throws {
        let upstream = try FixtureRepo(name: "upstream")
        defer { upstream.remove() }
        try upstream.commit("base")
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", upstream.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("switch", "-q", "-c", "main", "--track", "origin/main")
        try fixture.commit("local only", file: "local.txt")
        try fixture.git("switch", "-q", "-c", "work")
        let remoteTip = try upstream.commit("remote work", file: "remote.txt")
        try fixture.git("fetch", "-q", "origin")
        try fixture.write("untracked.txt", "new\n")
        let repo = Repository(path: fixture.path)

        do {
            try await repo.checkout(.fastForward(branch: "main", to: "origin/main"), stashMessage: "carried by the test")
            XCTFail("a diverged branch cannot fast-forward")
        } catch is GitError {}

        try await repo.checkout(.localBranch("work"), stashMessage: "carried by the test")
        try await repo.checkout(.reset(branch: "main", to: "origin/main"), stashMessage: "carried by the test")
        XCTAssertEqual(try currentBranch(fixture), "main")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), remoteTip)
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "main@{upstream}"), "origin/main")
        XCTAssertEqual(try contents(fixture, "untracked.txt"), "new\n")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    /// `topic` and the commit it should fast-forward to have both moved on, so `merge --ff-only` refuses after the switch.
    private func divergedTopic(_ fixture: FixtureRepo) throws -> String {
        try fixture.commit("base", file: "shared.txt", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "topic")
        try fixture.commit("topic only", file: "topic.txt")
        try fixture.git("switch", "-q", "-c", "elsewhere", "main")
        let other = try fixture.commit("elsewhere only", file: "elsewhere.txt")
        try fixture.git("switch", "-q", "main")
        return other
    }

    func testAFailedFastForwardReturnsToTheOriginalBranchWithTheChanges() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let target = try divergedTopic(fixture)
        try fixture.write("shared.txt", "edited\n")
        try fixture.write("untracked.txt", "new\n")

        do {
            try await fixture.repository.checkout(.fastForward(branch: "topic", to: target), stashMessage: "carried by the test")
            XCTFail("a fast-forward of diverged branches succeeded")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("Not possible to fast-forward") || error.stderr.contains("fast-forward"), error.stderr)
        }
        XCTAssertEqual(try currentBranch(fixture), "main")
        XCTAssertEqual(try contents(fixture, "shared.txt"), "edited\n")
        XCTAssertEqual(try contents(fixture, "untracked.txt"), "new\n")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    /// A post-checkout hook recreates an untracked file the stash carries, so putting the stash back fails after the switch failed.
    func testAFailedPutBackNamesTheStashThatKeepsTheChanges() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let target = try divergedTopic(fixture)
        let hook = fixture.url.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\necho hook > untracked.txt\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try fixture.write("untracked.txt", "new\n")

        do {
            try await fixture.repository.checkout(.fastForward(branch: "topic", to: target), stashMessage: "carried by the test")
            XCTFail("a fast-forward of diverged branches succeeded")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("carried by the test"), error.stderr)
        }
        XCTAssertTrue(try fixture.git("stash", "list").contains("carried by the test"))
    }
}
