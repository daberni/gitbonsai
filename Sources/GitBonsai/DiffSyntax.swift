import Foundation
import GitEngine
import TextViewerModel

/// Syntax colours for the lines of a diff's hunks. A hunk alone cuts strings and comments apart, so both whole versions of the file are parsed off the main thread; removed lines take the old version's colours, added and context lines the new one's.
struct DiffSyntax: Sendable {
    /// Styled stretches of each line, by line number of each side; a style is an index into `SyntaxToken.allCases`.
    var old: [Int: [DiffLineText.StyledRange]] = [:]
    var new: [Int: [DiffLineText.StyledRange]] = [:]

    func styles(of line: DiffLine) -> [DiffLineText.StyledRange] {
        switch line.kind {
        case .removed: line.oldNumber.flatMap { old[$0] } ?? []
        case .added, .context: line.newNumber.flatMap { new[$0] } ?? []
        }
    }

    static func token(ofStyle style: Int) -> SyntaxToken? {
        SyntaxToken.allCases.indices.contains(style) ? SyntaxToken.allCases[style] : nil
    }

    /// Nil for a language without a grammar or when neither side can be read.
    static func load(_ diff: FileDiff, path: String, source: DiffSource, from repository: Repository) async -> DiffSyntax? {
        guard let language = SyntaxLanguage(path: path), !diff.isBinary else { return nil }
        let interval = Signposts.begin("diff.highlight", language.rawValue)
        defer { interval.end() }
        let sides = repository.blobSides(of: diff, in: source)
        let lines = diff.hunks.flatMap(\.lines)
        async let old = side(sides.old, numbers: lines.filter { $0.kind == .removed }.compactMap(\.oldNumber), texts: lines, language: language, from: repository, number: \.oldNumber)
        async let new = side(sides.new, numbers: lines.filter { $0.kind != .removed }.compactMap(\.newNumber), texts: lines, language: language, from: repository, number: \.newNumber)
        let syntax = DiffSyntax(old: await old, new: await new)
        return syntax.old.isEmpty && syntax.new.isEmpty ? nil : syntax
    }

    private static func side(_ location: BlobLocation?, numbers: [Int], texts: [DiffLine], language: SyntaxLanguage, from repository: Repository, number: KeyPath<DiffLine, Int?>) async -> [Int: [DiffLineText.StyledRange]] {
        guard let location, !numbers.isEmpty, let data = try? await repository.blobData(at: location) else { return [:] }
        let document = TextDocument(data: data)
        guard let highlighter = await SyntaxHighlighter.make(for: document, language: language) else { return [:] }
        let textOf = Dictionary(texts.compactMap { line in line[keyPath: number].map { ($0, line.text) } }, uniquingKeysWith: { first, _ in first })
        var result: [Int: [DiffLineText.StyledRange]] = [:]
        for run in runs(of: Set(numbers).sorted()) {
            // Diff numbers count from 1; a line the file does not have, or whose text differs, stays plain.
            let first = run.lowerBound - 1, last = run.upperBound - 1
            guard first >= 0, last < document.lineCount else { continue }
            let start = document.range(ofLine: first).location
            let range = NSRange(location: start, length: NSMaxRange(document.range(ofLine: last)) - start)
            let spans = await highlighter.spans(in: range)
            let text = document.text as NSString
            for line in first...last {
                let lineRange = document.range(ofLine: line)
                let lineText = text.substring(with: lineRange)
                guard textOf[line + 1] == lineText else { continue }
                let styles = spans.compactMap { span -> DiffLineText.StyledRange? in
                    let clipped = NSIntersectionRange(span.range, lineRange)
                    guard clipped.length > 0, let style = SyntaxToken.allCases.firstIndex(of: span.token) else { return nil }
                    return DiffLineText.StyledRange(range: scalars(of: NSRange(location: clipped.location - lineRange.location, length: clipped.length), in: lineText), style: style)
                }
                if !styles.isEmpty { result[line + 1] = styles }
            }
        }
        return result
    }

    /// Consecutive numbers grouped, so each hunk is highlighted in one request.
    private static func runs(of numbers: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for number in numbers {
            if let last = result.last, last.upperBound + 1 == number { result[result.count - 1] = last.lowerBound...number } else { result.append(number...number) }
        }
        return result
    }

    /// The highlighter counts UTF-16 units; the diff's line text counts Unicode scalars.
    private static func scalars(of range: NSRange, in text: String) -> Range<Int> {
        let utf16 = text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: range.location).samePosition(in: text.unicodeScalars) ?? text.unicodeScalars.startIndex
        let upper = utf16.index(utf16.startIndex, offsetBy: NSMaxRange(range)).samePosition(in: text.unicodeScalars) ?? text.unicodeScalars.endIndex
        let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: lower)
        return start..<(start + text.unicodeScalars.distance(from: lower, to: upper))
    }
}
