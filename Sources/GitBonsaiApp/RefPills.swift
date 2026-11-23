import AppKit

struct PillModel: Hashable {
    let name: String
    let glyphs: [Glyph]
    let isHead: Bool
    let ref: PillRef
}

/// What a pill stands for, so a click on it can act on that ref: a branch pill joins the local branch and its same-named remote branches.
enum PillRef: Hashable {
    case branch(String)
    case tag(String)
    case detachedHead
    case other(String)
}

/// Where the ref pills of one history row go and how one pill looks; shared by the row and its expansion.
@MainActor
enum RefPills {
    private typealias P = Theme.Pill

    struct Placement {
        let index: Int
        let rect: CGRect
        let textWidth: CGFloat
        let isTruncated: Bool
    }

    /// The pills that fit into the label column, right-aligned toward the graph, with a "+n" counter for the rest.
    struct CompactLayout {
        var placements: [Placement] = []
        var counter: (text: NSAttributedString, rect: CGRect)?
        /// Right edge of the pills, where the connector to the node starts; nil when none fits.
        var end: CGFloat?

        /// Something of the row's refs is not readable here: a label left out or a name cut short.
        var hidesSomething: Bool { counter != nil || placements.contains(where: \.isTruncated) }
    }

    /// What lies under `point` in a row's pills: the rounded shape of a pill, cut short or not, or the "+n" counter with a little slack around it.
    enum Hit: Equatable {
        case pill(Int)
        case counter
    }

    static func hit(_ layout: CompactLayout, at point: CGPoint) -> Hit? {
        if let placement = hit(layout.placements, at: point) { return .pill(placement.index) }
        if let counter = layout.counter {
            let inset = Theme.RefOverlay.counterHitInset
            if counter.rect.insetBy(dx: -inset, dy: -inset).contains(point) { return .counter }
        }
        return nil
    }

    static func hit(_ placements: [Placement], at point: CGPoint) -> Placement? {
        placements.first { shape(of: $0.rect).contains(point) }
    }

    /// The capsule a pill fills, inset by half its border.
    static func shape(of rect: CGRect) -> CGPath {
        let edge = P.stroke / 2
        return CGPath(roundedRect: rect.insetBy(dx: edge, dy: edge), cornerWidth: P.height / 2 - edge, cornerHeight: P.height / 2 - edge, transform: nil)
    }

    static func title(_ pill: PillModel) -> NSAttributedString {
        NSAttributedString(string: pill.name, attributes: [.font: pill.isHead ? P.fontStrong : P.font, .foregroundColor: Theme.ink])
    }

    /// Width of everything but the name: padding, glyphs and the gap before the text.
    static func chrome(_ pill: PillModel) -> CGFloat {
        P.padding + CGFloat(pill.glyphs.count) * (P.glyph + P.glyphGap) + P.textGap + P.trailingPadding
    }

    /// Width of the pill with its whole name.
    static func naturalWidth(_ pill: PillModel) -> CGFloat {
        chrome(pill) + ceil(title(pill).size().width)
    }

    /// Measures only the pills that are drawn, so a row with many refs costs no more than one with a few.
    static func compactLayout(_ pills: [PillModel], labelEnd: CGFloat, midY: CGFloat) -> CompactLayout {
        var layout = CompactLayout()
        guard !pills.isEmpty else { return layout }
        let rightEdge = labelEnd - P.trailing
        var right = rightEdge
        for (index, pill) in pills.enumerated() {
            let remaining = pills.count - index
            let reserve = remaining > 1 ? P.counterReserve : 0
            let available = right - P.padding - reserve
            let chrome = chrome(pill)
            guard available - chrome > P.minimumText else { break }
            let fullWidth = title(pill).size().width
            let textWidth = min(fullWidth, available - chrome)
            let rect = CGRect(x: right - chrome - textWidth, y: midY - P.height / 2, width: chrome + textWidth, height: P.height)
            layout.placements.append(Placement(index: index, rect: rect, textWidth: textWidth, isTruncated: textWidth < fullWidth))
            right = rect.minX - P.spacing
        }
        if layout.placements.count < pills.count {
            let text = NSAttributedString(string: "+\(pills.count - layout.placements.count)", attributes: [.font: P.font, .foregroundColor: Theme.inkMuted])
            let size = text.size()
            layout.counter = (text, CGRect(x: right - size.width, y: midY - size.height / 2, width: size.width, height: size.height))
        }
        layout.end = layout.placements.isEmpty ? nil : rightEdge
        return layout
    }

    /// Draws one pill into `rect` (flipped coordinates); the name gets `textWidth` and is cut with "…" beyond it. `title` replaces the plain name, such as with search hits highlighted.
    static func draw(_ pill: PillModel, in rect: CGRect, textWidth: CGFloat, strand: NSColor, context: CGContext, title: NSAttributedString? = nil) {
        let midY = rect.midY
        let path = shape(of: rect)
        // The ground is opaque (strand mixed into the surface) so the connector never shows through.
        context.setFillColor(strand.mixed(into: Theme.surface0, fraction: pill.isHead ? P.tint.head : P.tint.plain).cgColor)
        context.addPath(path)
        context.fillPath()
        if P.stroke > 0 {
            context.setStrokeColor(strand.withAlphaComponent(pill.isHead ? P.border.head : P.border.plain).cgColor)
            context.setLineWidth(P.stroke)
            context.addPath(path)
            context.strokePath()
        }
        var x = rect.minX + P.padding
        for glyph in pill.glyphs {
            glyph.draw(in: CGRect(x: x, y: midY - P.glyph / 2, width: P.glyph, height: P.glyph), color: Theme.ink, context: context)
            x += P.glyph + P.glyphGap
        }
        let title = title ?? Self.title(pill)
        let textRect = CGRect(x: x + P.textGap, y: midY - title.size().height / 2, width: textWidth, height: title.size().height)
        title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
