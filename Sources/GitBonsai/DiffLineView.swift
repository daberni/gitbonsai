import AppKit
import GitEngine

/// One line of a diff: old and new line number, the sign, the text. Added and removed lines are tinted, their changed part more strongly; invisible characters show as faint markers and named capsules.
final class DiffLineView: NSView {
    struct Content {
        let line: DiffLine
        let runs: [DiffLineText.Run]
        /// In place of `runs` for a word diff line that kept some words and changed others.
        var words: [Word] = []
    }

    /// Words both sides share, or that only the old (struck through) or the new side has.
    struct Word {
        let kind: DiffLine.Kind
        let runs: [DiffLineText.Run]
    }

    var content: Content? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let line = content.line
        typealias D = Theme.Diff
        let tint: NSColor? = switch line.kind {
        case .added: Theme.moss
        case .removed: Theme.persimmon
        case .context: nil
        }
        let numbers = CGRect(x: 0, y: 0, width: 2 * D.numberColumn, height: bounds.height)
        if let tint {
            tint.withAlphaComponent(D.lineTint).setFill()
            bounds.fill()
            tint.withAlphaComponent(D.numberTint).setFill()
            numbers.fill()
        } else {
            Theme.surface1.setFill()
            numbers.fill()
        }
        let top = Self.textTop(in: bounds)
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: Theme.inkFaint]
        func number(_ value: Int?, columnEnd: CGFloat) {
            guard let value else { return }
            let text = NSAttributedString(string: "\(value)", attributes: numberAttributes)
            text.draw(at: CGPoint(x: columnEnd - D.textInset - text.size().width, y: top))
        }
        number(line.oldNumber, columnEnd: D.numberColumn)
        number(line.newNumber, columnEnd: 2 * D.numberColumn)
        let sign = switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
        NSAttributedString(string: sign, attributes: [.font: Theme.mono, .foregroundColor: tint ?? Theme.inkMuted]).draw(at: CGPoint(x: numbers.maxX + D.textInset, y: top))
        var x = Self.textX
        for run in content.runs {
            x = draw(run, at: x, top: top, emphasis: tint)
        }
        for word in content.words {
            let wordTint: NSColor? = switch word.kind {
            case .added: Theme.moss
            case .removed: Theme.persimmon
            case .context: nil
            }
            for run in word.runs {
                x = draw(run, at: x, top: top, emphasis: wordTint, struck: word.kind == .removed)
            }
        }
        if line.missingNewline {
            let note = NSAttributedString(string: "  " + String(localized: "diff.noNewlineAtEnd", defaultValue: "⏎ missing at end of file", bundle: .module, comment: "Marks a last line without a newline"), attributes: [.font: Theme.caption, .foregroundColor: Theme.inkFaint])
            note.draw(at: CGPoint(x: x, y: bounds.midY - note.size().height / 2))
        }
    }

    /// Draws one run from `x` and returns where the next one starts.
    private func draw(_ run: DiffLineText.Run, at x: CGFloat, top: CGFloat, emphasis tint: NSColor?, struck: Bool = false) -> CGFloat {
        typealias D = Theme.Diff
        switch run.kind {
        case .text, .marker:
            let color = run.kind == .text ? Theme.ink : Theme.inkFaint
            var attributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: color]
            if struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let text = NSAttributedString(string: run.text, attributes: attributes)
            let width = text.size().width
            if run.emphasized, let tint {
                tint.withAlphaComponent(D.emphasisTint).setFill()
                CGRect(x: x, y: 0, width: width, height: bounds.height).fill()
            }
            text.draw(at: CGPoint(x: x, y: top))
            return x + width
        case .badge:
            let text = NSAttributedString(string: run.text, attributes: [.font: D.invisibleBadgeFont, .foregroundColor: Theme.inkMuted])
            let size = text.size()
            let capsule = CGRect(x: x + D.invisibleBadgeGap, y: (bounds.height - D.invisibleBadgeHeight) / 2, width: size.width + 2 * D.invisibleBadgePadding, height: D.invisibleBadgeHeight)
            if run.emphasized, let tint {
                tint.withAlphaComponent(D.emphasisTint).setFill()
                CGRect(x: x, y: 0, width: capsule.width + 2 * D.invisibleBadgeGap, height: bounds.height).fill()
            }
            let path = NSBezierPath(roundedRect: capsule.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: Theme.Radius.xs, yRadius: Theme.Radius.xs)
            Theme.inkFaint.setStroke()
            path.lineWidth = Theme.Stroke.hairline
            path.stroke()
            text.draw(at: CGPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2))
            return capsule.maxX + D.invisibleBadgeGap
        }
    }

    static var textX: CGFloat { 2 * Theme.Diff.numberColumn + Theme.Diff.textInset + Theme.Diff.signColumn }

    /// The text sits by the font's line height, never by the measured string, so no character can move or cut a line.
    private static func textTop(in bounds: CGRect) -> CGFloat {
        let font = Theme.mono
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return (bounds.height - lineHeight) / 2
    }

    /// Width of the widest line among `runs`, for the horizontal scroll range.
    static func width(ofColumns columns: Int) -> CGFloat {
        let characterWidth = NSAttributedString(string: "0", attributes: [.font: Theme.mono]).size().width
        return textX + CGFloat(columns) * characterWidth
    }
}

/// A sentence above the lines about the file as a whole, such as "Line endings: LF → CRLF".
final class DiffNoticeView: NSView {
    var text = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // The hunk header below draws the dividing line.
        Theme.surface1.setFill()
        bounds.fill()
        let label = NSAttributedString(string: text, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
        label.draw(at: CGPoint(x: DiffLineView.textX - Theme.Diff.signColumn, y: (bounds.height - label.size().height) / 2))
    }
}
