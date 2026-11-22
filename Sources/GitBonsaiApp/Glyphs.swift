import AppKit

/// Monochrome glyphs: SF Symbols for the generic ones, hand-drawn paths on a 24 pt grid for the bonsai family.
enum Glyph: Hashable {
    case check, laptop, cloud, tag, chevronRight, chevronDown, plus, minus, pencil, staged, branch, xmark, trash
    case bonsaiMain, bonsaiLinked, bonsaiLocked, bonsaiDetached, bonsaiPrunable, stashBowl

    /// The hand-drawn paths are designed on this grid (icons/*.svg) with this stroke, then scaled to the box.
    private static let grid: CGFloat = 24
    private static let gridStroke: CGFloat = 1.6
    /// SF Symbols carry their own padding; at this share of the box they match the drawn glyphs in weight.
    private static let symbolScale: CGFloat = 0.78

    private var symbolName: String? {
        switch self {
        case .check: "checkmark"
        case .laptop: "laptopcomputer"
        case .cloud: "cloud"
        case .tag: "tag"
        case .chevronRight: "chevron.right"
        case .chevronDown: "chevron.down"
        case .plus: "plus"
        case .minus: "minus"
        case .xmark: "xmark"
        case .trash: "trash"
        case .pencil: "pencil"
        case .staged: "checkmark.circle"
        case .branch: "arrow.triangle.branch"
        default: nil
        }
    }

    /// Draws the glyph centred in `rect` (flipped coordinates) in a single color.
    @MainActor
    func draw(in rect: CGRect, color: NSColor, context: CGContext) {
        if let symbolName {
            let pointSize = rect.height * Self.symbolScale
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium).applying(.init(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            let size = image.size
            let scale = min(rect.width / size.width, rect.height / size.height, 1)
            let target = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / Self.grid, y: rect.height / Self.grid)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(Self.gridStroke)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        func line(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
            context.beginPath()
            context.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
            if close { context.closePath() }
            context.strokePath()
        }
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
            context.strokeEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }
        switch self {
        case .bonsaiMain:
            line([(5, 17), (19, 17), (17.6, 21), (6.4, 21)], close: true)
            line([(12, 17), (12, 13), (9.2, 10)])
            line([(12, 13), (14.4, 10.9)])
            ellipse(7.5, 8.5, 3, 2.1); ellipse(14.8, 6.2, 3.4, 2.3); ellipse(16.8, 11, 2.6, 1.8)
        case .bonsaiLinked:
            line([(7, 18), (17, 18), (16, 21), (8, 21)], close: true)
            line([(12, 18), (12, 13), (14.3, 9.2)])
            ellipse(15.5, 7.5, 3.2, 2.2)
        case .bonsaiLocked:
            line([(5, 15), (19, 15), (17.7, 20), (6.3, 20)], close: true)
            line([(5.6, 17.5), (18.4, 17.5)])
            line([(12, 15), (12, 12)])
            ellipse(8, 7.6, 2.8, 2); ellipse(14.6, 6.3, 3, 2.1)
        case .bonsaiDetached:
            line([(8, 10), (16, 10), (16, 19), (14, 21), (10, 21), (8, 19)], close: true)
            line([(8, 14.5), (16, 14.5)])
            line([(12, 16), (12, 6.5)])
            ellipse(15.6, 4.6, 2.6, 1.8)
        case .bonsaiPrunable:
            line([(7, 18), (17, 18), (16, 21), (8, 21)], close: true)
            line([(12, 18), (12, 9)])
            line([(12, 12), (10.2, 8.9)])
            line([(12, 10.5), (14.1, 7.8)])
        case .stashBowl:
            line([(4, 9), (20, 9)])
            line([(5, 9), (6.2, 16), (8, 17), (16, 17), (17.8, 16), (19, 9)])
            line([(8, 17), (8, 19)]); line([(16, 17), (16, 19)])
        default:
            break
        }
        context.restoreGState()
    }
}
