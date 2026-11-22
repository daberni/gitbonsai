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
}
