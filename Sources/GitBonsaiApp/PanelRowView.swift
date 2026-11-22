import AppKit

/// Selection as the sidebar shows it: a rounded moss wash instead of the system accent.
final class PanelSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.surfaceSelected.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.Panel.selectionInset, dy: Theme.Panel.selectionInset), xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
    }

    override var isSelected: Bool { didSet { needsDisplay = true } }
}

/// One entry, drawn: glyph, title with marker and age on the first line, detail and short SHA on the second.
final class PanelRowView: NSView {
    private typealias P = Theme.Panel
    static let identifier = NSUserInterfaceItemIdentifier("PanelRowView")

    var row: PanelRow? { didSet { needsDisplay = true } }
    var onPress: ((_ clickCount: Int) -> Void)?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?(event.clickCount)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let context = NSGraphicsContext.current?.cgContext else { return }
        if row.isHighlighted {
            Theme.clay.withAlphaComponent(Theme.Wash.pressed).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: P.selectionInset, dy: P.selectionInset), xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
        }
        let left = P.rowPadding
        let right = bounds.width - P.rowPadding
        let firstLine = bounds.height * P.firstLine
        let secondLine = bounds.height * P.secondLine
        row.glyph.draw(in: CGRect(x: left, y: firstLine - Theme.Icon.regular / 2, width: Theme.Icon.regular, height: Theme.Icon.regular), color: row.isDimmed ? Theme.inkFaint : Theme.inkMuted, context: context)
        let textLeft = left + Theme.Icon.regular + Theme.Space.s

        let age = row.date.map { Self.relativeFormatter.localizedString(for: $0, relativeTo: Date()) } ?? ""
        let ageWidth = draw(age, font: Theme.captionDigits, color: Theme.inkMuted, rightEdge: right, midY: firstLine)
        let shaWidth = draw(row.sha, font: Theme.monoSmall, color: Theme.inkFaint, rightEdge: right, midY: secondLine)

        var titleRight = right - ageWidth - (ageWidth > 0 ? Theme.Space.s : 0)
        titleRight = drawBadges(row.badges, rightEdge: titleRight, midY: firstLine, context: context)
        if let marker = row.marker {
            let markerAttributes: [NSAttributedString.Key: Any] = [.font: Theme.caption, .foregroundColor: Theme.inkMuted]
            let titleWidth = (row.title as NSString).size(withAttributes: [.font: Theme.bodyMedium]).width
            let markerWidth = (marker as NSString).size(withAttributes: markerAttributes).width
            let markerX = min(textLeft + titleWidth + Theme.Space.xs, titleRight - markerWidth)
            (marker as NSString).draw(at: CGPoint(x: markerX, y: firstLine - Theme.caption.lineHeight / 2), withAttributes: markerAttributes)
            titleRight = markerX - Theme.Space.xs
        }
        drawTruncated(row.title, font: Theme.bodyMedium, color: row.isDimmed ? Theme.inkMuted : Theme.ink, x: textLeft, maxX: titleRight, midY: firstLine)
        drawTruncated(row.detail, font: Theme.caption, color: Theme.inkMuted, x: textLeft, maxX: right - shaWidth - Theme.Space.s, midY: secondLine)
    }

    /// Right-aligned in their order, returns where the space left of them ends.
    private func drawBadges(_ badges: [PanelBadge], rightEdge: CGFloat, midY: CGFloat, context: CGContext) -> CGFloat {
        var x = rightEdge
        for badge in badges.reversed() {
            let color: NSColor = switch badge.tone {
            case .muted: Theme.inkMuted
            case .faint: Theme.inkFaint
            case .alert: Theme.clay
            }
            if let label = badge.label {
                x -= draw(label, font: Theme.caption, color: color, rightEdge: x, midY: midY) + Theme.Space.xs / 2
            }
            x -= Theme.Icon.small
            badge.glyph.draw(in: CGRect(x: x, y: midY - Theme.Icon.small / 2, width: Theme.Icon.small, height: Theme.Icon.small), color: color, context: context)
            x -= Theme.Space.s
        }
        return x
    }

    /// Right-aligned, returns its width.
    private func draw(_ text: String, font: NSFont, color: NSColor, rightEdge: CGFloat, midY: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: CGPoint(x: rightEdge - width, y: midY - font.lineHeight / 2), withAttributes: attributes)
        return width
    }

    private func drawTruncated(_ text: String, font: NSFont, color: NSColor, x: CGFloat, maxX: CGFloat, midY: CGFloat) {
        guard maxX > x else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        (text as NSString).draw(in: CGRect(x: x, y: midY - font.lineHeight / 2, width: maxX - x, height: font.lineHeight), withAttributes: attributes)
    }
}

private extension NSFont {
    var lineHeight: CGFloat { ceil(ascender - descender + leading) }
}
