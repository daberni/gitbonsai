import AppKit

/// A name as a pill that keeps its full length: a name wider than the line wraps inside the pill instead of being cut. The tooltip carries the full name.
final class RefPillView: NSView {
    private typealias M = Theme.RefText
    private let name: String
    private let kind: RefKind
    private let textFont: NSFont
    private var textSize = NSSize.zero
    private var lineHeight: CGFloat { ceil(textFont.ascender - textFont.descender + textFont.leading) }
    private var glyph: CGFloat { lineHeight + M.extraHeight - 2 * M.glyphInset }
    private var textInset: CGFloat { M.padding + glyph + M.glyphGap }

    init(_ name: String, kind: RefKind, font: NSFont) {
        self.name = name
        self.kind = kind
        textFont = RefText.textFont(kind, like: font)
        super.init(frame: .zero)
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var attributedName: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: name, attributes: [.font: textFont, .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
    }

    /// The pill's size when it may be at most `width` wide.
    func fit(width: CGFloat) -> NSSize {
        let available = max(width - textInset - M.trailingPadding, glyph)
        let bounds = attributedName.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        textSize = NSSize(width: ceil(bounds.width), height: max(ceil(bounds.height), lineHeight))
        return NSSize(width: textInset + textSize.width + M.trailingPadding, height: textSize.height + M.extraHeight + 2 * Theme.Confirmation.pillInset)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let single = lineHeight + M.extraHeight + 2 * Theme.Confirmation.pillInset
        RefText.color(kind).mixed(into: Theme.surface0, fraction: Theme.Pill.tint.plain).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: single / 2, yRadius: single / 2).fill()
        let glyphRect = CGRect(x: M.padding, y: (single - glyph) / 2, width: glyph, height: glyph)
        RefText.drawGlyph(kind, in: glyphRect, context: context)
        attributedName.draw(with: NSRect(x: textInset, y: (bounds.height - textSize.height) / 2, width: textSize.width + 1, height: textSize.height), options: [.usesLineFragmentOrigin])
    }
}

/// What a confirmation shows below its short title: the names it acts on as full pills on their own lines, then the sentence that says the consequence.
/// It replaces NSAlert's message text, so names are never squeezed into the alert's title or cut in the middle.
final class ConfirmationBody: NSView {
    init(names: RefString, info: RefString, width: CGFloat = Theme.Confirmation.width) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 0
        var x: CGFloat = 0
        var lineHeight: CGFloat = 0
        let gap = Theme.Confirmation.pillGap
        var line: [NSView] = []
        // An accessory this wide gives the alert its left-aligned layout, so the body is left-aligned like the title.
        func endLine() {
            y += lineHeight + gap
            x = 0
            lineHeight = 0
            line = []
        }
        func place(_ view: NSView, size: NSSize) {
            if x > 0, x + size.width > width { endLine() }
            view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            addSubview(view)
            line.append(view)
            x += size.width + gap
            lineHeight = max(lineHeight, size.height)
        }
        for part in names.parts {
            switch part {
            case .name(let name, let kind):
                let pill = RefPillView(name, kind: kind, font: Theme.caption)
                place(pill, size: pill.fit(width: width))
            case .text(let text):
                for (index, piece) in text.components(separatedBy: "\n").enumerated() {
                    if index > 0, !line.isEmpty { endLine() }
                    let trimmed = piece.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let label = NSTextField(labelWithString: trimmed)
                    label.font = Theme.caption
                    label.textColor = Theme.inkMuted
                    place(label, size: label.fittingSize)
                }
            }
        }
        if !line.isEmpty { endLine() }
        if !info.isEmpty {
            if y > 0 { y += Theme.Confirmation.spacing - gap }
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = Theme.caption
            label.setText(info)
            label.preferredMaxLayoutWidth = width
            let height = ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: 0, y: y, width: width, height: height)
            addSubview(label)
            y += height
        } else if y > 0 {
            y -= gap
        }
        frame.size.height = y
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}
