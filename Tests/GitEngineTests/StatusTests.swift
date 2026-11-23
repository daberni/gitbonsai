import Foundation
import XCTest
@testable import GitEngine

final class StatusTests: XCTestCase {
    func testStagedUnstagedUntrackedRenameAndUnicodePath() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let head = try fixture.commit("base", file: "keep.txt", contents: "keep\n")
        try fixture.write("rename-me.txt", "rename\n")
        try fixture.write("both.txt", "both\n")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "more")
        let head2 = try fixture.git("rev-parse", "HEAD")
        _ = head

        try fixture.write("staged.txt", "new\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("keep.txt", "changed\n")
        try fixture.write("both.txt", "staged part\n")
        try fixture.git("add", "both.txt")
        try fixture.write("both.txt", "staged part\nplus unstaged\n")
        try fixture.git("mv", "rename-me.txt", "renamed.txt")
        try fixture.write("Ünïcode Ordner/datei mit leerzeichen.txt", "u\n")

        let status = try await fixture.repository.status()
        let byPath = Dictionary(uniqueKeysWithValues: status.entries.map { ($0.path, $0) })

        XCTAssertEqual(status.branch.headSHA, head2)
        XCTAssertEqual(status.branch.branch, "main")
        XCTAssertNil(status.branch.upstream)

        let staged = try XCTUnwrap(byPath["staged.txt"])
        XCTAssertEqual(staged.indexState, .added)
        XCTAssertEqual(staged.worktreeState, .unmodified)
        XCTAssertTrue(staged.isStaged)

        let unstaged = try XCTUnwrap(byPath["keep.txt"])
        XCTAssertEqual(unstaged.indexState, .unmodified)
        XCTAssertEqual(unstaged.worktreeState, .modified)
        XCTAssertFalse(unstaged.isStaged)

        let both = try XCTUnwrap(byPath["both.txt"])
        XCTAssertEqual(both.indexState, .modified)
        XCTAssertEqual(both.worktreeState, .modified)

        let renamed = try XCTUnwrap(byPath["renamed.txt"])
        XCTAssertEqual(renamed.indexState, .renamed)
        XCTAssertEqual(renamed.originalPath, "rename-me.txt")

        let unicode = try XCTUnwrap(byPath["Ünïcode Ordner/datei mit leerzeichen.txt"])
        XCTAssertTrue(unicode.isUntracked)
        XCTAssertTrue(unicode.hasWorktreeChanges)

        XCTAssertEqual(Set(status.staged.map(\.path)), ["staged.txt", "both.txt", "renamed.txt"])
        XCTAssertEqual(Set(status.unstaged.map(\.path)), ["keep.txt", "both.txt", "Ünïcode Ordner/datei mit leerzeichen.txt"])
        XCTAssertFalse(status.hasConflicts)
    }

    func testConflictAndDetachedHead() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "c.txt", contents: "base\n")
        try fixture.git("checkout", "-q", "-b", "other")
        try fixture.commit("theirs", file: "c.txt", contents: "theirs\n")
        try fixture.git("checkout", "-q", "main")
        let ours = try fixture.commit("ours", file: "c.txt", contents: "ours\n")
        try fixture.git("checkout", "-q", "--detach")
        XCTAssertThrowsError(try fixture.git("merge", "other"))

        let status = try await fixture.repository.status()

        XCTAssertNil(status.branch.branch)
        XCTAssertEqual(status.branch.headSHA, ours)
        XCTAssertTrue(status.hasConflicts)
        let conflict = try XCTUnwrap(status.conflicted.first)
        XCTAssertEqual(conflict.path, "c.txt")
        XCTAssertEqual(conflict.conflict, .bothModified)
        XCTAssertEqual(conflict.indexState, .unmerged)
        XCTAssertTrue(status.staged.isEmpty)
    }

    func testUnbornBranchHasNoHead() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.write("new.txt", "x\n")

        let status = try await fixture.repository.status()

        XCTAssertNil(status.branch.headSHA)
        XCTAssertEqual(status.branch.branch, "main")
        XCTAssertEqual(status.entries.map(\.path), ["new.txt"])
    }

    func testUpstreamAheadBehindHeaders() async throws {
        let remote = try FixtureRepo(name: "remote")
        defer { remote.remove() }
        let first = try remote.commit("one")
        try remote.commit("two")
        let fixture = try FixtureRepo(name: "local")
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("checkout", "-q", "-b", "main", "--track", "origin/main")
        try fixture.git("reset", "-q", "--hard", first)
        try fixture.commit("local", file: "l.txt")
        try fixture.commit("local 2", file: "l2.txt")

        let status = try await fixture.repository.status()

        XCTAssertEqual(status.branch.upstream, "origin/main")
        XCTAssertEqual(status.branch.ahead, 2)
        XCTAssertEqual(status.branch.behind, 1)
    }

    /// A submodule with a new commit and a dirty working tree shows as one submodule entry, not as its files.
    func testSubmoduleWithNewCommitAndLocalChanges() async throws {
        let library = try FixtureRepo(name: "status-library")
        defer { library.remove() }
        try library.commit("library")
        let fixture = try FixtureRepo(name: "status-super")
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("submodule", "add", "-q", library.path, "modules/library")
        try fixture.git("commit", "-q", "-m", "Add library")
        let submodule = FixtureRepo(existing: fixture.url.appendingPathComponent("modules/library"))
        try submodule.git("config", "user.name", "Fixture")
        try submodule.git("config", "user.email", "fixture@example.com")
        try submodule.commit("moved on", file: "file.txt", contents: "new\n")
        try submodule.write("file.txt", "dirty\n")

        let status = try await fixture.repository.status()
        XCTAssertEqual(status.entries.map(\.path), ["modules/library"])
        let entry = try XCTUnwrap(status.entries.first)
        XCTAssertTrue(entry.isSubmodule)
        XCTAssertEqual(entry.worktreeState, .modified)
        XCTAssertEqual(entry.indexState, .unmodified)
    }
}
