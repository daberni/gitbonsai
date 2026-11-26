import AppKit
import GitEngine
import TextViewerModel

/// The "Whole file" mode on the shared text viewer: the file's lines with old and new numbers beside them, changed lines washed in the colour of their side and the changed part of a paired line marked.
extension DiffViewController {
    /// Shows the whole file in the viewer; `hunkStarts` become line indices of the viewer.
    func showWholeFile(_ diff: FileDiff, notice: String?) {
        fileNotice.text = notice ?? ""
        fileNoticeHeight?.constant = notice == nil ? 0 : Theme.Diff.noticeHeight
        fileViewer.show(wholeFileContent())
        if style.options.wordDiff {
            // Word diff numbers follow the lines as shown, not the line diff's; navigation stops at each run of changed lines instead.
            let changed = fileLines.map { $0.kind != .context || !$0.segments.isEmpty }
            hunkStarts = changed.indices.filter { changed[$0] && ($0 == 0 || !changed[$0 - 1]) }.map { max(0, $0 - Self.contextAboveChange) }
        } else {
            // A hunk starts with the same line in both views, and a line's pair of old and new number occurs once in the file.
            let lineOfNumbers = Dictionary(fileLines.enumerated().map { (NumberPair($1), $0) }, uniquingKeysWith: { first, _ in first })
            hunkStarts = diff.hunks.compactMap { $0.lines.first.flatMap { lineOfNumbers[NumberPair($0)] } }
        }
    }

    /// git's default context, so a jump in a word diff lands where the hunk would start.
    static var contextAboveChange: Int { 3 }

    private func wholeFileContent() -> TextViewer.Content {
        let lines = fileLines
        let document = TextDocument(lines: lines.map(\.text), carriageReturns: lines.filter(\.carriageReturn).count)
        var decorations: [Int: TextViewerDecoration] = [:]
        let showsInvisibles = style.options.showsInvisibles
        for (index, line) in lines.enumerated() {
            let tint = Self.tint(of: line.kind)
            var decoration = TextViewerDecoration()
            decoration.wash = tint?.withAlphaComponent(Theme.Diff.lineTint)
            decoration.gutterWash = tint?.withAlphaComponent(Theme.Diff.numberTint)
            decoration.showsInvisibles = showsInvisibles && line.kind != .context
            decoration.carriageReturn = showsInvisibles && line.carriageReturn && style.notice == nil
            decoration.missingNewline = line.missingNewline
            decoration.marks = marks(of: line, at: index)
            let isPlain = tint == nil && decoration.marks.isEmpty && !decoration.missingNewline && !decoration.carriageReturn
            if !isPlain { decorations[index] = decoration }
        }
        return TextViewer.Content(document: document, language: selection.flatMap { SyntaxLanguage(path: $0.path) }, decorations: decorations, sideColumn: DiffSideColumn(lines: lines))
    }

    /// The changed part of a paired line, or each changed word of a word diff line in the colour of its side.
    private func marks(of line: DiffLine, at index: Int) -> [TextViewerDecoration.Mark] {
        guard line.segments.isEmpty else {
            var column = 0
            return line.segments.compactMap { segment in
                let length = segment.text.utf16.count
                defer { column += length }
                guard let tint = Self.tint(of: segment.kind) else { return nil }
                return TextViewerDecoration.Mark(columns: column..<(column + length), tint: tint.withAlphaComponent(Theme.Diff.emphasisTint), struck: segment.kind == .removed)
            }
        }
        guard let tint = Self.tint(of: line.kind), let scalars = style.change(ofFileLine: index)?.range else { return [] }
        let columns = Self.utf16Columns(of: scalars, in: line.text)
        return [TextViewerDecoration.Mark(columns: columns, tint: tint.withAlphaComponent(Theme.Diff.emphasisTint))]
    }

    /// The intraline diff counts Unicode scalars; the viewer counts UTF-16 units.
    private static func utf16Columns(of scalars: Range<Int>, in text: String) -> Range<Int> {
        let view = text.unicodeScalars
        let lower = view.index(view.startIndex, offsetBy: min(scalars.lowerBound, view.count))
        let upper = view.index(view.startIndex, offsetBy: min(scalars.upperBound, view.count))
        let start = text.utf16.distance(from: text.utf16.startIndex, to: lower)
        return start..<(start + text.utf16.distance(from: lower, to: upper))
    }

    static func tint(of kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: Theme.moss
        case .removed: Theme.persimmon
        case .context: nil
        }
    }
}

/// The old and new line number and the sign of each line of the whole file, in the viewer's gutter.
@MainActor
final class DiffSideColumn: TextViewerSideColumn {
    private let lines: [DiffLine]

    init(lines: [DiffLine]) {
        self.lines = lines
    }

    var width: CGFloat { 2 * Theme.Diff.numberColumn + Theme.Diff.signColumn }

    func draw(line index: Int, in rect: CGRect) {
        guard lines.indices.contains(index) else { return }
        let line = lines[index]
        let font = Theme.mono
        let top = rect.minY + (rect.height - ceil(font.ascender - font.descender + font.leading)) / 2
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.inkFaint]
        func number(_ value: Int?, columnEnd: CGFloat) {
            guard let value else { return }
            let text = NSAttributedString(string: "\(value)", attributes: attributes)
            text.draw(at: CGPoint(x: rect.minX + columnEnd - Theme.Diff.textInset - text.size().width, y: top))
        }
        number(line.oldNumber, columnEnd: Theme.Diff.numberColumn)
        number(line.newNumber, columnEnd: 2 * Theme.Diff.numberColumn)
        let sign = switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
        let tint = DiffViewController.tint(of: line.kind) ?? Theme.inkMuted
        NSAttributedString(string: sign, attributes: [.font: font, .foregroundColor: tint]).draw(at: CGPoint(x: rect.minX + 2 * Theme.Diff.numberColumn + Theme.Diff.textInset / 2, y: top))
    }
}
