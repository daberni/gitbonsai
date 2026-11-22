import XCTest
@testable import GitEngine

final class InteractiveRebaseTests: XCTestCase {
    /// main: base - a - b - c - d, each commit adding its own file.
    private func linearFixture(name: String = "irebase") throws -> (fixture: FixtureRepo, base: String) {
        let fixture = try FixtureRepo(name: name)
        let base = try fixture.commit("base", file: "base.txt")
        for name in ["a", "b", "c", "d"] { try fixture.commit(name, file: "\(name).txt") }
        return (fixture, base)
    }

    private func messages(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--reverse", "--format=%B%x1e", range).split(separator: "\u{1e}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--reverse", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    private func plan(_ repo: Repository, base: String, _ actions: [String: RebaseAction] = [:], order: [String]? = nil) async throws -> RebasePlan {
        let commits = try await repo.rebaseCommits(after: base)
        var plan = RebasePlan(base: base, commits: commits)
        if let order { plan.steps = order.map { subject in plan.steps.first { $0.commit?.subject == subject }! } }
        for index in plan.steps.indices { if let action = actions[plan.steps[index].commit!.subject] { plan.steps[index].action = action } }
        return plan
    }

    private func id(_ plan: RebasePlan, _ subject: String) -> String {
        plan.steps.first { $0.commit?.subject == subject }!.commit!.id
    }

    // MARK: Todo list

    func testTodoParsingReadsLongAndShortCommandsAndKeepsTheRest() {
        let text = """
        # comment
        pick 1111111 first subject
        r 2222222 # second
        fixup -C 3333333 third
        x make test
        update-ref refs/heads/stacked

        break
        label onto
        """
        XCTAssertEqual(RebaseTodoLine.parseList(text), [
            .commit(.pick, sha: "1111111", subject: "first subject"),
            .commit(.reword, sha: "2222222", subject: "second"),
            .commit(.fixup, sha: "3333333", subject: "third"),
            .exec("make test"),
            .updateRef("refs/heads/stacked"),
            .other(command: "break", argument: ""),
            .other(command: "label", argument: "onto"),
        ])
    }

    func testUpdateRefLinesFollowTheChainThatMeltsIntoTheirCommit() {
        let commits = ["a", "b", "c"].map { RebaseCommit(id: "sha-\($0)", parents: [], subject: $0, message: $0) }
        var plan = RebasePlan(base: "base", commits: commits, branches: ["sha-a": ["refs/heads/feature"]])
        plan.steps[1].action = .fixup
        XCTAssertEqual(plan.todoText, "pick sha-a a\nfixup sha-b b\nupdate-ref refs/heads/feature\npick sha-c c\n")
        plan.updateRefs = false
        XCTAssertEqual(plan.todoText, "pick sha-a a\nfixup sha-b b\npick sha-c c\n")
    }

    func testPlanProblemsAndResult() {
        let commits = ["a", "b", "c"].map { RebaseCommit(id: $0, parents: [], subject: $0, message: "\($0) subject\n\n\($0) body") }
        var plan = RebasePlan(base: "base", commits: commits)
        plan.steps[0].action = .drop
        plan.steps[1].action = .squash
        XCTAssertEqual(plan.problem, .nothingToFoldInto(commits[1]), "after the drop the squash has nothing before it")
        plan.steps[0].action = .pick
        XCTAssertNil(plan.problem)
        XCTAssertEqual(plan.result.map(\.message), ["a subject\n\na body\n\nb subject\n\nb body", "c subject\n\nc body"])
        plan.messages["a"] = "  \n"
        XCTAssertEqual(plan.problem, .emptyMessage(commits[0]))
    }

    // MARK: Running

    func testReorderRewordSquashAndDropInOneRun() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        var plan = try await plan(repo, base: base, ["b": .reword, "a": .squash, "d": .drop], order: ["c", "a", "b", "d"])
        plan.messages[id(plan, "c")] = "c und a zusammen"
        plan.messages[id(plan, "b")] = "b neu formuliert\n\n#42 bleibt als Text"

        let outcome = try await repo.startInteractiveRebase(plan)

        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(try messages(fixture, "\(base)..main"), ["c und a zusammen", "b neu formuliert\n\n#42 bleibt als Text"])
        XCTAssertEqual(try fixture.git("ls-tree", "--name-only", "HEAD~1"), "a.txt\nbase.txt\nc.txt", "a melted into c")
        XCTAssertFalse(try fixture.git("ls-tree", "--name-only", "HEAD").contains("d.txt"), "d was dropped")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD~2"), base)
        let progress = await repo.operationInProgress()
        XCTAssertNil(progress)
    }

    func testSquashWithoutChosenMessageJoinsTheMessagesAndFixupKeepsTheTarget() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let plan = try await plan(repo, base: base, ["b": .squash, "d": .fixup])

        _ = try await repo.startInteractiveRebase(plan)

        XCTAssertEqual(try messages(fixture, "\(base)..main"), ["a\n\nb", "c"])
        XCTAssertEqual(try fixture.git("ls-tree", "--name-only", "HEAD"), "a.txt\nb.txt\nbase.txt\nc.txt\nd.txt")
    }

    func testUnicodeMessagesSurviveRewordAndSquashInAFolderWithSpacesAndQuotes() async throws {
        let (fixture, base) = try linearFixture(name: "it's a täst")
        defer { fixture.remove() }
        let repo = fixture.repository
        var plan = try await plan(repo, base: base, ["a": .reword, "d": .squash])
        plan.messages[id(plan, "a")] = "Grüße 🌱 – „Zitat“"
        plan.messages[id(plan, "c")] = "Zusammengeführt: 日本語\n\nZweite Zeile ✓"

        _ = try await repo.startInteractiveRebase(plan)

        XCTAssertEqual(try messages(fixture, "\(base)..main"), ["Grüße 🌱 – „Zitat“", "b", "Zusammengeführt: 日本語\n\nZweite Zeile ✓"])
    }

    func testEditStopsThenAmendAndContinueFinish() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let plan = try await plan(repo, base: base, ["b": .edit])
        let b = id(plan, "b")

        let outcome = try await repo.startInteractiveRebase(plan)

        guard case let .stopped(progress, _) = outcome else { return XCTFail("edit stops: \(outcome)") }
        XCTAssertEqual(progress.stop, .edit(commit: b, subject: "b"))
        XCTAssertEqual(progress.step, 2)
        XCTAssertEqual(progress.total, 4)
        try fixture.write("b.txt", "b amended\n")
        try fixture.git("add", "b.txt")
        try await repo.commit(message: "b geändert", amend: true)
        try await repo.continueOperation(.rebase)

        let after = await repo.operationInProgress()
        XCTAssertNil(after)
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "b geändert", "c", "d"])
        XCTAssertEqual(try fixture.git("show", "HEAD~2:b.txt"), "b amended")
        let undo = await repo.finishedInteractiveRebase()
        XCTAssertNotNil(undo)
    }

    func testConflictStopsWithTheCommitAndAbortRestoresEverything() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base", file: "shared.txt", contents: "one\n")
        try fixture.commit("first", file: "shared.txt", contents: "two\n")
        let second = try fixture.commit("second", file: "shared.txt", contents: "three\n")
        let repo = fixture.repository
        let plan = try await plan(repo, base: base, order: ["second", "first"])

        let outcome = try await repo.startInteractiveRebase(plan)

        guard case let .stopped(progress, output) = outcome else { return XCTFail("swapping conflicts: \(outcome)") }
        XCTAssertEqual(progress.stop, .conflict(commit: second, subject: "second"))
        XCTAssertTrue(output.contains("CONFLICT") || output.contains("could not apply"), output)
        let status = try await repo.status()
        XCTAssertEqual(status.conflicted.map(\.path), ["shared.txt"])

        try await repo.abortOperation(.rebase)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), second)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "")
        let session = try await repo.rebaseSession()
        XCTAssertFalse(session.exists, "abort ends the app's session")
    }

    func testRewordOfAConflictingCommitGetsItsMessageWhenContinued() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base", file: "shared.txt", contents: "one\n")
        try fixture.commit("first", file: "shared.txt", contents: "two\n")
        try fixture.commit("second", file: "shared.txt", contents: "three\n")
        let repo = fixture.repository
        var plan = try await plan(repo, base: base, ["second": .reword], order: ["second", "first"])
        plan.messages[id(plan, "second")] = "zweiter, neu"

        _ = try await repo.startInteractiveRebase(plan)
        try fixture.write("shared.txt", "three\n")
        try fixture.git("add", "shared.txt")
        do {
            try await repo.continueOperation(.rebase)
            XCTFail("first conflicts next")
        } catch {}
        try fixture.write("shared.txt", "two\n")
        try fixture.git("add", "shared.txt")
        try await repo.continueOperation(.rebase)

        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["zweiter, neu", "first"])
    }

    func testFailedExecStopsTheRebase() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        var plan = try await plan(repo, base: base)
        plan.steps.insert(RebaseStep(exec: "test -f nothing-here"), at: 2)

        let outcome = try await repo.startInteractiveRebase(plan)

        guard case let .stopped(progress, _) = outcome else { return XCTFail("exec fails: \(outcome)") }
        XCTAssertEqual(progress.stop, .exec("test -f nothing-here"))
        try await repo.skipOperation(.rebase)
        let after = await repo.operationInProgress()
        XCTAssertNil(after)
    }

    func testUpdateRefsMovesAStackedBranchAlong() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        try fixture.git("branch", "stacked", "HEAD~2")
        try fixture.git("branch", "elsewhere", "HEAD~1")
        let linked = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-linked-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try fixture.git("worktree", "add", "-q", linked, "elsewhere")
        let repo = fixture.repository
        let commits = try await repo.rebaseCommits(after: base)
        let branches = await repo.stackedBranches(in: commits)
        XCTAssertEqual(branches, [commits[1].id: ["refs/heads/stacked"]], "main is current and elsewhere is checked out in a worktree")
        var plan = RebasePlan(base: base, commits: commits, branches: branches)
        XCTAssertTrue(plan.updateRefs)
        plan.steps[0].action = .reword
        plan.messages[commits[0].id] = "a2"

        _ = try await repo.startInteractiveRebase(plan)

        XCTAssertEqual(try subjects(fixture, "\(base)..stacked"), ["a2", "b"])
        XCTAssertEqual(try fixture.git("rev-parse", "stacked"), try fixture.git("rev-parse", "main~2"))

        let finished = await repo.finishedInteractiveRebase()
        let undo = try XCTUnwrap(finished)
        XCTAssertEqual(undo.stacked.map(\.ref), ["refs/heads/stacked"])
        let canUndo = await repo.canUndoRebase(undo)
        XCTAssertTrue(canUndo)
        try await repo.undoRebase(undo)
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "b", "c", "d"])
        XCTAssertEqual(try fixture.git("rev-parse", "stacked"), commits[1].id, "the stacked branch goes back too")
        let afterUndo = await repo.lastRebaseUndo()
        XCTAssertNil(afterUndo, "an undone rebase offers no second undo")
    }

    func testUndoIsRefusedOnceHeadHasMoved() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let before = try fixture.git("rev-parse", "HEAD")
        _ = try await repo.startInteractiveRebase(try await plan(repo, base: base, ["c": .drop]))
        let finished = await repo.finishedInteractiveRebase()
        let undo = try XCTUnwrap(finished)
        XCTAssertEqual(undo.before, before)
        XCTAssertEqual(undo.branch, "refs/heads/main")
        let again = await repo.finishedInteractiveRebase()
        XCTAssertNil(again, "the session ends once it was read")
        let kept = await repo.lastRebaseUndo()
        XCTAssertEqual(kept, undo, "the record stays for a later launch")

        try fixture.commit("later", file: "later.txt")
        let canUndo = await repo.canUndoRebase(undo)
        XCTAssertFalse(canUndo)
        let stale = await repo.lastRebaseUndo()
        XCTAssertNil(stale)
        do {
            try await repo.undoRebase(undo)
            XCTFail("HEAD moved")
        } catch {}
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "b", "d", "later"])
    }

    func testDroppingEverythingResetsToTheBase() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let plan = try await plan(repo, base: base, ["a": .drop, "b": .drop, "c": .drop, "d": .drop])
        XCTAssertTrue(plan.dropsEverything)

        _ = try await repo.startInteractiveRebase(plan)

        XCTAssertEqual(try fixture.git("rev-parse", "main"), base)
    }

    func testMergesInTheRangeAndBasesOutsideHistoryAreRefused() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base", file: "base.txt")
        try fixture.git("switch", "-q", "-c", "side")
        try fixture.commit("side", file: "side.txt")
        try fixture.git("switch", "-q", "main")
        try fixture.commit("main", file: "main.txt")
        try fixture.git("merge", "-q", "--no-edit", "side")
        let side = try fixture.git("rev-parse", "side")
        let repo = fixture.repository

        do {
            _ = try await repo.rebaseCommits(after: base)
            XCTFail("a merge is in the range")
        } catch let error as RebasePlanError {
            XCTAssertEqual(error, .mergeInRange)
        }
        try fixture.git("switch", "-q", "-c", "other", base)
        try fixture.commit("other", file: "other.txt")
        do {
            _ = try await repo.rebaseCommits(after: side)
            XCTFail("side is not in other's history")
        } catch let error as RebasePlanError {
            XCTAssertEqual(error, .baseNotInHistory)
        }
    }

    func testDirtyWorkingTreeNeedsAutostash() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        try fixture.write("a.txt", "local change\n")
        var plan = try await plan(repo, base: base, ["d": .drop])

        do {
            _ = try await repo.startInteractiveRebase(plan)
            XCTFail("git refuses a dirty tree without autostash")
        } catch is GitError {}
        let session = try await repo.rebaseSession()
        XCTAssertFalse(session.exists, "a refused start leaves no session behind")

        plan.autostash = true
        _ = try await repo.startInteractiveRebase(plan)
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "b", "c"])
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8), "local change\n")
    }

    // MARK: Single steps

    func testSingleStepRewordAndDrop() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let b = try fixture.git("rev-parse", "HEAD~2")

        let reword = try await repo.singleStepPlan(.reword("b – neu"), commit: b)
        XCTAssertEqual(reword.steps.map(\.action), [.reword, .pick, .pick], "the range starts right below b")
        _ = try await repo.startInteractiveRebase(reword)
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "b – neu", "c", "d"])

        let c = try fixture.git("rev-parse", "HEAD~1")
        _ = try await repo.startInteractiveRebase(try await repo.singleStepPlan(.drop, commit: c))
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "b – neu", "d"])
    }

    func testSingleStepMovesSwapWithTheNeighbour() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let b = try fixture.git("rev-parse", "HEAD~2")

        _ = try await repo.startInteractiveRebase(try await repo.singleStepPlan(.moveUp, commit: b))
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "c", "b", "d"])

        let d = try fixture.git("rev-parse", "HEAD")
        _ = try await repo.startInteractiveRebase(try await repo.singleStepPlan(.moveDown, commit: d))
        XCTAssertEqual(try subjects(fixture, "\(base)..main"), ["a", "c", "d", "b"])
    }

    func testSingleStepsRefuseRootHeadAndForeignCommits() async throws {
        let (fixture, base) = try linearFixture()
        defer { fixture.remove() }
        let repo = fixture.repository
        let a = try fixture.git("rev-parse", "HEAD~3")
        let head = try fixture.git("rev-parse", "HEAD")
        try fixture.git("switch", "-q", "-c", "side", a)
        let foreign = try fixture.commit("side", file: "side.txt")
        try fixture.git("switch", "-q", "main")

        let cases: [(RebaseSingleStep, String, RebasePlanError)] = [
            (.drop, base, .rootCommit),
            (.moveDown, a, .rootCommit),
            (.moveUp, head, .nothingAbove),
            (.drop, foreign, .notOnCurrentBranch),
        ]
        for (step, commit, expected) in cases {
            do {
                _ = try await repo.singleStepPlan(step, commit: commit)
                XCTFail("\(step) on \(commit.prefix(7)) should be refused")
            } catch let error as RebasePlanError {
                XCTAssertEqual(error, expected, "\(step)")
            }
        }
    }
}
