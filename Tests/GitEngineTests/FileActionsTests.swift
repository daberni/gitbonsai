import XCTest
@testable import GitEngine

final class FileActionsTests: XCTestCase {
    private func commit(_ id: String, in fixture: FixtureRepo) async throws -> Commit {
        let commits = try await fixture.repository.collectLog()
        return try XCTUnwrap(commits.first { $0.id == id })
    }

    private func read(_ fixture: FixtureRepo, _ file: String) throws -> String {
        try String(contentsOf: fixture.url.appendingPathComponent(file), encoding: .utf8)
    }

    // MARK: Restore

    func testRestoreWritesTheCommitsVersionAndLeavesTheIndexAlone() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let old = try fixture.commit("old", contents: "one\n")
        try fixture.commit("new", contents: "two\n")
        let repo = fixture.repository

        let clean = try await repo.hasLocalChanges(at: "file.txt")
        XCTAssertFalse(clean)
        try await repo.restore("file.txt", of: try await commit(old, in: fixture))

        XCTAssertEqual(try read(fixture, "file.txt"), "one\n")
        XCTAssertEqual(try fixture.git("status", "--porcelain"), " M file.txt")
        let changed = try await repo.hasLocalChanges(at: "file.txt")
        XCTAssertTrue(changed)
    }

    func testLocalChangesAreDetectedBeforeTheyWouldBeOverwritten() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let old = try fixture.commit("old", contents: "one\n")
        try fixture.commit("new", contents: "two\n")
        try fixture.write("other.txt", "untouched\n")
        try fixture.git("add", "other.txt")
        try fixture.git("commit", "-q", "-m", "other")
        let repo = fixture.repository

        try fixture.write("file.txt", "local edit\n")
        let edited = try await repo.hasLocalChanges(at: "file.txt")
        XCTAssertTrue(edited)
        let otherFile = try await repo.hasLocalChanges(at: "other.txt")
        XCTAssertFalse(otherFile, "changes elsewhere do not count")

        // A staged edit counts too, and the restore leaves it in the index.
        try fixture.git("add", "file.txt")
        let staged = try await repo.hasLocalChanges(at: "file.txt")
        XCTAssertTrue(staged)
        try await repo.restore("file.txt", of: try await commit(old, in: fixture))
        XCTAssertEqual(try read(fixture, "file.txt"), "one\n")
        XCTAssertEqual(try fixture.git("show", ":file.txt"), "local edit")

        // An untracked file in the way counts as a local change.
        try fixture.write("new.txt", "mine\n")
        let untracked = try await repo.hasLocalChanges(at: "new.txt")
        XCTAssertTrue(untracked)
    }

    func testRestoringAFileTheCommitDeletedBringsBackTheVersionBeforeIt() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("add", file: "gone.txt", contents: "last words\n")
        try fixture.git("rm", "-q", "gone.txt")
        try fixture.git("commit", "-q", "-m", "delete")
        let deletion = try await commit(try fixture.git("rev-parse", "HEAD"), in: fixture)
        let repo = fixture.repository

        let revision = try await repo.restoreRevision(for: "gone.txt", of: deletion)
        XCTAssertEqual(revision, deletion.parents.first)
        try await repo.restore("gone.txt", of: deletion)
        XCTAssertEqual(try read(fixture, "gone.txt"), "last words\n")
    }

    func testRestoringARenamedFileWritesItUnderItsNewPath() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("add", file: "before.txt", contents: "content\n")
        try fixture.git("mv", "before.txt", "after.txt")
        try fixture.git("commit", "-q", "-m", "rename")
        let rename = try await commit(try fixture.git("rev-parse", "HEAD"), in: fixture)
        try fixture.write("after.txt", "edited\n")
        let repo = fixture.repository

        let revision = try await repo.restoreRevision(for: "after.txt", of: rename)
        XCTAssertEqual(revision, rename.id)
        try await repo.restore("after.txt", of: rename)
        XCTAssertEqual(try read(fixture, "after.txt"), "content\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("before.txt").path), "the old path stays gone")
    }

    // MARK: Diff tool

    func testDiffToolIsDetectedAndGetsBothSidesOfACommitsFile() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let log = fixture.url.deletingLastPathComponent().appendingPathComponent("difftool-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let root = try fixture.commit("root", contents: "one\n")
        let second = try fixture.commit("second", contents: "two\n")
        let repo = fixture.repository
        // Empty local values hide a tool the machine's global configuration may name.
        for key in ["diff.tool", "diff.guitool", "merge.tool"] { try fixture.git("config", key, "") }

        let before = await repo.hasDiffTool()
        XCTAssertFalse(before)
        try fixture.git("config", "diff.tool", "record")
        try fixture.git("config", "difftool.record.cmd", "cat \"$LOCAL\" \"$REMOTE\" >> '\(log.path)'")
        let after = await repo.hasDiffTool()
        XCTAssertTrue(after)

        try await repo.openDiffTool(for: "file.txt", in: .commit(try await commit(second, in: fixture)))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "one\ntwo\n")

        // A root commit is compared against the empty tree.
        try FileManager.default.removeItem(at: log)
        try await repo.openDiffTool(for: "file.txt", in: .commit(try await commit(root, in: fixture)))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "one\n")

        try FileManager.default.removeItem(at: log)
        try fixture.write("file.txt", "three\n")
        try await repo.openDiffTool(for: "file.txt", in: .unstaged)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "two\nthree\n")
    }
}
