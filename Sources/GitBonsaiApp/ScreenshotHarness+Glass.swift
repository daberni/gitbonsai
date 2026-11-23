import AppKit
import CoreImage

/// Liquid Glass in rendered captures. `cacheDisplay` cannot draw a glass view, whose backdrop only the window server composites, and leaves the window around it blank.
/// The harness renders the window without its glass views and composites each one over the result: the backdrop blurred and saturated, the view's tint, its content and a hairline rim.
/// It approximates the material for checks of layout and legibility; refraction and the moving highlights only show in a foreground `screencapture`.
@MainActor
extension ScreenshotHarness {
    private static let glassBlur: CGFloat = 12
    private static let glassSaturation: CGFloat = 1.6

    static func renderWithGlass(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let glasses = glassViews(in: view).filter { !$0.isHiddenOrHasHiddenAncestor }
        glasses.forEach { $0.isHidden = true }
        view.cacheDisplay(in: view.bounds, to: rep)
        glasses.forEach { $0.isHidden = false }
        guard !glasses.isEmpty, let backdrop = CIImage(bitmapImageRep: rep), let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for glass in glasses { draw(glass, in: view, over: backdrop, scale: scale) }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func draw(_ glass: NSGlassEffectView, in view: NSView, over backdrop: CIImage, scale: CGFloat) {
        let rect = glass.convert(glass.bounds, to: view)
        let shape = NSBezierPath(roundedRect: rect, xRadius: glass.cornerRadius, yRadius: glass.cornerRadius)
        // Core Image counts pixels from the bottom, like an unflipped view.
        let bottom = view.isFlipped ? view.bounds.height - rect.maxY : rect.minY
        let pixels = CGRect(x: rect.minX * scale, y: bottom * scale, width: rect.width * scale, height: rect.height * scale)
        let frosted = backdrop.clampedToExtent().applyingGaussianBlur(sigma: glassBlur * scale).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: glassSaturation]).cropped(to: pixels)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let image = CIContext().createCGImage(frosted, from: pixels) {
            NSGraphicsContext.current?.cgContext.draw(image, in: rect)
        }
        (glass.tintColor ?? .clear).setFill()
        rect.fill(using: .sourceOver)
        if let content = glass.contentView, let rendered = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rendered)
            rendered.draw(in: content.convert(content.bounds, to: view), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: glass.cornerRadius, yRadius: glass.cornerRadius)
        rim.lineWidth = Theme.Stroke.hairline
        Theme.hairline.setStroke()
        rim.stroke()
    }

    private static func glassViews(in view: NSView) -> [NSGlassEffectView] {
        view.subviews.flatMap { subview -> [NSGlassEffectView] in
            if let glass = subview as? NSGlassEffectView { return [glass] }
            return glassViews(in: subview)
        }
    }
}
