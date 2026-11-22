import XCTest
@testable import GitEngine

final class TagTests: XCTestCase {
    private func tagExists(_ fixture: FixtureRepo, _ name: String) -> Bool {
        (try? fixture.git("rev-parse", "-q", "--verify", "refs/tags/\(name)")) != nil
    }

    func testListsAnnotatedAndLightweightTagsNewestFirstWithTheirCommits() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("first commit")
        let second = try fixture.commit("second commit")
        try fixture.git("tag", "light", first)
        try fixture.git(["-c", "user.name=Fixture", "tag", "-a", "v1.0", "-m", "Release 1.0\n\nNotes", second])
        try fixture.git("tag", "-a", "nested", "-m", "points at a tag", "v1.0")
        // A tag of a blob has no commit to show.
        let blob = try fixture.git("rev-parse", "HEAD:file.txt")
        try fixture.git("tag", "blob-tag", blob)
        let repo = fixture.repository
        try await repo.createTag("later", at: first, message: "Later")

        let tags = try await repo.tags()
        let byName = Dictionary(uniqueKeysWithValues: tags.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["light", "v1.0", "nested", "later"])
        XCTAssertEqual(byName["light"]?.isAnnotated, false)
        XCTAssertEqual(byName["light"]?.commitID, first)
        XCTAssertEqual(byName["light"]?.subject, "first commit")
        XCTAssertEqual(byName["v1.0"]?.isAnnotated, true)
        XCTAssertEqual(byName["v1.0"]?.commitID, second, "an annotated tag is peeled to its commit")
        XCTAssertEqual(byName["v1.0"]?.subject, "Release 1.0")
        XCTAssertEqual(byName["nested"]?.commitID, second)
        XCTAssertEqual(tags.map(\.date), tags.map(\.date).sorted(by: >), "newest first")
        XCTAssertGreaterThan(try XCTUnwrap(byName["later"]?.date), try XCTUnwrap(byName["light"]?.date), "an annotated tag carries its own date")
    }

    func testDeleteLocalTagKeepsTheCommitAndOtherTags() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let commit = try fixture.commit("first")
        try fixture.git("tag", "gone", commit)
        try fixture.git("tag", "-a", "kept", "-m", "kept", commit)
        let repo = fixture.repository

        try await repo.deleteTag("gone")
        XCTAssertFalse(tagExists(fixture, "gone"))
        XCTAssertTrue(tagExists(fixture, "kept"))
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), commit)

        do {
            try await repo.deleteTag("gone")
            XCTFail("deleting a missing tag must fail")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("not found"), error.stderr)
        }
    }

    func testPushAndDeleteOnTheRemoteLeaveTheLocalTag() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let remote = try FixtureRepo(name: "remote")
        defer { remote.remove() }
        try remote.git("config", "receive.denyCurrentBranch", "ignore")
        let commit = try fixture.commit("first")
        try fixture.git("tag", "-a", "v1", "-m", "one", commit)
        try fixture.git("remote", "add", "origin", remote.path)
        let repo = fixture.repository
        let remotes = try await repo.remotes()
        XCTAssertEqual(remotes, ["origin"])

        try await repo.pushTag("v1", to: "origin")
        XCTAssertEqual(try remote.git("rev-parse", "v1^{commit}"), commit)
        XCTAssertEqual(try remote.git("cat-file", "-t", "v1"), "tag", "the annotated tag object travels, not only the commit")
        XCTAssertFalse((try? remote.git("rev-parse", "-q", "--verify", "refs/heads/main")) != nil, "only the tag is pushed")

        try await repo.deleteRemoteTag("v1", on: "origin")
        XCTAssertFalse(tagExists(remote, "v1"))
        XCTAssertTrue(tagExists(fixture, "v1"))
    }
}
