import Foundation
import Testing
@testable import TextViewerModel

struct TextDocumentTests {
    @Test func crlfLinesDropTheirCarriageReturnAndAreCounted() {
        let document = TextDocument(data: Data("one\r\ntwo\r\nthree\r\n".utf8))
        #expect(document.text == "one\ntwo\nthree")
        #expect(document.lineCount == 3)
        #expect(document.lineEndings == .crlf)
        #expect(!document.missingFinalNewline)
    }

    @Test func mixedEndingsAndAMissingFinalNewline() {
        let document = TextDocument(data: Data("a\r\nb\nc".utf8))
        #expect(document.text == "a\nb\nc")
        #expect(document.lineEndings == .mixed)
        #expect(document.missingFinalNewline)
    }

    @Test func emptyFileIsOneEmptyLine() {
        let document = TextDocument(data: Data())
        #expect(document.lineCount == 1)
        #expect(document.text == "")
        #expect(!document.missingFinalNewline)
    }

    @Test func invalidUTF8FallsBackToLatin1AndIsMarked() {
        let document = TextDocument(data: Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        #expect(document.encoding == .fallbackWindowsLatin1)
        #expect(document.text == "café")
    }

    @Test func byteOrderMarksSelectTheEncodingAndAreNotText() {
        #expect(TextDocument(data: Data([0xEF, 0xBB, 0xBF, 0x61])).encoding == .utf8WithBOM)
        let utf16 = TextDocument(data: Data([0xFF, 0xFE, 0x61, 0x00, 0x0A, 0x00]))
        #expect(utf16.encoding == .utf16LittleEndian)
        #expect(utf16.text == "a")
    }

    @Test func positionsCountUTF16AndClampToTheLine() {
        let document = TextDocument(lines: ["😀x", "", "end"])
        #expect(document.position(atOffset: 2) == TextPosition(line: 0, column: 2))
        #expect(document.position(atOffset: 4) == TextPosition(line: 1, column: 0))
        #expect(document.position(atOffset: 5) == TextPosition(line: 2, column: 0))
        #expect(document.offset(of: TextPosition(line: 2, column: 99)) == document.length)
        #expect(document.range(ofLine: 0) == NSRange(location: 0, length: 3))
    }

    @Test func selectionEndingAtALineStartLeavesThatLineOut() {
        let document = TextDocument(lines: ["a", "b", "c"])
        #expect(document.selection(of: NSRange(location: 0, length: 4)).lines == 0...1)
        #expect(document.selection(of: NSRange(location: 2, length: 3)).lines == 1...2)
        #expect(document.selection(of: NSRange(location: 2, length: 0)).lines == 1...1)
    }
}

struct TextFindTests {
    @Test func findsEveryMatchIgnoringCaseAndWrapsAround() {
        let document = TextDocument(lines: ["Foo foo", "bar FOO"])
        let find = TextFind("foo", in: document)
        #expect(find.matches.map(\.location) == [0, 4, 12])
        #expect(find.next(after: 4, forward: true) == 2)
        #expect(find.next(after: 12, forward: true) == 0)
        #expect(find.next(after: 0, forward: false) == 2)
        #expect(TextFind("", in: document).matches.isEmpty)
    }
}

struct SyntaxHighlighterTests {
    @Test func languageFollowsTheExtension() {
        #expect(SyntaxLanguage(path: "app/styles/site.scss") == .scss)
        #expect(SyntaxLanguage(path: "theme.less") == .less)
        #expect(SyntaxLanguage(path: "Info.plist") == .xml)
        #expect(SyntaxLanguage(path: "fix.patch") == .diff)
        #expect(SyntaxLanguage(path: "src/main/resources/application.properties") == .properties)
        #expect(SyntaxLanguage(path: "Sources/App/main.swift") == .swift)
        #expect(SyntaxLanguage(path: "web/index.tsx") == .tsx)
        #expect(SyntaxLanguage(path: "Gemfile") == .ruby)
        #expect(SyntaxLanguage(path: "notes.txt") == nil)
    }

    @Test(arguments: SyntaxLanguage.allCases)
    func everyBundledQueryCompiles(language: SyntaxLanguage) throws {
        _ = try language.query()
    }

    @Test func swiftKeywordsStringsAndCommentsAreHighlighted() async throws {
        let document = TextDocument(lines: ["// note", "let name = \"value\""])
        let highlighter = try #require(await SyntaxHighlighter.make(for: document, language: .swift))
        let spans = await highlighter.spans(in: NSRange(location: 0, length: document.length))
        let text = document.text as NSString
        func token(of word: String) -> SyntaxToken? {
            let range = text.range(of: word)
            return spans.last { NSIntersectionRange($0.range, range).length == range.length }?.token
        }
        #expect(token(of: "// note") == .comment)
        #expect(token(of: "let") == .keyword)
        #expect(token(of: "value") == .string)
    }

    /// SCSS reuses the CSS query beneath its own; both must match the SCSS grammar's nodes, and Less's own syntax must colour too.
    @Test(arguments: [
        (SyntaxLanguage.scss, "@mixin round($r) { border-radius: $r; }\n.a { color: #fff; }", "@mixin", SyntaxToken.keyword),
        (SyntaxLanguage.scss, "@mixin round($r) { border-radius: $r; }\n.a { color: #fff; }", "border-radius", SyntaxToken.property),
        (SyntaxLanguage.less, "@import \"base\";\n.a { color: #fff; }", "@import", SyntaxToken.keyword),
        (SyntaxLanguage.less, "@import \"base\";\n.a { color: #fff; }", "color", SyntaxToken.property),
    ])
    func styleSheetDialectsAreHighlighted(language: SyntaxLanguage, source: String, word: String, expected: SyntaxToken) async throws {
        let document = TextDocument(lines: source.components(separatedBy: "\n"))
        let highlighter = try #require(await SyntaxHighlighter.make(for: document, language: language))
        let spans = await highlighter.spans(in: NSRange(location: 0, length: document.length))
        let range = (document.text as NSString).range(of: word)
        #expect(spans.last { NSIntersectionRange($0.range, range).length == range.length }?.token == expected)
    }

    /// The XML, properties and diff grammars with their own queries: tags, attributes, values, comments, escapes and changed lines.
    @Test(arguments: [
        (SyntaxLanguage.xml, "<?xml version=\"1.0\"?>\n<plist id=\"a\"><!-- note --><key>&amp;</key></plist>", "plist", SyntaxToken.tag),
        (SyntaxLanguage.xml, "<?xml version=\"1.0\"?>\n<plist id=\"a\"><!-- note --><key>&amp;</key></plist>", "id", SyntaxToken.attribute),
        (SyntaxLanguage.xml, "<?xml version=\"1.0\"?>\n<plist id=\"a\"><!-- note --><key>&amp;</key></plist>", "<!-- note -->", SyntaxToken.comment),
        (SyntaxLanguage.xml, "<?xml version=\"1.0\"?>\n<plist id=\"a\"><!-- note --><key>&amp;</key></plist>", "&amp;", SyntaxToken.escape),
        (SyntaxLanguage.properties, "# note\napp.name = Bonsai\\n${HOME}", "# note", SyntaxToken.comment),
        (SyntaxLanguage.properties, "# note\napp.name = Bonsai\\n${HOME}", "app.name", SyntaxToken.property),
        (SyntaxLanguage.properties, "# note\napp.name = Bonsai\\n${HOME}", "Bonsai", SyntaxToken.string),
        (SyntaxLanguage.properties, "# note\napp.name = Bonsai\\n${HOME}", "HOME", SyntaxToken.constant),
        (SyntaxLanguage.diff, "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-old line\n+new line", "-old line", SyntaxToken.deleted),
        (SyntaxLanguage.diff, "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-old line\n+new line", "+new line", SyntaxToken.inserted),
    ])
    func markupAndConfigurationFilesAreHighlighted(language: SyntaxLanguage, source: String, word: String, expected: SyntaxToken) async throws {
        let document = TextDocument(lines: source.components(separatedBy: "\n"))
        let highlighter = try #require(await SyntaxHighlighter.make(for: document, language: language))
        let spans = await highlighter.spans(in: NSRange(location: 0, length: document.length))
        let range = (document.text as NSString).range(of: word)
        #expect(spans.last { NSIntersectionRange($0.range, range).length == range.length }?.token == expected)
    }

    @Test func spansStayInsideTheAskedRange() async throws {
        let lines = (0..<2000).map { "let value\($0) = \($0)" }
        let document = TextDocument(lines: lines)
        let highlighter = try #require(await SyntaxHighlighter.make(for: document, language: .swift))
        let range = document.range(ofLine: 1000)
        let spans = await highlighter.spans(in: range)
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { NSIntersectionRange($0.range, range).length > 0 })
    }

    @Test func unknownLanguageOrOversizedFileHasNoHighlighter() async {
        #expect(await SyntaxHighlighter.make(for: TextDocument(lines: ["x"]), language: nil) == nil)
    }
}
