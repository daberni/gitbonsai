import AppKit
import Avatars

/// The stand-in for an author without avatar, derived from the address so it looks the same in every repository and the detail panel.
enum AvatarFallbackStyle: String, CaseIterable {
    /// Muted initials on the node's background.
    case initials
    /// Initials in a palette colour picked by the address hash, on a wash of the same colour.
    case tintedInitials
    /// A mirrored 5×5 pattern in a palette colour picked by the address hash.
    case pattern
}

@MainActor
enum AvatarFallbackDrawing {
    static var style: AvatarFallbackStyle {
        ScreenshotHarness.avatarFallbackStyle ?? Theme.Avatar.fallback
    }

    /// Draws inside the ring whose outer bounds are `rect`, where a picture would go; the caller draws background and ring.
    static func draw(email: String, initials: String, font: NSFont, in rect: CGRect, ring: CGFloat, context: CGContext) {
        let inner = rect.insetBy(dx: ring + Theme.Avatar.ringGap, dy: ring + Theme.Avatar.ringGap)
        let seed = AvatarFallback(email: email, palette: Theme.strandCount)
        let tint = Theme.strand(seed.tint)
        switch style {
        case .initials:
            drawText(initials, font: font, color: Theme.inkMuted, center: CGPoint(x: rect.midX, y: rect.midY))
        case .tintedInitials:
            context.setFillColor(tint.withAlphaComponent(Theme.Avatar.tintAlpha).cgColor)
            context.fillEllipse(in: inner)
            drawText(initials, font: font, color: tint, center: CGPoint(x: rect.midX, y: rect.midY))
        case .pattern:
            let side = inner.width * Theme.Avatar.patternSpan
            let cell = side / CGFloat(AvatarFallback.side)
            let origin = CGPoint(x: inner.midX - side / 2, y: inner.midY - side / 2)
            context.setFillColor(tint.cgColor)
            for (index, on) in seed.cells.enumerated() where on {
                let row = index / AvatarFallback.side
                let column = index % AvatarFallback.side
                context.fill(CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row) * cell, width: cell, height: cell))
            }
        }
    }

    private static func drawText(_ string: String, font: NSFont, color: NSColor, center: CGPoint) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
