import AppKit

/// A history row's ref pills at full length, floating above the rows like a popover. It is a subview of the table, so it shares the rows' coordinates and never moves them.
/// Only the card itself takes clicks; the shadow margin around it lets them through to the rows.
final class RefOverlayView: NSView {
    struct Content {
        let row: Int
        let pills: [PillModel]
        let strand: NSColor
        let isSelected: Bool
        /// The drawn card, in the table's coordinates.
        let card: CGRect
        /// Each pill and the width its name gets, in the table's coordinates.
        let placements: [RefPills.Placement]
        let isWrapped: Bool
    }

    var content: Content? {
        didSet {
            if let content { frame = content.card.insetBy(dx: -Theme.RefOverlay.shadowMargin, dy: -Theme.RefOverlay.shadowMargin) }
            needsDisplay = true
        }
    }
    var onPress: ((NSEvent) -> Void)?
    var makeMenu: (() -> NSMenu?)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let content else { return nil }
        return content.card.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onPress?(event) }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
        typealias O = Theme.RefOverlay
        let origin = frame.origin
        let card = content.card.offsetBy(dx: -origin.x, dy: -origin.y)
        let path = CGPath(roundedRect: card.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), cornerWidth: O.radius, cornerHeight: O.radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -O.shadowOffset), blur: O.shadowBlur, color: O.shadow.cgColor)
        context.setFillColor(Theme.surface0.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        // The same ground as the row underneath: the selection tint, or the hover wash of an unselected row.
        let wash = content.isSelected ? Theme.surfaceSelected : Theme.ink.withAlphaComponent(Theme.Wash.hover)
        context.setFillColor(wash.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(Theme.hairline.cgColor)
        context.setLineWidth(Theme.Stroke.hairline)
        context.addPath(path)
        context.strokePath()
        for placement in content.placements {
            RefPills.draw(content.pills[placement.index], in: placement.rect.offsetBy(dx: -origin.x, dy: -origin.y), textWidth: placement.textWidth, strand: content.strand, context: context)
        }
    }

    /// Lays the pills out at full length. A line that fits stays in place: right-aligned where the row's pills end, in the row's order, growing leftwards and over the graph when the label column is too narrow.
    /// A line wider than `maxWidth` or the visible area wraps into a card that reads left to right, most important label first, anchored to the row and opening downwards, or upwards near the bottom.
    static func layout(_ pills: [PillModel], row: Int, rowRect: CGRect, anchorRight: CGFloat, visible: CGRect, strand: NSColor, isSelected: Bool) -> Content {
        typealias O = Theme.RefOverlay
        typealias P = Theme.Pill
        let widths = pills.map(RefPills.naturalWidth)
        let minX = visible.minX + O.edgeInset
        let maxRight = visible.maxX - O.edgeInset
        let limit = min(O.maxWidth, maxRight - minX)
        let lineWidth = widths.reduce(0, +) + P.spacing * CGFloat(max(pills.count - 1, 0)) + 2 * O.padding
        var placements: [RefPills.Placement] = []

        if lineWidth <= limit {
            var left = min(anchorRight + O.padding, maxRight) - lineWidth
            left = max(left, minX)
            let height = P.height + 2 * O.padding
            let card = CGRect(x: left, y: rowRect.midY - height / 2, width: lineWidth, height: height)
            var right = card.maxX - O.padding
            for (index, pill) in pills.enumerated() {
                let rect = CGRect(x: right - widths[index], y: rowRect.midY - P.height / 2, width: widths[index], height: P.height)
                placements.append(RefPills.Placement(index: index, rect: rect, textWidth: widths[index] - RefPills.chrome(pill), isTruncated: false))
                right = rect.minX - P.spacing
            }
            return Content(row: row, pills: pills, strand: strand, isSelected: isSelected, card: card, placements: placements, isWrapped: false)
        }

        let inner = limit - 2 * O.padding
        var x: CGFloat = 0
        var line = 0
        var slots: [(line: Int, x: CGFloat, width: CGFloat)] = []
        for width in widths {
            let fitted = min(width, inner)
            if x > 0, x + fitted > inner {
                line += 1
                x = 0
            }
            slots.append((line, x, fitted))
            x += fitted + P.spacing
        }
        let lines = CGFloat(line + 1)
        let height = lines * P.height + (lines - 1) * O.lineSpacing + 2 * O.padding
        // As wide as its longest line, so short lines leave no empty band on the right.
        let width = (slots.map { $0.x + $0.width }.max() ?? 0) + 2 * O.padding
        let left = max(min(anchorRight + O.padding, maxRight) - width, minX)
        // The first line sits on the row; near the bottom of the view the card opens upwards with its last line on the row instead.
        var top = rowRect.midY - P.height / 2 - O.padding
        if top + height > visible.maxY - O.edgeInset { top = rowRect.midY + P.height / 2 + O.padding - height }
        top = max(top, visible.minY + O.edgeInset)
        let card = CGRect(x: left, y: top, width: width, height: height)
        for (index, slot) in slots.enumerated() {
            let rect = CGRect(x: card.minX + O.padding + slot.x, y: card.minY + O.padding + CGFloat(slot.line) * (P.height + O.lineSpacing), width: slot.width, height: P.height)
            let textWidth = slot.width - RefPills.chrome(pills[index])
            placements.append(RefPills.Placement(index: index, rect: rect, textWidth: textWidth, isTruncated: slot.width < widths[index]))
        }
        return Content(row: row, pills: pills, strand: strand, isSelected: isSelected, card: card, placements: placements, isWrapped: true)
    }
}
