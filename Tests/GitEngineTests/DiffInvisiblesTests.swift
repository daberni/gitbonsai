import XCTest
@testable import GitEngine

/// Line endings, byte order marks, invisible and control characters as git passes them through, from the parser to the runs a line is drawn with.
final class DiffInvisiblesTests: XCTestCase {
    private func fixture() throws -> FixtureRepo {
        let fixture = try FixtureRepo()
        try fixture.git("config", "core.autocrlf", "false")
        return fixture
    }

    private func writeBytes(_ fixture: FixtureRepo, _ path: String, _ bytes: Data) throws {
        try bytes.write(to: fixture.url.appendingPathComponent(path))
    }

    private func commitBytes(_ fixture: FixtureRepo, _ path: String, _ bytes: Data, message: String) throws {
        try writeBytes(fixture, path, bytes)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", message)
    }

    private func headDiff(_ fixture: FixtureRepo, _ path: String) async throws -> FileDiff {
        let history = try await fixture.repository.collectLog()
        return try await XCTUnwrapAsync(await fixture.repository.diff(of: path, in: .commit(history[0])))
    }

    private func visibleRuns(_ line: DiffLine, change: IntralineChange? = nil, invisibles: Bool = true) -> [DiffLineText.Run] {
        DiffLineText.runs(line.text, options: DiffLineText.Options(showsInvisibles: invisibles, isChanged: line.kind != .context, isFileStart: line.oldNumber == 1 || line.newNumber == 1, marksCarriageReturn: invisibles && line.carriageReturn, carriageReturnEmphasized: change?.lineEndingChanged ?? false, emphasis: change?.range))
    }

    /// The commit from the report: an Eclipse `.classpath` from git-svn with CR LF endings, two entries moved. The CR used to stay in the text and AppKit laid each line out as two.
    func testOldCommitWithCRLFKeepsCarriageReturnOutOfTheText() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let old = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<classpath>", "\t<classpathentry kind=\"src\" path=\"src/main/java\"/>", "\t<classpathentry kind=\"src\" path=\"src/test/java\"/>", "\t<classpathentry kind=\"output\" path=\"target/classes\"/>", "</classpath>"]
        let new = [old[0], old[1], old[3], old[2], old[4], old[5]]
        try commitBytes(fixture, ".classpath", Data((old.joined(separator: "\r\n") + "\r\n").utf8), message: "base")
        try commitBytes(fixture, ".classpath", Data((new.joined(separator: "\r\n") + "\r\n").utf8), message: "making modules")

        let diff = try await headDiff(fixture, ".classpath")
        let lines = diff.hunks.flatMap(\.lines)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy(\.carriageReturn))
        XCTAssertFalse(lines.contains { $0.text.unicodeScalars.contains("\r") }, "no CR may reach the text a line is drawn from")
        XCTAssertEqual(lines.first?.text, old[0])
        XCTAssertNil(diff.lineEndingConversion, "only some lines changed")
        for line in lines {
            let runs = visibleRuns(line, invisibles: false)
            XCTAssertFalse(runs.contains { $0.text.unicodeScalars.contains { $0.value < 0x20 } }, "control characters never reach the drawing")
        }
    }

    /// The raw lines keep the CR, so a hunk of a CR LF file still applies to the index.
    func testCRLFHunkStillStages() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try commitBytes(fixture, "win.txt", Data("one\r\ntwo\r\nthree\r\n".utf8), message: "base")
        try writeBytes(fixture, "win.txt", Data("one\r\nzwei\r\nthree\r\n".utf8))
        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "win.txt", in: .unstaged))
        XCTAssertEqual(diff.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["zwei"])
        try await fixture.repository.stage(diff.hunks[0], of: diff)
        XCTAssertEqual(try fixture.git("rev-parse", ":win.txt"), try fixture.git("hash-object", "win.txt"), "the index holds the working tree's bytes, CRs included")
    }

    func testWholeFileConvertedToCRLFIsOneConversion() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try commitBytes(fixture, "unix.txt", Data("a\n\tb\nc".utf8), message: "base")
        try commitBytes(fixture, "unix.txt", Data("a\r\n\tb\r\nc".utf8), message: "convert")

        let diff = try await headDiff(fixture, "unix.txt")
        let conversion = try XCTUnwrap(diff.lineEndingConversion)
        XCTAssertEqual(conversion.from, .lf)
        XCTAssertEqual(conversion.to, .crlf)
    }

    func testMixedEndingsMarkTheLinesThatChanged() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try commitBytes(fixture, "mixed.txt", Data("first\nsecond\nthird\n".utf8), message: "base")
        try commitBytes(fixture, "mixed.txt", Data("first\r\nsecond\nthird line\r\n".utf8), message: "mixed")

        let diff = try await headDiff(fixture, "mixed.txt")
        XCTAssertNil(diff.lineEndingConversion, "a context line and a content change rule out a pure conversion")
        let lines = diff.hunks[0].lines
        let changes = IntralineDiff.changes(in: lines)
        let firstAdded = try XCTUnwrap(lines.firstIndex { $0.kind == .added && $0.text == "first" })
        XCTAssertEqual(changes[firstAdded], IntralineChange(range: nil, lineEndingChanged: true))
        XCTAssertEqual(visibleRuns(lines[firstAdded], change: changes[firstAdded]).last, DiffLineText.Run(kind: .marker, text: "␍", emphasized: true))
        let context = try XCTUnwrap(lines.first { $0.kind == .context })
        XCTAssertFalse(context.carriageReturn)
        let thirdAdded = try XCTUnwrap(lines.firstIndex { $0.kind == .added && $0.text == "third line" })
        XCTAssertEqual(changes[thirdAdded]?.range, 5..<10)
    }

    func testBOMOnlyChangeShowsABadgeOnTheFirstLine() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try commitBytes(fixture, "bom.txt", Data("<?xml?>\nrest\n".utf8), message: "base")
        try commitBytes(fixture, "bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("<?xml?>\nrest\n".utf8), message: "bom")

        let diff = try await headDiff(fixture, "bom.txt")
        let lines = diff.hunks[0].lines
        let changes = IntralineDiff.changes(in: lines)
        let added = try XCTUnwrap(lines.firstIndex { $0.kind == .added })
        XCTAssertEqual(lines[added].text, "\u{FEFF}<?xml?>")
        XCTAssertEqual(changes[added]?.range, 0..<1)
        XCTAssertEqual(visibleRuns(lines[added], change: changes[added]), [DiffLineText.Run(kind: .badge, text: "BOM", emphasized: true), DiffLineText.Run(kind: .text, text: "<?xml?>")])
        XCTAssertEqual(visibleRuns(lines[added], invisibles: false), [DiffLineText.Run(kind: .text, text: "<?xml?>")])
    }

    func testNBSPAndZeroWidthSpaceGetBadges() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try commitBytes(fixture, "price.txt", Data("10 EUR\nhello world\n".utf8), message: "base")
        try commitBytes(fixture, "price.txt", Data("10\u{00A0}EUR\nhello\u{200B} world\n".utf8), message: "nbsp")

        let diff = try await headDiff(fixture, "price.txt")
        let lines = diff.hunks[0].lines
        let changes = IntralineDiff.changes(in: lines)
        let nbsp = try XCTUnwrap(lines.firstIndex { $0.kind == .added && $0.text.hasPrefix("10") })
        XCTAssertEqual(visibleRuns(lines[nbsp], change: changes[nbsp]), [DiffLineText.Run(kind: .text, text: "10"), DiffLineText.Run(kind: .badge, text: "NBSP", emphasized: true), DiffLineText.Run(kind: .text, text: "EUR")])
        let removed = try XCTUnwrap(lines.firstIndex { $0.kind == .removed && $0.text.hasPrefix("10") })
        XCTAssertEqual(visibleRuns(lines[removed], change: changes[removed])[1], DiffLineText.Run(kind: .text, text: " ", emphasized: true))
        let zwsp = try XCTUnwrap(lines.firstIndex { $0.kind == .added && $0.text.hasPrefix("hello") })
        XCTAssertTrue(visibleRuns(lines[zwsp], change: changes[zwsp]).contains(DiffLineText.Run(kind: .badge, text: "ZWSP", emphasized: true)))
        XCTAssertEqual(visibleRuns(lines[zwsp], invisibles: false).map(\.text).joined(), "hello\u{200B} world", "without the option the text stays as it is")
    }

    func testUTF16FileIsRecognisedAsText() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let utf16 = { (text: String) in Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)! }
        try commitBytes(fixture, "wide.txt", utf16("Hallo\r\n"), message: "base")
        try commitBytes(fixture, "wide.txt", utf16("Hallo Welt\r\n"), message: "change")

        let diff = try await headDiff(fixture, "wide.txt")
        XCTAssertTrue(diff.isBinary)
        let history = try await fixture.repository.collectLog()
        let encoding = await fixture.repository.wideTextEncoding(of: diff, in: .commit(history[0]))
        XCTAssertEqual(encoding, .utf16LE(bom: true))
        XCTAssertEqual(encoding?.workingTreeEncoding, "UTF-16LE-BOM")

        try writeBytes(fixture, "wide.txt", utf16("Hallo schöne Welt\r\n"))
        let unstaged = try await XCTUnwrapAsync(await fixture.repository.diff(of: "wide.txt", in: .unstaged))
        let unstagedEncoding = await fixture.repository.wideTextEncoding(of: unstaged, in: .unstaged)
        XCTAssertEqual(unstagedEncoding, .utf16LE(bom: true), "the working tree file is read directly")

        try commitBytes(fixture, "image.bin", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0xFF, 0x00, 0x00, 0x10]), message: "binary")
        let image = try await headDiff(fixture, "image.bin")
        let latest = try await fixture.repository.collectLog()
        let imageEncoding = await fixture.repository.wideTextEncoding(of: image, in: .commit(latest[0]))
        XCTAssertNil(imageEncoding)
    }

    func testWideEncodingWithoutByteOrderMark() {
        XCTAssertEqual(WideTextEncoding.detect("plain text here\n".data(using: .utf16BigEndian)!), .utf16BE(bom: false))
        XCTAssertEqual(WideTextEncoding.detect("plain text here\n".data(using: .utf16LittleEndian)!), .utf16LE(bom: false))
        XCTAssertEqual(WideTextEncoding.detect(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])), .utf32LE)
        XCTAssertNil(WideTextEncoding.detect(Data("plain UTF-8".utf8)))
    }

    /// Tabs and trailing spaces only in changed lines; control characters always, since AppKit would break or hide them.
    func testWhitespaceAndControlCharacters() {
        let changed = DiffLineText.Options(showsInvisibles: true, isChanged: true)
        XCTAssertEqual(DiffLineText.runs("\tx  ", options: changed), [DiffLineText.Run(kind: .marker, text: "→"), DiffLineText.Run(kind: .text, text: "   x"), DiffLineText.Run(kind: .marker, text: "··")])
        let context = DiffLineText.Options(showsInvisibles: true, isChanged: false)
        XCTAssertEqual(DiffLineText.runs("\tx  ", options: context), [DiffLineText.Run(kind: .text, text: "    x  ")])
        let hidden = DiffLineText.Options(showsInvisibles: false)
        XCTAssertEqual(DiffLineText.runs("a\u{1B}[0m\u{0}b\u{7F}", options: hidden), [DiffLineText.Run(kind: .text, text: "a"), DiffLineText.Run(kind: .marker, text: "␛"), DiffLineText.Run(kind: .text, text: "[0m"), DiffLineText.Run(kind: .marker, text: "␀"), DiffLineText.Run(kind: .text, text: "b"), DiffLineText.Run(kind: .marker, text: "␡")])
        XCTAssertEqual(DiffLineText.runs("a\u{2028}b\u{85}\r", options: hidden).filter { $0.kind != .text }.map(\.text), ["LSEP", "U+0085", "␍"])
    }

    /// A combining mark right after the sign forms one character with it; the line is still an added line.
    func testCombiningMarkAfterSignStaysAnAddedLine() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try commitBytes(fixture, "accent.txt", Data("base\n".utf8), message: "base")
        try commitBytes(fixture, "accent.txt", Data("base\n\u{0301}e\n".utf8), message: "accent")
        let diff = try await headDiff(fixture, "accent.txt")
        let added = try XCTUnwrap(diff.hunks[0].lines.last)
        XCTAssertEqual(added.kind, .added)
        XCTAssertEqual(added.text, "\u{0301}e")
    }

    /// Styles count scalars of the text, so a tab expanded to spaces or a character outside the BMP never shifts a colour onto its neighbour.
    func testStylesFollowScalarsAcrossTabsAndWideCharacters() {
        var options = DiffLineText.Options(showsInvisibles: false, tabWidth: 2)
        options.styles = [DiffLineText.StyledRange(range: 3..<6, style: 1)]
        let runs = DiffLineText.runs("\t😀 let x", options: options)
        XCTAssertEqual(runs.map(\.text), ["  😀 ", "let", " x"])
        XCTAssertEqual(runs.map(\.style), [nil, 1, nil])
    }
}
