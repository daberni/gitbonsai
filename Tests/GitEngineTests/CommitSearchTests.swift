import Foundation
import XCTest
@testable import GitEngine

final class CommitSearchTests: XCTestCase {
    private func commit(_ id: String, subject: String, body: String = "", author: String = "Ada Lovelace", email: String = "ada@example.com") -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: [], authorName: author, authorEmail: email, authorDate: date, committerName: author, committerEmail: email, committerDate: date, subject: subject, body: body)
    }

    func testEmptyQueryIsNoSearch() {
        XCTAssertNil(CommitSearch(""))
        XCTAssertNil(CommitSearch("  \n"))
        XCTAssertEqual(CommitSearch("  fix ")?.text, "fix")
    }

    func testMatchesEveryFieldCaseInsensitively() throws {
        let sample = commit("0123abcd", subject: "Fix the Parser", body: "Handles RENAMES now.", author: "Grace Hopper", email: "grace@navy.mil")
        for query in ["parser", "PARSER", "renames", "grace hop", "NAVY.MIL"] {
            XCTAssertTrue(try XCTUnwrap(CommitSearch(query)).matches(sample), query)
        }
        XCTAssertFalse(try XCTUnwrap(CommitSearch("lexer")).matches(sample))
    }

    func testRefNamesMatch() throws {
        let sample = commit("0123abcd", subject: "Initial")
        let search = try XCTUnwrap(CommitSearch("release/2"))
        XCTAssertFalse(search.matches(sample))
        XCTAssertTrue(search.matches(sample, refNames: ["origin/Release/2.0", "v2.0"]))
    }

    func testUnicodeQueryFoldsCase() throws {
        let sample = commit("0123abcd", subject: "Füge Ünïcode hinzu 🌳", author: "Jürgen Öhler")
        XCTAssertTrue(try XCTUnwrap(CommitSearch("ÜNÏCODE")).matches(sample))
        XCTAssertTrue(try XCTUnwrap(CommitSearch("jürgen öh")).matches(sample))
        XCTAssertTrue(try XCTUnwrap(CommitSearch("🌳")).matches(sample))
        XCTAssertFalse(try XCTUnwrap(CommitSearch("über")).matches(sample))
    }

    /// Short hex words are ordinary text; only a prefix of four or more characters selects by SHA.
    func testSHAPrefixNeedsFourCharacters() throws {
        let sample = commit("deadbeef0123", subject: "Unrelated")
        XCTAssertFalse(try XCTUnwrap(CommitSearch("dea")).matches(sample))
        XCTAssertTrue(try XCTUnwrap(CommitSearch("dead")).matches(sample))
        XCTAssertTrue(try XCTUnwrap(CommitSearch("DEADBEEF")).matches(sample))
        XCTAssertFalse(try XCTUnwrap(CommitSearch("beef")).matches(sample), "only a prefix selects by SHA")
    }

    func testMatchingIndicesWithinRange() throws {
        let commits = [
            commit("a1", subject: "fix one"),
            commit("a2", subject: "feature"),
            commit("a3", subject: "Fix two"),
            commit("a4", subject: "docs", body: "also a fix"),
        ]
        let search = try XCTUnwrap(CommitSearch("fix"))
        XCTAssertEqual(search.matchingIndices(in: commits, range: 0..<4, refNames: [:]), [0, 2, 3])
        XCTAssertEqual(search.matchingIndices(in: commits, range: 1..<3, refNames: [:]), [2])
        XCTAssertEqual(search.matchingIndices(in: commits, range: 0..<4, refNames: ["a2": ["fixes"]]), [0, 1, 2, 3])
    }

    func testOccurrencesForHighlighting() throws {
        let search = try XCTUnwrap(CommitSearch("ab"))
        XCTAssertEqual(search.occurrences(in: "Ab cab ABAB"), [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2), NSRange(location: 7, length: 2), NSRange(location: 9, length: 2)])
        XCTAssertEqual(try XCTUnwrap(CommitSearch("🌳")).occurrences(in: "a 🌳 b"), [NSRange(location: 2, length: 2)])
        XCTAssertEqual(search.occurrences(in: "none"), [])
    }

    /// The history can hold 100k commits; one full pass has to stay well below a frame budget per chunk the app scans.
    func testPerformanceHundredThousandCommits() throws {
        let commits = (0..<100_000).map { index in
            commit(String(format: "%040x", index), subject: "Change number \(index) in module \(index % 97)", body: "Body line for commit \(index).\nRefs #\(index % 1000)", author: "Author \(index % 50)", email: "author\(index % 50)@example.com")
        }
        let search = try XCTUnwrap(CommitSearch("Module 42"))
        let miss = try XCTUnwrap(CommitSearch("zzz-not-there"))
        let unicode = try XCTUnwrap(CommitSearch("Müll"))
        let start = ContinuousClock.now
        let hits = search.matchingIndices(in: commits, range: 0..<commits.count, refNames: [:])
        let afterHits = ContinuousClock.now
        let none = miss.matchingIndices(in: commits, range: 0..<commits.count, refNames: [:])
        let afterMiss = ContinuousClock.now
        _ = unicode.matchingIndices(in: commits, range: 0..<commits.count, refNames: [:])
        let afterUnicode = ContinuousClock.now
        XCTAssertEqual(hits.count, (0..<100_000).filter { $0 % 97 == 42 }.count)
        XCTAssertTrue(none.isEmpty)
        print("CommitSearch 100k: hits \(afterHits - start), miss \(afterMiss - afterHits), unicode \(afterUnicode - afterMiss)")
        XCTAssertLessThan(afterMiss - afterHits, .milliseconds(300), "a miss scans every field of 100k commits")
        XCTAssertLessThan(afterUnicode - afterMiss, .milliseconds(300), "ASCII fields skip the Unicode search")
    }
}
