import AppKit

/// A name as a pill that keeps its full length: a name wider than the line wraps inside the pill instead of being cut. The tooltip carries the full name.
/// It measures like the inline pills of `RefText`, from the font of the text around it.
final class RefPillView: NSView {
    private let name: String
    private let kind: RefKind
    private let metrics: RefText.PillMetrics
    private var textSize = NSSize.zero

    init(_ name: String, kind: RefKind, font: NSFont) {
        self.name = name
        self.kind = kind
        metrics = RefText.PillMetrics(kind, like: font)
        super.init(frame: .zero)
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The baseline of the pill's first text line, from its top.
    var baseline: CGFloat { metrics.textTop + metrics.textFont.ascender }

    private var attributedName: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: name, attributes: [.font: metrics.textFont, .foregroundColor: Theme.ink, .paragraphStyle: paragraph])
    }

    /// The pill's size when it may be at most `width` wide.
    func fit(width: CGFloat) -> NSSize {
        let available = max(width - metrics.textInset - metrics.trailingPadding, metrics.glyph)
        let bounds = attributedName.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        textSize = NSSize(width: ceil(bounds.width), height: max(ceil(bounds.height), metrics.lineHeight))
        return NSSize(width: metrics.textInset + textSize.width + metrics.trailingPadding, height: textSize.height + metrics.height - metrics.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let single = metrics.height
        RefText.color(kind).mixed(into: Theme.surface0, fraction: Theme.Pill.tint.plain).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: single / 2, yRadius: single / 2).fill()
        let glyphRect = CGRect(x: metrics.padding, y: (single - metrics.glyph) / 2, width: metrics.glyph, height: metrics.glyph)
        RefText.drawGlyph(kind, in: glyphRect, context: context)
        attributedName.draw(with: NSRect(x: metrics.textInset, y: metrics.textTop, width: textSize.width + 1, height: textSize.height), options: [.usesLineFragmentOrigin])
    }
}

/// What a confirmation shows below its short title: the names it acts on as full pills, then the sentence that says the consequence.
/// It replaces NSAlert's message text, so names are never squeezed into the alert's title or cut in the middle.
/// Text next to a pill, such as a commit subject or a stash message, stays on the pill's line, on its baseline, cut at the end with the full text as tooltip.
final class ConfirmationBody: NSView {
    private struct Item {
        let view: NSView
        let size: NSSize
        let baseline: CGFloat
    }

    init(names: RefString, info: RefString, width: CGFloat = Theme.Confirmation.width) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        let font = Theme.caption
        let gap = Theme.Confirmation.pillGap
        var y: CGFloat = 0
        var x: CGFloat = 0
        var line: [Item] = []
        // An accessory this wide gives the alert its left-aligned layout, so the body is left-aligned like the title.
        func endLine() {
            guard !line.isEmpty else { return }
            let baseline = line.map(\.baseline).max() ?? 0
            var bottom: CGFloat = 0
            var left: CGFloat = 0
            for item in line {
                let top = y + baseline - item.baseline
                item.view.frame = NSRect(x: left, y: top, width: item.size.width, height: item.size.height)
                addSubview(item.view)
                left += item.size.width + gap
                bottom = max(bottom, top + item.size.height)
            }
            y = bottom + gap
            x = 0
            line = []
        }
        func place(_ view: NSView, size: NSSize, baseline: CGFloat) {
            if x > 0, x + size.width > width { endLine() }
            line.append(Item(view: view, size: size, baseline: baseline))
            x += size.width + gap
        }
        for part in names.parts {
            switch part {
            case .name(let name, let kind):
                let pill = RefPillView(name, kind: kind, font: font)
                place(pill, size: pill.fit(width: width), baseline: pill.baseline)
            case .text(let text):
                for (index, piece) in text.components(separatedBy: "\n").enumerated() {
                    if index > 0 { endLine() }
                    let trimmed = piece.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let label = NSTextField(labelWithString: trimmed)
                    label.font = font
                    label.textColor = Theme.inkMuted
                    label.lineBreakMode = .byTruncatingTail
                    label.maximumNumberOfLines = 1
                    label.cell?.truncatesLastVisibleLine = true
                    let fitting = label.fittingSize
                    let room = width - x
                    if fitting.width > room { label.toolTip = trimmed }
                    line.append(Item(view: label, size: NSSize(width: min(fitting.width, max(room, 0)), height: fitting.height), baseline: label.firstBaselineOffsetFromTop))
                    x += min(fitting.width, room) + gap
                }
            }
        }
        endLine()
        if !info.isEmpty {
            if y > 0 { y += Theme.Confirmation.spacing - gap }
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = font
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
