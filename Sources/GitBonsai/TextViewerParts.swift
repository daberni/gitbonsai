import AppKit
import CodeEditTextView
import TextViewerModel

/// The text itself: CodeEditTextView, read-only, with the viewer's keys for find and go to line while it has the focus.
final class ViewerTextView: TextView {
    weak var viewer: TextViewer?

    /// The text takes the focus on a click although it cannot be selected, so ⌘F, ⌘G and ⌘L reach the viewer.
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard let viewer, !viewer.findBar.isHidden else { return super.cancelOperation(sender) }
        viewer.hideFindBar()
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? {
        String(localized: "files.viewer.accessibility.label", defaultValue: "File text", bundle: .module, comment: "Accessibility label of the read-only text viewer")
    }

    /// The line with the caret, which VoiceOver reads with the text.
    override func accessibilityValueDescription() -> String? {
        guard let viewer, let selection = viewer.selections.first else { return nil }
        return String(localized: "files.viewer.accessibility.line", defaultValue: "Line \(selection.start.line + 1)", bundle: .module, comment: "Accessibility description of the line with the caret")
    }
}

/// Line numbers or the caller's side column, outside the scroll view so they stay in place sideways and are never selected or copied.
final class TextViewerGutter: NSView {
    weak var viewer: TextViewer?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        guard let viewer, let content = viewer.content else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: Theme.inkFaint]
        let textTop = (Theme.TextViewer.lineHeight - ceil(Theme.mono.ascender - Theme.mono.descender + Theme.mono.leading)) / 2
        for row in viewer.visibleLines() {
            let rect = CGRect(x: 0, y: convert(NSPoint(x: 0, y: row.y), from: viewer).y, width: bounds.width, height: row.height)
            guard rect.intersects(dirtyRect) else { continue }
            if let wash = content.decorations[row.line]?.gutterWash {
                wash.setFill()
                rect.fill()
            }
            if let side = content.sideColumn {
                side.draw(line: row.line, in: rect)
            } else {
                let number = NSAttributedString(string: "\(row.line + 1)", attributes: attributes)
                number.draw(at: CGPoint(x: rect.maxX - Theme.TextViewer.textInset - number.size().width, y: rect.minY + textTop))
            }
        }
    }
}

/// Behind the transparent text: line washes, marked parts, find matches, markers for invisible characters and the note on a missing final newline.
final class TextViewerBackdrop: NSView {
    weak var viewer: TextViewer?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface0.setFill()
        bounds.fill()
        guard let viewer, let content = viewer.content else { return }
        let document = content.document
        let lines = viewer.visibleLines()
        for row in lines {
            let rowRect = CGRect(x: 0, y: convert(NSPoint(x: 0, y: row.y), from: viewer).y, width: bounds.width, height: row.height)
            guard rowRect.intersects(dirtyRect), let decoration = content.decorations[row.line] else { continue }
            if let wash = decoration.wash {
                wash.setFill()
                rowRect.fill()
            }
            for mark in decoration.marks {
                guard let rect = rect(of: TextViewer.range(of: mark.columns, inLine: row.line, of: document)) else { continue }
                mark.tint.setFill()
                CGRect(x: rect.minX, y: rowRect.minY, width: rect.width, height: rowRect.height).fill()
            }
            if decoration.showsInvisibles { drawInvisibles(line: row.line, decoration: decoration, in: rowRect, document: document) }
        }
        drawMatches(in: lines)
        drawMissingNewlines(in: lines, content: content)
    }

    private func rect(of range: NSRange) -> CGRect? {
        guard let viewer, let rect = viewer.rect(of: range) else { return nil }
        return convert(rect, from: viewer)
    }

    private func drawMatches(in lines: [(line: Int, y: CGFloat, height: CGFloat)]) {
        guard let viewer, let find = viewer.find, let document = viewer.content?.document, let first = lines.first?.line, let last = lines.last?.line else { return }
        let visible = NSRange(location: document.lineStarts[first], length: NSMaxRange(document.range(ofLine: last)) - document.lineStarts[first])
        for (index, match) in find.matches.enumerated() where NSIntersectionRange(match, visible).length > 0 {
            guard let rect = rect(of: match) else { continue }
            Theme.ochre.withAlphaComponent(index == viewer.currentMatch ? Theme.TextViewer.currentMatchWash : Theme.TextViewer.matchWash).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.xs, yRadius: Theme.Radius.xs).fill()
        }
    }

    /// `→` for a tab, `·` for a trailing space, a dot under characters that take no room or look like a space, `␍` after a CR LF line.
    private func drawInvisibles(line: Int, decoration: TextViewerDecoration, in rowRect: CGRect, document: TextDocument) {
        let lineRange = document.range(ofLine: line)
        let text = (document.text as NSString).substring(with: lineRange) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: Theme.inkFaint]
        var trailingStart = text.length
        while trailingStart > 0, text.character(at: trailingStart - 1) == 0x20 { trailingStart -= 1 }
        for column in 0..<text.length {
            let character = text.character(at: column)
            let marker: String? = switch character {
            case 0x09: "→"
            case 0x20 where column >= trailingStart: "·"
            case 0x00A0, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD: "•"
            default: nil
            }
            guard let marker, let rect = rect(of: NSRange(location: lineRange.location + column, length: 1)) else { continue }
            let glyph = NSAttributedString(string: marker, attributes: attributes)
            glyph.draw(at: CGPoint(x: rect.minX, y: rowRect.midY - glyph.size().height / 2))
        }
        if decoration.carriageReturn, let end = rect(of: NSRange(location: NSMaxRange(lineRange), length: 0)) {
            let glyph = NSAttributedString(string: "␍", attributes: attributes)
            glyph.draw(at: CGPoint(x: end.minX, y: rowRect.midY - glyph.size().height / 2))
        }
    }

    private func drawMissingNewlines(in lines: [(line: Int, y: CGFloat, height: CGFloat)], content: TextViewer.Content) {
        let note = NSAttributedString(string: "  " + String(localized: "diff.noNewlineAtEnd", defaultValue: "⏎ missing at end of file", bundle: .module, comment: "Marks a last line without a newline"), attributes: [.font: Theme.caption, .foregroundColor: Theme.inkFaint])
        for row in lines {
            let isLast = row.line == content.document.lineCount - 1
            let missing = content.decorations[row.line]?.missingNewline ?? (isLast && content.document.missingFinalNewline)
            guard missing, let end = rect(of: NSRange(location: NSMaxRange(content.document.range(ofLine: row.line)), length: 0)) else { continue }
            let y = convert(NSPoint(x: 0, y: row.y), from: viewer).y
            note.draw(at: CGPoint(x: end.minX, y: y + (row.height - note.size().height) / 2))
        }
    }
}
