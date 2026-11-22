import XCTest
@testable import GitEngine

final class StashTests: XCTestCase {
    private func newest(_ repo: Repository) async throws -> Stash {
        let stashes = try await repo.stashes()
        return try XCTUnwrap(stashes.first)
    }

    private func read(_ fixture: FixtureRepo, _ file: String) throws -> String {
        try String(contentsOf: fixture.url.appendingPathComponent(file), encoding: .utf8)
    }

    private func exists(_ fixture: FixtureRepo, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent(file).path)
    }

    func testPushWithUntrackedAndPopRestoresEverything() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.write("file.txt", "changed\n")
        try fixture.write("new.txt", "untracked\n")
        let repo = fixture.repository

        try await repo.stash(message: "half done", scope: .includingUntracked)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "", "tracked and untracked changes are both stashed")
        let stashes = try await repo.stashes()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes[0].selector, "stash@{0}")
        XCTAssertEqual(stashes[0].message, "On main: half done")
        XCTAssertEqual(stashes[0].text, "half done")
        XCTAssertEqual(stashes[0].branch, "main")

        try await repo.popStash(stashes[0])
        XCTAssertEqual(try read(fixture, "file.txt"), "changed\n")
        XCTAssertEqual(try read(fixture, "new.txt"), "untracked\n")
        let afterPop = try await repo.stashes()
        XCTAssertTrue(afterPop.isEmpty)
    }

    func testPushWithoutUntrackedLeavesUntrackedFilesAndWritesGitsSubject() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.write("file.txt", "changed\n")
        try fixture.write("new.txt", "untracked\n")
        let repo = fixture.repository

        try await repo.stash(message: nil, scope: .tracked)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "?? new.txt")
        let stash = try await newest(repo)
        XCTAssertTrue(stash.message.hasPrefix("WIP on main: "), stash.message)
        XCTAssertEqual(stash.branch, "main")
        XCTAssertTrue(stash.text.hasSuffix("base"), stash.text)
    }

    func testDefaultMessagePartsNameBranchAndHeadSubject() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("Add the parser", contents: "base\n")
        try fixture.write("file.txt", "changed\n")
        let repo = fixture.repository

        let parts = await repo.defaultStashMessageParts()
        XCTAssertEqual(parts.branch, "main")
        XCTAssertEqual(parts.subject, "Add the parser")
        let created = try await repo.stash(message: "WIP on main: Add the parser", scope: .includingUntracked)
        XCTAssertEqual(created?.stash.text, "WIP on main: Add the parser")
        XCTAssertEqual(created?.remaining, "")

        try fixture.git("checkout", "--detach")
        let detached = await repo.defaultStashMessageParts()
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.subject, "Add the parser")
    }

    func testNothingToStashReturnsNil() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        let created = try await fixture.repository.stash(message: "nothing", scope: .includingUntracked)
        XCTAssertNil(created)
    }

    func testStagedScopeStashesOnlyTheIndex() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.write("staged.txt", "staged\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("file.txt", "unstaged\n")
        let repo = fixture.repository

        let created = try await repo.stash(message: "only staged", scope: .staged)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), " M file.txt")
        XCTAssertEqual(created?.remaining, " M file.txt\n")
        XCTAssertEqual(try fixture.git("stash", "show", "--name-only", "stash@{0}"), "staged.txt")

        try await repo.undoStash(try XCTUnwrap(created))
        XCTAssertEqual(try fixture.git("status", "--porcelain"), " M file.txt\nA  staged.txt", "undo puts the staged change back into the index")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    func testUndoRestoresIndexAndUntrackedFiles() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.write("file.txt", "changed\n")
        try fixture.write("staged.txt", "staged\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("new.txt", "untracked\n")
        let repo = fixture.repository

        let stashed = try await repo.stash(message: "undo me", scope: .includingUntracked)
        let created = try XCTUnwrap(stashed)
        try await repo.undoStash(created)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), " M file.txt\nA  staged.txt\n?? new.txt")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    /// Undo must not mix the stash into anything that happened after it.
    func testUndoIsRefusedOnceSomethingElseChanged() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        let repo = fixture.repository

        try fixture.write("file.txt", "changed\n")
        let first = try await repo.stash(message: "first", scope: .includingUntracked)
        var created = try XCTUnwrap(first)
        try fixture.write("other.txt", "later\n")
        await assertUndo(created, in: repo, fails: .workingTreeChanged)
        try fixture.git("stash", "push", "-q", "-u", "-m", "newer")
        await assertUndo(created, in: repo, fails: .notNewest)
        try fixture.git("stash", "pop", "-q")
        try fixture.git("add", "other.txt")
        try fixture.git("commit", "-qm", "later")
        await assertUndo(created, in: repo, fails: .headMoved)

        try fixture.write("file.txt", "again\n")
        let second = try await repo.stash(message: "second", scope: .includingUntracked)
        created = try XCTUnwrap(second)
        try await repo.undoStash(created)
        XCTAssertEqual(try read(fixture, "file.txt"), "again\n")
        XCTAssertEqual(try fixture.git("stash", "list").split(separator: "\n").count, 1, "only the refused first stash is left")
    }

    /// A cherry-pick that git refuses over a dirty file goes through with the changes set aside, and they come back merged.
    func testWithLocalChangesStashedRunsTheBlockedCommandAndBringsTheChangesBack() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "a\nb\nc\n")
        try fixture.git("switch", "-q", "-c", "other")
        let pick = try fixture.commit("upper a", contents: "A\nb\nc\n")
        try fixture.git("switch", "-q", "main")
        try fixture.write("file.txt", "a\nb\nC\n")
        try fixture.write("new.txt", "untracked\n")
        let repo = fixture.repository

        do {
            _ = try await repo.runner.runWrite(["cherry-pick", pick])
            XCTFail("git refuses to cherry-pick over the dirty file")
        } catch let error as GitError {
            XCTAssertEqual(GitFailure(output: error.stderr), .localChangesInTheWay(["file.txt"]))
        }
        let conflicted = try await repo.withLocalChangesStashed(message: "vor Cherry-pick") { _ = try await repo.runner.runWrite(["cherry-pick", pick]) }

        XCTAssertFalse(conflicted)
        XCTAssertEqual(try read(fixture, "file.txt"), "A\nb\nC\n")
        XCTAssertEqual(try read(fixture, "new.txt"), "untracked\n")
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%s"), "upper a")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    func testWithLocalChangesStashedKeepsTheStashWhenTheChangesConflict() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "a\n")
        try fixture.git("switch", "-q", "-c", "other")
        let pick = try fixture.commit("theirs", contents: "theirs\n")
        try fixture.git("switch", "-q", "main")
        try fixture.write("file.txt", "mine\n")
        let repo = fixture.repository

        let conflicted = try await repo.withLocalChangesStashed(message: "vor Cherry-pick") { _ = try await repo.runner.runWrite(["cherry-pick", pick]) }

        XCTAssertTrue(conflicted)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "UU file.txt")
        XCTAssertTrue(try fixture.git("stash", "list").hasSuffix("vor Cherry-pick"))
    }

    func testWithLocalChangesStashedPutsTheChangesBackWhenTheCommandFails() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "a\n")
        try fixture.write("file.txt", "mine\n")
        let repo = fixture.repository

        do {
            _ = try await repo.withLocalChangesStashed(message: "vor nichts") { _ = try await repo.runner.runWrite(["cherry-pick", "no-such-commit"]) }
            XCTFail("the command's error is thrown")
        } catch is GitError {}
        XCTAssertEqual(try read(fixture, "file.txt"), "mine\n")
        XCTAssertEqual(try fixture.git("stash", "list"), "")
    }

    private func assertUndo(_ created: NewStash, in repo: Repository, fails expected: StashUndoError, line: UInt = #line) async {
        do {
            try await repo.undoStash(created)
            XCTFail("undo should be refused", line: line)
        } catch {
            XCTAssertEqual(error as? StashUndoError, expected, line: line)
        }
    }

    func testStashOnDetachedHeadHasNoBranch() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base")
        try fixture.git("switch", "-q", "--detach", base)
        try fixture.write("file.txt", "changed\n")
        try await fixture.repository.stash(message: "detached", scope: .includingUntracked)
        let stash = try await newest(fixture.repository)
        XCTAssertNil(stash.branch)
        XCTAssertEqual(stash.text, "detached")
    }

    func testPopWithConflictKeepsTheStashAndReportsGitsMessage() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        try fixture.write("file.txt", "stashed\n")
        let repo = fixture.repository
        try await repo.stash(message: "mine", scope: .includingUntracked)
        try fixture.commit("theirs", contents: "committed\n")
        let stash = try await newest(repo)

        do {
            try await repo.popStash(stash)
            XCTFail("the pop must stop on the conflict")
        } catch let error as GitError {
            XCTAssertTrue(error.stoppedOnConflict, error.stderr)
            XCTAssertTrue(error.stderr.contains("file.txt"), error.stderr)
        }
        let kept = try await repo.stashes()
        XCTAssertEqual(kept.map(\.commitID), [stash.commitID], "git keeps a stash whose pop conflicted")
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "UU file.txt", "the conflict stays in the working tree")
    }

    func testApplyKeepsAndDropRemovesTheStashNamedByItsCommitAfterTheListShifted() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", contents: "base\n")
        let repo = fixture.repository
        try fixture.write("file.txt", "first\n")
        try await repo.stash(message: "first", scope: .includingUntracked)
        let first = try await newest(repo)
        // Another worktree pushing a stash moves `first` to stash@{1}.
        try fixture.write("file.txt", "second\n")
        try await repo.stash(message: "second", scope: .includingUntracked)

        try await repo.applyStash(first)
        XCTAssertEqual(try read(fixture, "file.txt"), "first\n")
        try fixture.git("checkout", "--", "file.txt")

        try await repo.dropStash(first)
        let remaining = try await repo.stashes()
        XCTAssertEqual(remaining.map(\.text), ["second"])

        do {
            try await repo.dropStash(first)
            XCTFail("a stash that is gone must not drop whatever took its number")
        } catch is GitError {}
        let unchanged = try await repo.stashes()
        XCTAssertEqual(unchanged.map(\.text), ["second"])
    }

    func testBranchFromStashStartsAtItsBaseAndDropsIt() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base", contents: "base\n")
        try fixture.write("file.txt", "stashed\n")
        try fixture.write("new.txt", "untracked\n")
        let repo = fixture.repository
        try await repo.stash(message: "idea", scope: .includingUntracked)
        try fixture.commit("moved on", contents: "later\n")
        let stash = try await newest(repo)

        try await repo.createBranch("idea", from: stash)
        XCTAssertEqual(try fixture.git("rev-parse", "--abbrev-ref", "HEAD"), "idea")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), base)
        XCTAssertEqual(try read(fixture, "file.txt"), "stashed\n")
        XCTAssertTrue(exists(fixture, "new.txt"))
        let remaining = try await repo.stashes()
        XCTAssertTrue(remaining.isEmpty)
    }
}
