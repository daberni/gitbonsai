import AppKit
import GitEngine
import GraphLayout

struct PillModel: Hashable {
    let name: String
    let glyphs: [Glyph]
    let isHead: Bool
}

/// Draws one history row: ref labels, strands and node, commit text, author and date.
///
/// Strands are drawn per transition between two rows. Each cell draws its own row's edges down to the next row and the previous row's edges down to itself; both are clipped to the cell, so a lane change is one continuous S across the boundary.
final class GraphRowView: NSView {
    struct Model {
        var commit: Commit
        var row: GraphRow
        var previous: GraphRow?
        var next: GraphRow?
        var kind: GraphViewModel.RowKind
        var previousKind: GraphViewModel.RowKind?
        /// Lane of the strand between the working directory row and HEAD where it enters and where it leaves this row.
        var wipLaneAbove: Lane?
        var wipLaneBelow: Lane?
        var pills: [PillModel]
        var isHead: Bool
        var dimmed: Bool
        var isSelected: Bool
        var subject: String
        var wipCounts: (changed: Int, staged: Int, untracked: Int)?
        /// A search is active and this row does not match: everything but the strands is drawn at `Theme.Focus.dimmedAlpha`.
        var isSearchMiss = false
        var highlights = Highlights()
        var columns: HistoryColumns
    }

    static let shortSHALength = 7

    var model: Model? { didSet { needsDisplay = true } }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()
    static let exactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EEE, d. MMM yyyy, HH:mm"
        return formatter
    }()

    override var isFlipped: Bool { true }

    private typealias G = Theme.Graph
    /// Left edge of the graph column in the row being drawn.
    private var graphOrigin: CGFloat = 0

    private func laneX(_ lane: Int) -> CGFloat {
        graphOrigin + G.firstLane + CGFloat(lane) * G.lane - (model?.columns.graphScrollX ?? 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let height = bounds.height
        let midY = height / 2
        let strand = Theme.strand(model.row.color)
        let layout = model.columns.layout(in: bounds.width)
        let textX = layout.commit.lowerBound + Theme.Cell.subjectLeading

        if model.isSelected {
            Theme.surfaceSelected.setFill()
            bounds.fill()
        }
        defer {
            beginDimming(context, model)
            drawText(context, model: model, layout: layout, textX: textX, midY: midY)
            endDimming(context, model)
        }
        guard let graphRange = layout.graph else {
            if let label = layout.label {
                beginDimming(context, model)
                _ = drawPills(context, model: model, strand: strand, midY: midY, labelEnd: label.upperBound)
                endDimming(context, model)
            }
            return
        }
        graphOrigin = graphRange.lowerBound
        let graphRect = CGRect(x: graphRange.lowerBound, y: 0, width: graphRange.upperBound - graphRange.lowerBound, height: height)
        let nodeX = laneX(model.row.lane)
        // The strand bar closes the graph column on the right; the band runs from the node to it, with a gap above and below so rows stay separate.
        let barX = graphRect.maxX - G.barInset
        let bandColor: NSColor = model.kind == .wip ? Theme.inkMuted : strand
        beginDimming(context, model)
        if nodeX < barX {
            context.setFillColor(bandColor.withAlphaComponent(model.isHead ? G.headBandAlpha : G.bandAlpha).cgColor)
            // A node scrolled out to the left still leaves its band, starting at the column edge.
            let bandStart = max(nodeX, graphRect.minX)
            context.fill(CGRect(x: bandStart, y: G.bandInset, width: barX - bandStart, height: height - 2 * G.bandInset))
        }
        context.setFillColor(bandColor.cgColor)
        context.fill(CGRect(x: barX, y: G.bandInset, width: Theme.Stroke.strand, height: height - 2 * G.bandInset))
        endDimming(context, model)

        context.saveGState()
        context.clip(to: graphRect)
        context.setLineWidth(G.strandWidth)
        context.setLineCap(.round)
        if let previous = model.previous {
            for edge in previous.edges where edge.kind != .fromChild {
                let target = Self.targetLane(of: edge, nextRow: model.row)
                let isWipStrand = edge.fromLane == model.wipLaneAbove
                let dashed = isWipStrand || (Self.isParked(model.previousKind) && edge.fromLane == previous.lane)
                stroke(context, from: laneX(edge.fromLane), to: laneX(target), startY: midY - height, color: isWipStrand ? Theme.inkMuted : Self.color(of: edge, kind: model.previousKind, row: previous), dashed: dashed)
            }
        }
        for edge in model.row.edges where edge.kind != .fromChild {
            let target = Self.targetLane(of: edge, nextRow: model.next)
            let isWipStrand = edge.fromLane == model.wipLaneBelow
            let dashed = isWipStrand || (Self.isParked(model.kind) && edge.fromLane == model.row.lane)
            stroke(context, from: laneX(edge.fromLane), to: laneX(target), startY: midY, color: isWipStrand ? Theme.inkMuted : Self.color(of: edge, kind: model.kind, row: model.row), dashed: dashed)
        }
        let nodeCenter = CGPoint(x: nodeX, y: midY)
        if model.isSearchMiss { eraseStrands(context, under: nodeCenter, model: model) }
        beginDimming(context, model)
        drawNode(context, at: nodeCenter, strand: strand, model: model)
        endDimming(context, model)
        context.restoreGState()

        beginDimming(context, model)
        defer { endDimming(context, model) }
        let nodeEdge = nodeX - Self.nodeExtent(model.kind)
        let pillsEnd = layout.label.flatMap { drawPills(context, model: model, strand: strand, midY: midY, labelEnd: $0.upperBound) }
        if let pillsEnd, nodeEdge > pillsEnd {
            context.setStrokeColor(strand.cgColor)
            context.setLineWidth(Theme.Stroke.hairline)
            context.setLineDash(phase: 0, lengths: [])
            context.beginPath()
            context.move(to: CGPoint(x: pillsEnd, y: midY))
            context.addLine(to: CGPoint(x: min(nodeEdge, barX), y: midY))
            context.strokePath()
        }
    }

    // MARK: Strands

    private static func isParked(_ kind: GraphViewModel.RowKind?) -> Bool {
        kind == .stash || kind == .wip
    }

    private static func color(of edge: GraphEdge, kind: GraphViewModel.RowKind?, row: GraphRow) -> NSColor {
        kind == .wip && edge.fromLane == row.lane ? Theme.inkMuted : Theme.strand(edge.color)
    }

    static func nodeExtent(_ kind: GraphViewModel.RowKind) -> CGFloat {
        switch kind {
        case .commit: G.nodeRadius
        case .merge: G.mergeRadius
        case .stash: G.stashHalf
        case .wip: G.wipRadius
        }
    }

    /// A strand that the next row collapses into its node (`fromChild`) bends toward that node, so both halves of the curve agree on one end point.
    private static func targetLane(of edge: GraphEdge, nextRow: GraphRow?) -> Int {
        guard let nextRow, nextRow.edges.contains(where: { $0.kind == .fromChild && $0.fromLane == edge.toLane }) else { return edge.toLane }
        return nextRow.lane
    }

    /// One transition from a row centre at `startY` to the next row centre: straight on the lane, an S inside the elbow window around the row boundary, straight again.
    private func stroke(_ context: CGContext, from x0: CGFloat, to x1: CGFloat, startY: CGFloat, color: NSColor, dashed: Bool) {
        let height = bounds.height
        let boundary = startY + height / 2
        context.setStrokeColor(color.cgColor)
        context.setLineDash(phase: 0, lengths: dashed ? Theme.Stroke.dash : [])
        context.beginPath()
        context.move(to: CGPoint(x: x0, y: startY))
        if x0 == x1 {
            context.addLine(to: CGPoint(x: x1, y: startY + height))
        } else {
            let half = G.elbow / 2
            context.addLine(to: CGPoint(x: x0, y: boundary - half))
            context.addCurve(to: CGPoint(x: x1, y: boundary + half), control1: CGPoint(x: x0, y: boundary), control2: CGPoint(x: x1, y: boundary))
            context.addLine(to: CGPoint(x: x1, y: startY + height))
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }

    // MARK: Node

    private func drawNode(_ context: CGContext, at center: CGPoint, strand: NSColor, model: Model) {
        switch model.kind {
        case .commit:
            let rect = CGRect(x: center.x - G.nodeRadius, y: center.y - G.nodeRadius, width: G.nodeRadius * 2, height: G.nodeRadius * 2)
            // Opaque disc: strands end at the ring, none runs through the avatar.
            context.setFillColor(Theme.surface1.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(strand.cgColor)
            context.setLineWidth(G.strandWidth)
            context.strokeEllipse(in: rect.insetBy(dx: G.strandWidth / 2, dy: G.strandWidth / 2))
            let initials = Self.initials(model.commit.authorName)
            let text = NSAttributedString(string: initials, attributes: [.font: Theme.initialsSmall, .foregroundColor: Theme.inkMuted])
            let size = text.size()
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        case .merge:
            context.setFillColor(strand.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - G.mergeRadius, y: center.y - G.mergeRadius, width: G.mergeRadius * 2, height: G.mergeRadius * 2))
        case .stash:
            let rect = CGRect(x: center.x - G.stashHalf, y: center.y - G.stashHalf, width: G.stashHalf * 2, height: G.stashHalf * 2)
            let path = CGPath(roundedRect: rect, cornerWidth: G.stashRadius, cornerHeight: G.stashRadius, transform: nil)
            context.setFillColor(Theme.surface0.cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(strand.cgColor)
            context.setLineWidth(Theme.Stroke.icon)
            context.setLineDash(phase: 0, lengths: Theme.Stroke.nodeDash)
            context.addPath(path)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        case .wip:
            let rect = CGRect(x: center.x - G.wipRadius, y: center.y - G.wipRadius, width: G.wipRadius * 2, height: G.wipRadius * 2)
            context.setFillColor(Theme.surface0.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(Theme.inkMuted.cgColor)
            context.setLineWidth(G.strandWidth)
            context.setLineDash(phase: 0, lengths: Theme.Stroke.nodeDash)
            context.strokeEllipse(in: rect)
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    // MARK: Labels

    /// Draws the pills right-aligned in the label column and returns the right edge of the last pill, where the connector starts.
    private func drawPills(_ context: CGContext, model: Model, strand: NSColor, midY: CGFloat, labelEnd: CGFloat) -> CGFloat? {
        guard !model.pills.isEmpty else { return nil }
        typealias P = Theme.Pill
        let rightEdge = labelEnd - P.trailing
        let pillHeight = P.height
        let glyphSize = P.glyph
        var right = rightEdge
        var drawn = 0
        for pill in model.pills {
            let font = pill.isHead ? Theme.pillStrong : Theme.pill
            let remaining = model.pills.count - drawn
            let reserve = remaining > 1 ? P.counterReserve : 0
            let available = right - P.padding - reserve
            let glyphsWidth = CGFloat(pill.glyphs.count) * (glyphSize + P.glyphGap)
            let chrome = P.padding + glyphsWidth + P.textGap + P.trailingPadding
            guard available - chrome > P.minimumText else { break }
            let title = NSAttributedString(string: pill.name, attributes: [.font: font, .foregroundColor: Theme.ink])
            let textWidth = min(title.size().width, available - chrome)
            let rect = CGRect(x: right - chrome - textWidth, y: midY - pillHeight / 2, width: chrome + textWidth, height: pillHeight)
            let edge = Theme.Stroke.hairline / 2
            let path = CGPath(roundedRect: rect.insetBy(dx: edge, dy: edge), cornerWidth: pillHeight / 2 - edge, cornerHeight: pillHeight / 2 - edge, transform: nil)
            // The ground is opaque (strand mixed into the surface) so the connector never shows through.
            context.setFillColor(strand.mixed(into: Theme.surface0, fraction: pill.isHead ? P.tint.head : P.tint.plain).cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(strand.withAlphaComponent(pill.isHead ? P.border.head : P.border.plain).cgColor)
            context.setLineWidth(Theme.Stroke.hairline)
            context.addPath(path)
            context.strokePath()
            var x = rect.minX + P.padding
            for glyph in pill.glyphs {
                glyph.draw(in: CGRect(x: x, y: midY - glyphSize / 2, width: glyphSize, height: glyphSize), color: Theme.ink, context: context)
                x += glyphSize + P.glyphGap
            }
            let textRect = CGRect(x: x + P.textGap, y: midY - title.size().height / 2, width: textWidth, height: title.size().height)
            title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            right = rect.minX - P.spacing
            drawn += 1
        }
        if drawn < model.pills.count {
            let more = NSAttributedString(string: "+\(model.pills.count - drawn)", attributes: [.font: Theme.pill, .foregroundColor: Theme.inkMuted])
            more.draw(at: CGPoint(x: right - more.size().width, y: midY - more.size().height / 2))
        }
        return drawn > 0 ? rightEdge : nil
    }

    // MARK: Text

    private func drawText(_ context: CGContext, model: Model, layout: HistoryColumns.Layout, textX: CGFloat, midY: CGFloat) {
        let subjectWidth = max(layout.commit.upperBound - textX - Theme.Cell.leading, Theme.Cell.minimumSubject)

        if let counts = model.wipCounts {
            var x = textX
            let items: [(Glyph, Int, String)] = [(.pencil, counts.changed, "geändert"), (.staged, counts.staged, "staged"), (.plus, counts.untracked, "untracked")]
            for (glyph, count, _) in items where count > 0 {
                glyph.draw(in: CGRect(x: x, y: midY - Theme.Icon.small / 2, width: Theme.Icon.small, height: Theme.Icon.small), color: Theme.inkMuted, context: context)
                let text = NSAttributedString(string: "\(count)", attributes: [.font: Theme.bodyDigits, .foregroundColor: Theme.ink])
                let numberX = x + Theme.Icon.small + G.counterGap
                text.draw(at: CGPoint(x: numberX, y: midY - text.size().height / 2))
                x = numberX + text.size().width + G.counterSpacing
            }
            return
        }

        let color = model.dimmed ? Theme.inkFaint : Theme.ink
        var font = model.isHead ? Theme.bodyStrong : Theme.body
        if model.kind == .stash { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let subject = Self.highlighted(model.subject, ranges: model.highlights.subject, attributes: [.font: font, .foregroundColor: color])
        let subjectHeight = subject.size().height
        subject.draw(with: CGRect(x: textX, y: midY - subjectHeight / 2, width: subjectWidth, height: subjectHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let muted: [NSAttributedString.Key: Any] = [.font: Theme.caption, .foregroundColor: Theme.inkMuted]
        func cell(_ string: String, in range: ClosedRange<CGFloat>?, attributes: [NSAttributedString.Key: Any], highlights: [NSRange] = [], rightAligned: Bool = false) {
            guard let range else { return }
            let text = Self.highlighted(string, ranges: highlights, attributes: attributes)
            let width = range.upperBound - range.lowerBound - Theme.Cell.leading - Theme.Cell.trailing
            guard width > Theme.Cell.minimumText else { return }
            let x = rightAligned ? max(range.upperBound - Theme.Cell.trailing - text.size().width, range.lowerBound + Theme.Cell.leading) : range.lowerBound + Theme.Cell.leading
            text.draw(with: CGRect(x: x, y: midY - text.size().height / 2, width: width, height: text.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        cell(model.commit.authorName, in: layout.author, attributes: muted, highlights: model.highlights.author)
        let shaHighlight = model.highlights.shaPrefix > 0 ? [NSRange(location: 0, length: model.highlights.shaPrefix)] : []
        cell(String(model.commit.id.prefix(Self.shortSHALength)), in: layout.sha, attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.inkMuted], highlights: shaHighlight)
        cell(Self.relativeFormatter.localizedString(for: model.commit.authorDate, relativeTo: Date()), in: layout.date, attributes: muted, rightAligned: true)
    }
}
