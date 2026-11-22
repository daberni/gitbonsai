import AppKit

/// How a history row shows the commit search: rows that do not match fade except for their strands, and matched text gets a highlight.
extension GraphRowView {
    /// The parts of a search match to mark: ranges in the subject and the author name, and how many characters of the short SHA.
    struct Highlights {
        var subject: [NSRange] = []
        var author: [NSRange] = []
        var shaPrefix = 0
    }

    /// Everything drawn until `endDimming` is composited as one layer, so overlapping parts such as a pill over its connector fade together.
    func beginDimming(_ context: CGContext, _ model: Model) {
        guard model.isSearchMiss else { return }
        context.saveGState()
        context.setAlpha(Theme.Focus.dimmedAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
    }

    func endDimming(_ context: CGContext, _ model: Model) {
        guard model.isSearchMiss else { return }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A faded node would let the strands through that its opaque disc normally covers, so the ground under it is restored first.
    func eraseStrands(_ context: CGContext, under center: CGPoint, model: Model) {
        let extent = Self.nodeExtent(model.kind)
        let rect = CGRect(x: center.x - extent, y: center.y - extent, width: extent * 2, height: extent * 2)
        let shape = model.kind == .stash ? CGPath(roundedRect: rect, cornerWidth: Theme.Graph.stashRadius, cornerHeight: Theme.Graph.stashRadius, transform: nil) : CGPath(ellipseIn: rect, transform: nil)
        for ground in model.isSelected ? [Theme.surface0, Theme.surfaceSelected] : [Theme.surface0] {
            context.setFillColor(ground.cgColor)
            context.addPath(shape)
            context.fillPath()
        }
    }

    /// Matched text keeps its font and gets the highlight ground with full ink, so it reads on dimmed and muted cells alike.
    static func highlighted(_ string: String, ranges: [NSRange], attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: string, attributes: attributes)
        for range in ranges where NSMaxRange(range) <= text.length {
            text.addAttributes([.backgroundColor: Theme.Search.highlight, .foregroundColor: Theme.ink], range: range)
        }
        return text
    }
}
