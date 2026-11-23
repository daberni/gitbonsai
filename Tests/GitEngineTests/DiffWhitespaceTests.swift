import XCTest
@testable import GitEngine

final class DiffWhitespaceTests: XCTestCase {
    func testWordDiffMarksChangedWordsWithinTheLine() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "text.txt", contents: "one two three\nkeep\nüber alles\n")
        try fixture.write("text.txt", "one TWO three\nkeep\nübel straße alles\nnew line\n")

        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "text.txt", in: .unstaged, words: true))
        let lines = try XCTUnwrap(diff.hunks.first?.lines)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].kind, .context)
        XCTAssertEqual(lines[0].segments, [DiffSegment(kind: .context, text: "one "), DiffSegment(kind: .removed, text: "two"), DiffSegment(kind: .added, text: "TWO"), DiffSegment(kind: .context, text: " three")])
        XCTAssertEqual(lines[0].oldNumber, 1)
        XCTAssertEqual(lines[0].newNumber, 1)
        XCTAssertEqual(lines[1], DiffLine(kind: .context, text: "keep", oldNumber: 2, newNumber: 2))
        XCTAssertEqual(lines[2].segments.filter { $0.kind == .added }.map(\.text), ["übel straße"])
        XCTAssertEqual(lines[2].segments.filter { $0.kind == .removed }.map(\.text), ["über"])
        XCTAssertEqual(lines[3], DiffLine(kind: .added, text: "new line", oldNumber: nil, newNumber: 4), "a line of only added words is an added line, without segments")
        XCTAssertTrue(diff.hunks[0].rawPatch.isEmpty, "a word diff cannot be applied")
    }

    func testWordDiffOfRemovedLinesAndADeletedFile() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "a.txt", contents: "first\nsecond\nthird\n")
        try fixture.commit("gone", file: "b.txt", contents: "only\n")
        try fixture.write("a.txt", "first\nthird\n")
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("b.txt"))

        let removed = try await XCTUnwrapAsync(await fixture.repository.diff(of: "a.txt", in: .unstaged, words: true))
        XCTAssertEqual(removed.hunks[0].lines.map(\.kind), [.context, .removed, .context])
        XCTAssertEqual(removed.hunks[0].lines.map(\.newNumber), [1, nil, 2])
        XCTAssertEqual(removed.hunks[0].lines.map(\.oldNumber), [1, 2, 3])

        let deleted = try await XCTUnwrapAsync(await fixture.repository.diff(of: "b.txt", in: .unstaged, words: true))
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertEqual(deleted.hunks[0].lines, [DiffLine(kind: .removed, text: "only", oldNumber: 1, newNumber: nil)])
    }

    /// git prints no "\ No newline" in porcelain word diffs of its own, but the marker is part of the format and binds to the line before it.
    func testWordDiffNoNewlineMarkerAndALastLineWithoutTilde() throws {
        let output = """
        diff --git a/f b/f
        index 1..2 100644
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
         a
        ~
        -b
        +c
        \\ No newline at end of file
        ~
         z
        """
        let diff = try XCTUnwrap(DiffParser.parse(Data(output.utf8), words: true).first)
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.map(\.text), ["a", "bc", "z"])
        XCTAssertEqual(lines[1].segments.map(\.kind), [.removed, .added])
        XCTAssertEqual(lines[1].kind, .context, "a line of removed and added words exists on both sides")
        XCTAssertFalse(lines[0].missingNewline)
        XCTAssertTrue(lines[1].missingNewline)
        XCTAssertEqual(lines[2], DiffLine(kind: .context, text: "z", oldNumber: 3, newNumber: 3), "a run at the end without its tilde still ends a line")
    }

    func testIgnoringWhitespace() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "code.txt", contents: "if x {\n\tcall()\n}\n")
        try fixture.write("code.txt", "if  x {\r\n    call ()\n\n}\n")

        let plain = try await XCTUnwrapAsync(await fixture.repository.diff(of: "code.txt", in: .unstaged))
        XCTAssertEqual(plain.stat, DiffStat(added: 3, removed: 2))
        let changes = try await XCTUnwrapAsync(await fixture.repository.diff(of: "code.txt", in: .unstaged, whitespace: DiffWhitespace(ignoring: .changes)))
        XCTAssertEqual(changes.stat, DiffStat(added: 2, removed: 1), "-b still sees whitespace where there was none, and the blank line")
        let all = try await XCTUnwrapAsync(await fixture.repository.diff(of: "code.txt", in: .unstaged, whitespace: DiffWhitespace(ignoring: .all)))
        XCTAssertEqual(all.stat, DiffStat(added: 1, removed: 0), "only the blank line is left")
        let none = try await fixture.repository.diff(of: "code.txt", in: .unstaged, whitespace: DiffWhitespace(ignoring: .all, ignoresBlankLines: true))
        XCTAssertNil(none, "a file whose only changes are whitespace has no diff")
    }

    func testIgnoringWhitespaceInAnUntrackedFile() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.write("new.txt", "\n\nhello  world\n")

        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "new.txt", in: .untracked, whitespace: DiffWhitespace(ignoring: .all), words: true))
        XCTAssertTrue(diff.isNew)
        XCTAssertEqual(diff.hunks[0].lines.last?.text, "hello  world")
        XCTAssertEqual(diff.hunks[0].lines.last?.kind, .added)
    }
}
