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

        try await repo.stash(message: "half done", includeUntracked: true)
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

        try await repo.stash(message: nil, includeUntracked: false)
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "?? new.txt")
        let stash = try await newest(repo)
        XCTAssertTrue(stash.message.hasPrefix("WIP on main: "), stash.message)
        XCTAssertEqual(stash.branch, "main")
        XCTAssertTrue(stash.text.hasSuffix("base"), stash.text)
    }

    func testStashOnDetachedHeadHasNoBranch() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base")
        try fixture.git("switch", "-q", "--detach", base)
        try fixture.write("file.txt", "changed\n")
        try await fixture.repository.stash(message: "detached", includeUntracked: true)
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
        try await repo.stash(message: "mine", includeUntracked: true)
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
        try await repo.stash(message: "first", includeUntracked: true)
        let first = try await newest(repo)
        // Another worktree pushing a stash moves `first` to stash@{1}.
        try fixture.write("file.txt", "second\n")
        try await repo.stash(message: "second", includeUntracked: true)

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
        try await repo.stash(message: "idea", includeUntracked: true)
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
