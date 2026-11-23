import XCTest
@testable import GitEngine

final class CommitTests: XCTestCase {
    func testMessageKeepsHashLinesAndAmendRewritesIt() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("Base")
        try fixture.write("a.txt", "a\n")
        try fixture.git("add", "a.txt")
        let repo = fixture.repository

        let message = "Füge Datei hinzu 🌳\n\n#123 references an issue\nSecond line"
        try await repo.commit(message: message, amend: false)
        let first = await repo.lastCommitMessage()
        XCTAssertEqual(first, message, "a line starting with # is part of the message, not a comment")

        try fixture.write("b.txt", "b\n")
        try fixture.git("add", "b.txt")
        try await repo.commit(message: "Rewritten", amend: true)
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%s"), "Rewritten")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD~1"), base, "amend replaces the commit instead of adding one")
        XCTAssertEqual(try fixture.git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted(), ["a.txt", "b.txt"])
    }

    func testCommitAllTakesStagedUnstagedUntrackedAndDeletedFiles() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.write("modified.txt", "a\n")
        try fixture.write("deleted.txt", "d\n")
        let base = try fixture.commit("Base")
        try fixture.write("staged.txt", "s\n")
        try fixture.git("add", "staged.txt")
        try fixture.write("modified.txt", "b\n")
        try fixture.write("neu ü.txt", "u\n")
        try FileManager.default.removeItem(atPath: fixture.path + "/deleted.txt")
        let repo = fixture.repository

        try await repo.commitAll(message: "Everything")
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD~1"), base)
        XCTAssertEqual(try fixture.git("-c", "core.quotepath=off", "show", "--name-status", "--format=", "HEAD").split(separator: "\n").sorted(), ["A\tneu ü.txt", "A\tstaged.txt", "D\tdeleted.txt", "M\tmodified.txt"])
        XCTAssertEqual(try fixture.git("status", "--porcelain"), "", "nothing is left behind")
    }

    func testCommitAllRefusesUnmergedPathsWithoutStagingThem() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.write("c.txt", "base\n")
        try fixture.commit("Base")
        try fixture.git("checkout", "-b", "other")
        try fixture.write("c.txt", "other\n")
        try fixture.commit("Other")
        try fixture.git("checkout", "-")
        try fixture.write("c.txt", "main\n")
        let head = try fixture.commit("Main")
        _ = try? fixture.git("merge", "other")
        let repo = fixture.repository

        do {
            try await repo.commitAll(message: "Merge")
            XCTFail("unmerged paths must block commit all")
        } catch {}
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), head)
        XCTAssertTrue(try fixture.git("status", "--porcelain").hasPrefix("UU"), "the conflict stays unresolved")
    }
}
