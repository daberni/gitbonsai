import Foundation
import XCTest
@testable import GitEngine

final class TrailerTests: XCTestCase {
    func testParsesInterpretTrailersOutputWithFoldedAndUnicodeValues() {
        let output = "Co-authored-by: Zoë Ünïcode <zoe@example.com>\nSigned-off-by: Fixture <fixture@example.com>\nFixes: #12\n"
        let trailers = TrailerParser.parse(output)
        XCTAssertEqual(trailers.map(\.key), ["Co-authored-by", "Signed-off-by", "Fixes"])
        XCTAssertEqual(trailers[0].person.name, "Zoë Ünïcode")
        XCTAssertEqual(trailers[0].person.email, "zoe@example.com")
        XCTAssertTrue(CommitTrailer(key: "Co-Authored-By", value: "x").isCoAuthor, "keys compare case-insensitively")
        XCTAssertEqual(trailers[2].person.name, "#12", "a value without address is all name")
    }

    func testLogAndInterpretTrailersReadTheSameTrailersAndTheBodyDropsThem() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let message = "Add feature\n\nExplains why.\nKey: not a trailer, inside the paragraph\n\nCo-Authored-By: Ada <ada@example.com>\nReviewed-by: Bob\n  folded on\nFixes: #7"
        try fixture.write("a.txt", "a\n")
        try fixture.git("add", "a.txt")
        try fixture.git("commit", "-q", "-m", message)

        let commit = try await fixture.repository.collectLog()[0]
        let parsed = await fixture.repository.trailers(of: message)
        XCTAssertEqual(commit.trailers, parsed)
        XCTAssertEqual(parsed, [CommitTrailer(key: "Co-Authored-By", value: "Ada <ada@example.com>"), CommitTrailer(key: "Reviewed-by", value: "Bob folded on"), CommitTrailer(key: "Fixes", value: "#7")])
        XCTAssertEqual(commit.coAuthors.map(\.person.name), ["Ada"])
        XCTAssertEqual(CommitTrailer.body(commit.body, without: commit.trailers), "Explains why.\nKey: not a trailer, inside the paragraph")
        XCTAssertTrue(CommitSearch("ada@example")!.matches(commit), "the search finds co-authors")
    }

    func testMessageWithoutTrailersHasNone() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        _ = try fixture.commit("Only a subject")
        let commit = try await fixture.repository.collectLog()[0]
        XCTAssertEqual(commit.trailers, [])
        let parsed = await fixture.repository.trailers(of: "Subject: with a colon\n\nPlain body.")
        XCTAssertEqual(parsed, [], "a subject is never a trailer, nor is a paragraph of prose")
    }

    func testCommitWritesCoAuthorAndSignOffOnceEach() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.write("a.txt", "a\n")
        try fixture.git("add", "a.txt")
        let ada = CommitTrailer(key: CommitTrailer.coAuthorKey, value: "Ada <ada@example.com>")
        try await fixture.repository.commit(message: "Pair work\n\nBody.", amend: false, trailers: [ada], signOff: true)
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B"), "Pair work\n\nBody.\n\nCo-authored-by: Ada <ada@example.com>\nSigned-off-by: Fixture <fixture@example.com>")

        try await fixture.repository.commit(message: try fixture.git("log", "-1", "--format=%B"), amend: true, trailers: [ada], signOff: true)
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%(trailers:only,unfold)").split(separator: "\n").count, 2, "amending with the same trailers does not repeat them")
    }

    func testTemplateDropsCommentLinesAndResolvesRelativePaths() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let repository = fixture.repository
        let empty = await repository.commitTemplate()
        XCTAssertNil(empty)
        try fixture.write(".gitmessage", "# Why this change?\n\nTicket: \n# Lines with # are hints\n")
        try fixture.git("config", "commit.template", ".gitmessage")
        let template = await repository.commitTemplate()
        XCTAssertEqual(template, "Ticket:")
        try fixture.git("config", "commit.template", "missing.txt")
        let missing = await repository.commitTemplate()
        XCTAssertNil(missing)
    }

    func testKnownAuthorsFromShortlog() {
        let authors = KnownAuthor.parseShortlog("    12\tAda Lovelace <ada@example.com>\n     1\tZoë <zoe@example.com>\n")
        XCTAssertEqual(authors, [KnownAuthor(name: "Ada Lovelace", email: "ada@example.com"), KnownAuthor(name: "Zoë", email: "zoe@example.com")])
        XCTAssertEqual(authors[0].identity, "Ada Lovelace <ada@example.com>")
    }
}
