import XCTest
@testable import GitEngine

final class CommitActionsTests: XCTestCase {
    private func commit(_ id: String, in fixture: FixtureRepo) async throws -> Commit {
        let commits = try await fixture.repository.collectLog()
        return try XCTUnwrap(commits.first { $0.id == id })
    }

    private func read(_ fixture: FixtureRepo, _ file: String) throws -> String {
        try String(contentsOf: fixture.url.appendingPathComponent(file), encoding: .utf8)
    }

    private func refExists(_ fixture: FixtureRepo, _ ref: String) -> Bool {
        (try? fixture.git("rev-parse", "-q", "--verify", ref)) != nil
    }

    // MARK: Branches

    func testCreateBranchWithAndWithoutCheckoutAndRefuseAnExistingName() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("first")
        try fixture.commit("second")
        let repo = fixture.repository

        try await repo.createBranch("kept", at: first, checkout: false)
        XCTAssertEqual(try fixture.git("rev-parse", "kept"), first)
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "HEAD"), "main")

        try await repo.createBranch("feature", at: first, checkout: true)
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "HEAD"), "feature")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), first)

        do {
            try await repo.createBranch("kept", at: first, checkout: false)
            XCTFail("an existing branch must not be overwritten")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("already exists"), error.stderr)
        }
    }

    func testResetModesKeepOrDiscardTheDirtyTree() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base", contents: "base\n")
        try fixture.commit("top", contents: "top\n")
        let repo = fixture.repository

        try fixture.write("file.txt", "dirty\n")
        try await repo.resetCurrentBranch(to: base, mode: .soft)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), base)
        XCTAssertEqual(try fixture.git("diff", "--cached", "--name-only"), "file.txt", "soft keeps the reset commit's change staged")
        XCTAssertEqual(try read(fixture, "file.txt"), "dirty\n")

        try await repo.resetCurrentBranch(to: base, mode: .mixed)
        XCTAssertEqual(try fixture.git("diff", "--cached", "--name-only"), "", "mixed empties the index")
        XCTAssertEqual(try read(fixture, "file.txt"), "dirty\n", "mixed keeps the working tree")

        try await repo.resetCurrentBranch(to: base, mode: .hard)
        XCTAssertEqual(try read(fixture, "file.txt"), "base\n", "hard discards the uncommitted edit")
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
    }

    func testRebaseMovesTheBranchAndStopsOnAConflict() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "shared.txt", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("feature", file: "feature.txt")
        try fixture.git("switch", "-q", "main")
        let clean = try fixture.commit("main clean", file: "other.txt")
        try fixture.git("switch", "-q", "feature")
        let repo = fixture.repository

        try await repo.rebaseCurrentBranch(onto: clean)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD~1"), clean)

        try fixture.git("switch", "-q", "main")
        let clash = try fixture.commit("main clash", file: "shared.txt", contents: "main\n")
        try fixture.git("switch", "-q", "feature")
        try fixture.commit("feature clash", file: "shared.txt", contents: "feature\n")
        do {
            try await repo.rebaseCurrentBranch(onto: clash)
            XCTFail("conflicting edits must stop the rebase")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
        }
        XCTAssertTrue(refExists(fixture, "REBASE_HEAD"), "the rebase must stay in progress, not be aborted")
    }

    func testPublishedCommitCountCountsRewrittenCommitsInTheUpstream() async throws {
        let upstream = try FixtureRepo(name: "upstream")
        defer { upstream.remove() }
        let base = try upstream.commit("base")
        let pushed = try upstream.commit("pushed")

        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", upstream.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("switch", "-q", "-c", "main", "--track", "origin/main")
        let local = try fixture.commit("local only", file: "local.txt")
        let repo = fixture.repository

        let rewritesLocalOnly = await repo.publishedCommitCount(rewrittenBy: pushed)
        let rewritesPushed = await repo.publishedCommitCount(rewrittenBy: base)
        let rewritesNothing = await repo.publishedCommitCount(rewrittenBy: local)
        XCTAssertEqual(rewritesLocalOnly, 0)
        XCTAssertEqual(rewritesPushed, 1)
        XCTAssertEqual(rewritesNothing, 0)

        try fixture.git("switch", "-q", "-c", "untracked")
        let withoutUpstream = await repo.publishedCommitCount(rewrittenBy: base)
        XCTAssertEqual(withoutUpstream, 0)
    }

    // MARK: History

    func testCherryPickAppliesACommitAndLeavesAConflictInProgress() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "shared.txt", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "feature")
        let clean = try fixture.commit("feature file", file: "feature.txt", contents: "feature\n")
        let clash = try fixture.commit("feature clash", file: "shared.txt", contents: "feature\n")
        try fixture.git("switch", "-q", "main")
        try fixture.commit("main clash", file: "shared.txt", contents: "main\n")
        let repo = fixture.repository

        try await repo.cherryPick(try await commit(clean, in: fixture))
        XCTAssertEqual(try read(fixture, "feature.txt"), "feature\n")
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%s"), "feature file")

        do {
            try await repo.cherryPick(try await commit(clash, in: fixture))
            XCTFail("conflicting edits must stop the cherry-pick")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
        }
        XCTAssertTrue(refExists(fixture, "CHERRY_PICK_HEAD"), "the cherry-pick must stay in progress")
    }

    func testCherryPickOfAMergeTakesItRelativeToTheFirstParent() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "side")
        try fixture.commit("side", file: "side.txt")
        try fixture.git("switch", "-q", "-c", "target", "main")
        try fixture.git("switch", "-q", "main")
        try fixture.commit("main", file: "main.txt")
        try fixture.git("merge", "-q", "--no-ff", "--no-edit", "side")
        let merge = try fixture.git("rev-parse", "HEAD")
        try fixture.git("switch", "-q", "target")

        try await fixture.repository.cherryPick(try await commit(merge, in: fixture))
        XCTAssertEqual(try fixture.git("diff", "--name-only", "HEAD~1", "HEAD"), "side.txt")
    }

    func testRevertUndoesACommitAndLeavesAConflictInProgress() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "shared.txt", contents: "one\n")
        let added = try fixture.commit("add file", file: "added.txt")
        let edit = try fixture.commit("edit", file: "shared.txt", contents: "two\n")
        try fixture.commit("edit again", file: "shared.txt", contents: "three\n")
        let repo = fixture.repository

        try await repo.revert(try await commit(added, in: fixture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("added.txt").path))
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%s"), "Revert \"add file\"")

        do {
            try await repo.revert(try await commit(edit, in: fixture))
            XCTFail("the later edit must make the revert conflict")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
        }
        XCTAssertTrue(refExists(fixture, "REVERT_HEAD"), "the revert must stay in progress")
    }

    func testPatchAppliesElsewhereWithAm() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base")
        let change = try fixture.commit("change", file: "new.txt", contents: "ü\n")
        let patch = try await fixture.repository.patch(of: change)
        XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("Subject: [PATCH] change"))

        try fixture.git("switch", "-q", "-c", "replay", base)
        let file = fixture.url.appendingPathComponent("change.patch")
        try patch.write(to: file)
        try fixture.git("am", "-q", file.path)
        XCTAssertEqual(try read(fixture, "new.txt"), "ü\n")
    }

    // MARK: Tags

    func testLightweightAndAnnotatedTagsAndRefuseAnExistingName() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("first")
        try fixture.commit("second")
        let repo = fixture.repository

        try await repo.createTag("v1", at: first)
        XCTAssertEqual(try fixture.git("cat-file", "-t", "v1"), "commit")
        try await repo.createTag("v1.1", at: first, message: "Release 1.1\n\n# keeps hash lines")
        XCTAssertEqual(try fixture.git("cat-file", "-t", "v1.1"), "tag")
        XCTAssertEqual(try fixture.git("rev-parse", "v1.1^{commit}"), first)
        XCTAssertTrue(try fixture.git("tag", "-l", "--format=%(contents)", "v1.1").contains("Release 1.1"))

        do {
            try await repo.createTag("v1", at: first)
            XCTFail("an existing tag must not be overwritten")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("already exists"), error.stderr)
        }
    }

    // MARK: Worktrees

    func testAddWorktreeDetachedOrOnANewBranch() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("first")
        try fixture.commit("second")
        let repo = fixture.repository
        let detached = fixture.url.appendingPathExtension("detached").path
        let branched = fixture.url.appendingPathExtension("branched").path
        defer {
            try? FileManager.default.removeItem(atPath: detached)
            try? FileManager.default.removeItem(atPath: branched)
        }

        try await repo.addWorktree(at: detached, commit: first, newBranch: nil)
        let detachedRepo = Repository(path: detached)
        let detachedStatus = try await detachedRepo.status()
        XCTAssertNil(detachedStatus.branch.branch)
        XCTAssertEqual(detachedStatus.branch.headSHA, first)

        try await repo.addWorktree(at: branched, commit: first, newBranch: "spike")
        let branchedStatus = try await Repository(path: branched).status()
        XCTAssertEqual(branchedStatus.branch.branch, "spike")

        do {
            try await repo.addWorktree(at: fixture.url.appendingPathExtension("again").path, commit: first, newBranch: "spike")
            XCTFail("an existing branch name must be refused")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("already exists"), error.stderr)
        }
    }
}
