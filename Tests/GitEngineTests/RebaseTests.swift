import XCTest
@testable import GitEngine

final class RebaseTests: XCTestCase {
    /// main: base - m1 (touches shared.txt); parent: base - p1; stacked: p1 - s1 - s2 (s2 touches shared.txt when `clash`).
    private func stackedFixture(clash: Bool) throws -> (fixture: FixtureRepo, base: String, main: String, parent: String) {
        let fixture = try FixtureRepo()
        let base = try fixture.commit("base", file: "shared.txt", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "parent")
        let parent = try fixture.commit("p1", file: "parent.txt")
        try fixture.git("switch", "-q", "-c", "stacked")
        try fixture.commit("s1", file: "s1.txt")
        try fixture.commit("s2", file: clash ? "shared.txt" : "s2.txt", contents: "stacked\n")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "shared.txt", contents: "main\n")
        try fixture.git("switch", "-q", "stacked")
        return (fixture, base, main, parent)
    }

    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    func testOntoMovesExactlyTheCommitsAfterTheOldBase() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: false)
        defer { fixture.remove() }
        let repo = fixture.repository

        let moving = try await repo.commitCount(from: parent, to: "stacked")
        XCTAssertEqual(moving, 2)
        try await repo.rebase(onto: main, from: parent, branch: "stacked")

        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "s1"], "p1 stays behind, only s1 and s2 move")
        XCTAssertEqual(try fixture.git("rev-parse", "stacked~2"), main)
        XCTAssertEqual(try fixture.git("rev-parse", "parent"), parent, "the old base branch is untouched")
        let progress = await repo.operationInProgress()
        XCTAssertNil(progress)
    }

    func testConflictStaysInProgressWithItsStepAndContinueFinishesAfterResolving() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: true)
        defer { fixture.remove() }
        let repo = fixture.repository

        do {
            try await repo.rebase(onto: main, from: parent, branch: "stacked")
            XCTFail("s2 conflicts with m1")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
        }
        let progress = await repo.operationInProgress()
        let s2 = try fixture.git("rev-parse", "stacked")
        XCTAssertEqual(progress, OperationProgress(kind: .rebase, step: 2, total: 2, branch: "stacked", onto: main, commit: nil, stop: .conflict(commit: s2, subject: "s2")))
        let status = try await repo.status()
        XCTAssertEqual(status.conflicted.map(\.path), ["shared.txt"])

        try fixture.write("shared.txt", "resolved\n")
        try fixture.git("add", "shared.txt")
        try await repo.continueOperation(.rebase)

        let after = await repo.operationInProgress()
        XCTAssertNil(after)
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s2", "s1"])
        XCTAssertEqual(try fixture.git("show", "stacked:shared.txt"), "resolved")
    }

    func testAbortRestoresTheBranchAndSkipDropsTheStoppedCommit() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: true)
        defer { fixture.remove() }
        let repo = fixture.repository
        let before = try fixture.git("rev-parse", "stacked")

        try? await repo.rebase(onto: main, from: parent, branch: "stacked")
        try await repo.abortOperation(.rebase)
        XCTAssertEqual(try fixture.git("rev-parse", "stacked"), before)
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "HEAD"), "stacked")
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
        let aborted = await repo.operationInProgress()
        XCTAssertNil(aborted)

        try? await repo.rebase(onto: main, from: parent, branch: "stacked")
        try await repo.skipOperation(.rebase)
        XCTAssertEqual(try subjects(fixture, "main..stacked"), ["s1"])
    }

    func testCherryPickAndRevertConflictsAreReported() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "other")
        let picked = try fixture.commit("other", contents: "other\n")
        try fixture.git("switch", "-q", "main")
        try fixture.commit("main", contents: "main\n")
        let repo = fixture.repository
        let commits = try await repo.collectLog()

        try? await repo.cherryPick(try XCTUnwrap(commits.first { $0.id == picked }))
        let picking = await repo.operationInProgress()
        XCTAssertEqual(picking, OperationProgress(kind: .cherryPick, step: nil, total: nil, branch: nil, onto: nil, commit: picked))
        try await repo.abortOperation(.cherryPick)

        let reverted = try fixture.git("rev-parse", "HEAD~1")
        try? await repo.revert(try XCTUnwrap(commits.first { $0.id == reverted }))
        let reverting = await repo.operationInProgress()
        XCTAssertEqual(reverting?.kind, .revert)
        XCTAssertEqual(reverting?.commit, reverted)
        try await repo.abortOperation(.revert)
        let none = await repo.operationInProgress()
        XCTAssertNil(none)
    }

    func testApplyBackendProgressAndProgressInALinkedWorktree() async throws {
        let (fixture, _, main, parent) = try stackedFixture(clash: true)
        defer { fixture.remove() }
        let linked = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-linked-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try fixture.git("switch", "-q", "main")
        try fixture.git("worktree", "add", "-q", linked, "stacked")
        let repo = Repository(path: linked)

        _ = try? await repo.runner.runWrite(["-c", "rebase.updateRefs=false", "rebase", "--apply", "--onto", main, parent, "stacked"])
        let progress = await repo.operationInProgress()
        XCTAssertEqual(progress?.kind, .rebase)
        XCTAssertEqual(progress?.step, 2)
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.branch, "stacked")
        let mainWorktree = await fixture.repository.operationInProgress()
        XCTAssertNil(mainWorktree, "the rebase belongs to the linked worktree only")
    }

    func testResolveCommitAcceptsRefsAndShasOnly() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let head = try fixture.commit("one")
        try fixture.git("tag", "-a", "v1", "-m", "v1")
        let repo = fixture.repository

        let byTag = await repo.resolveCommit("v1")
        let byPrefix = await repo.resolveCommit(String(head.prefix(7)))
        let unknown = await repo.resolveCommit("nope")
        let option = await repo.resolveCommit("--all")
        XCTAssertEqual(byTag, head, "an annotated tag is peeled to its commit")
        XCTAssertEqual(byPrefix, head)
        XCTAssertNil(unknown)
        XCTAssertNil(option)
    }

    // MARK: Already applied, empty steps and failures

    /// feature: x, y, f, w after the base; main has x cherry-picked and its own change of f.
    private func partlyAppliedFixture() throws -> (fixture: FixtureRepo, base: String) {
        let fixture = try FixtureRepo()
        let base = try fixture.commit("Initial commit", file: "f", contents: "base\n")
        try fixture.git("switch", "-q", "-c", "feature")
        let x = try fixture.commit("Add x", file: "x")
        try fixture.commit("Add y", file: "y")
        try fixture.commit("Change f on feature", file: "f", contents: "feature\n")
        try fixture.commit("Add w", file: "w")
        try fixture.git("switch", "-q", "main")
        try fixture.git("cherry-pick", x)
        try fixture.commit("Change f on main", file: "f", contents: "main\n")
        try fixture.git("switch", "-q", "feature")
        return (fixture, base)
    }

    func testOntoCountsAlreadyAppliedCommitsAndContinueSkipsAStepResolvedToHead() async throws {
        let (fixture, base) = try partlyAppliedFixture()
        defer { fixture.remove() }
        let repo = fixture.repository

        do {
            try await repo.rebase(onto: "main", from: base, branch: "feature")
            XCTFail("f conflicts")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict)
            XCTAssertEqual(OperationReport(output: error.stderr).alreadyApplied, 1, error.stderr)
            XCTAssertEqual(GitFailure(output: error.stderr), .couldNotApply(commit: String(try fixture.git("rev-parse", "feature~1").prefix(7)), subject: "Change f on feature"))
        }
        // Resolved in favour of the new base: nothing is left of this step.
        try fixture.git("checkout", "HEAD", "--", "f")

        let report = try await repo.continueOperation(.rebase)

        XCTAssertTrue(report.skippedEmptyStep)
        let after = await repo.operationInProgress()
        XCTAssertNil(after)
        XCTAssertEqual(try subjects(fixture, "main..feature"), ["Add w", "Add y"])
    }

    func testCherryPickContinueSkipsAStepResolvedToHeadAndDropsAnAlreadyAppliedCommit() async throws {
        let (fixture, _) = try partlyAppliedFixture()
        defer { fixture.remove() }
        try fixture.git("switch", "-q", "main")
        let repo = fixture.repository
        let commits = try await repo.collectLog()
        let head = try fixture.git("rev-parse", "HEAD")

        try? await repo.cherryPick(try XCTUnwrap(commits.first { $0.subject == "Change f on feature" }))
        let picking = await repo.operationInProgress()
        XCTAssertEqual(picking?.kind, .cherryPick)
        try fixture.git("checkout", "HEAD", "--", "f")
        let report = try await repo.continueOperation(.cherryPick)
        XCTAssertTrue(report.skippedEmptyStep)
        let after = await repo.operationInProgress()
        XCTAssertNil(after, "continuing did not stop at git's empty cherry-pick")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), head)

        let version = await repo.gitVersion()
        guard let version, version >= Repository.cherryPickEmptyDrop else { return }
        try await repo.cherryPick(try XCTUnwrap(commits.first { $0.subject == "Add x" && $0.parents.first != head }))
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), head, "x is already on main and is dropped instead of stopping")
        let none = await repo.operationInProgress()
        XCTAssertNil(none)
    }

    func testContinueAtAnEditStopIsNeverTakenForAnEmptyStep() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base")
        try fixture.commit("one", file: "one.txt")
        try fixture.commit("two", file: "two.txt")
        let repo = fixture.repository
        var plan = RebasePlan(base: base, commits: try await repo.rebaseCommits(after: base))
        plan.steps[0].action = .edit
        _ = try await repo.startInteractiveRebase(plan)

        let report = try await repo.continueOperation(.rebase)

        XCTAssertFalse(report.skippedEmptyStep)
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["two", "one"])
    }

    func testFailuresAreReadFromGitsOutput() {
        let rebase = """
        Rebasing (1/4)\rdropping f4544f9c3717e70e564c3afebf9433395cb79bb7 Add x -- patch contents already upstream
        Rebasing (2/4)\rRebasing (3/4)\rAuto-merging f
        CONFLICT (content): Merge conflict in f
        error: could not apply 11f8174... Add an ETP tab to Produktfinder
        hint: Resolve all conflicts manually, mark them as resolved with
        hint: "git add/rm <conflicted_files>", then run "git rebase --continue".
        Could not apply 11f8174... # Add an ETP tab to Produktfinder
        """
        XCTAssertEqual(GitFailure(output: rebase), .couldNotApply(commit: "11f8174", subject: "Add an ETP tab to Produktfinder"))
        XCTAssertEqual(OperationReport(output: rebase).alreadyApplied, 1)
        XCTAssertEqual(OperationReport(output: "warning: skipped previously applied commit 1a2b3c4\nwarning: skipped previously applied commit 5d6e7f8\nhint: use --reapply-cherry-picks").alreadyApplied, 2)
        XCTAssertEqual(GitFailure(output: "error: Your local changes to the following files would be overwritten by checkout:\n\tsrc/a.swift\n\tdocs/b.md\nPlease commit your changes or stash them before you switch branches.\nAborting"), .localChangesInTheWay(["src/a.swift", "docs/b.md"]))
        XCTAssertEqual(GitFailure(output: "error: cannot rebase: You have unstaged changes.\nerror: Please commit or stash them."), .uncommittedChanges)
        XCTAssertEqual(GitFailure(output: "Auto-merging f\nCONFLICT (content): Merge conflict in f\nAutomatic merge failed; fix conflicts and then commit the result."), .conflicts(["f"]))
        XCTAssertEqual(GitFailure(output: "The previous cherry-pick is now empty, possibly due to conflict resolution."), .emptyStep)
        XCTAssertEqual(GitFailure(output: "hint: something\nfatal: invalid upstream 'nope'"), .message("invalid upstream 'nope'"))
    }
}
