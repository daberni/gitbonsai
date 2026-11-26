import AppKit

extension GraphRowView {
    /// Covers the lanes under the avatar strips, throws their shadows inward over the graph and draws the avatar that reaches a strip above it.
    func drawPinStrips(_ context: CGContext, _ strips: HistoryColumns.AvatarStrips, band: ClosedRange<CGFloat>?, bandColor: NSColor, midY: CGFloat, nodeX: CGFloat, pinnedX: CGFloat?, strand: NSColor, model: Model) {
        drawStrip(context, strips.left, opacity: strips.leftOpacity, shadowToRight: true, band: band, bandColor: bandColor, model: model)
        drawStrip(context, strips.right, opacity: strips.rightOpacity, shadowToRight: false, band: band, bandColor: bandColor, model: model)
        guard let pinnedX else { return }
        beginDimming(context, model)
        context.saveGState()
        context.setAlpha(HistoryColumns.pinnedAvatarAlpha(nodeX: nodeX, pinnedX: pinnedX))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawNode(context, at: CGPoint(x: pinnedX, y: midY), strand: strand, model: model)
        context.endTransparencyLayer()
        context.restoreGState()
        endDimming(context, model)
    }

    private func drawStrip(_ context: CGContext, _ strip: ClosedRange<CGFloat>, opacity: CGFloat, shadowToRight: Bool, band: ClosedRange<CGFloat>?, bandColor: NSColor, model: Model) {
        guard opacity > 0 else { return }
        let G = Theme.Graph.self
        let height = bounds.height
        let rect = CGRect(x: strip.lowerBound, y: 0, width: strip.upperBound - strip.lowerBound, height: height)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        // The selection colour is translucent, so the strip lays it over an opaque surface to hide the lanes beneath.
        context.setFillColor(Theme.surface0.cgColor)
        context.fill(rect)
        if model.isSelected {
            context.setFillColor(Theme.surfaceSelected.cgColor)
            context.fill(rect)
        }
        if let band, band.overlaps(strip) {
            // The row's band runs on under the strip, so the strip reads as a layer over the graph only.
            let start = max(band.lowerBound, strip.lowerBound)
            let end = min(band.upperBound, strip.upperBound)
            context.setFillColor(bandColor.withAlphaComponent(model.isHead ? G.headBandAlpha : G.bandAlpha).cgColor)
            context.fill(CGRect(x: start, y: G.bandInset, width: end - start, height: height - 2 * G.bandInset))
        }
        let colors = [G.pinShadow.withAlphaComponent(0).cgColor, G.pinShadow.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) else { return }
        let edge = shadowToRight ? rect.maxX : rect.minX
        let outer = shadowToRight ? edge + G.pinShadowWidth : edge - G.pinShadowWidth
        context.drawLinearGradient(gradient, start: CGPoint(x: outer, y: 0), end: CGPoint(x: edge, y: 0), options: [])
    }
}
