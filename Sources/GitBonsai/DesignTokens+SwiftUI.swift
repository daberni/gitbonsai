import AppKit
import SwiftUI

/// The design tokens for SwiftUI views. Colours wrap the dynamic `NSColor`s, so they resolve per appearance exactly like their AppKit originals; fonts are the same faces.
/// Spacing, radii and component sizes are plain `CGFloat`s in `Theme` and are used as they are.
extension ShapeStyle where Self == Color {
    @MainActor static var ink: Color { Color(nsColor: Theme.ink) }
    @MainActor static var inkMuted: Color { Color(nsColor: Theme.inkMuted) }
    @MainActor static var moss: Color { Color(nsColor: Theme.moss) }
    @MainActor static var ochre: Color { Color(nsColor: Theme.ochre) }
    @MainActor static var persimmon: Color { Color(nsColor: Theme.persimmon) }
}

extension Font {
    @MainActor static var themeCaption: Font { Font(Theme.caption as CTFont) }
    @MainActor static var themePill: Font { Font(Theme.pill as CTFont) }
}

/// A short marker in the app's pill look, such as "Default" beside an app's name: the ground and height of a ref pill in running text, without a glyph since it names no ref.
struct PillLabel: View {
    let text: LocalizedStringResource

    var body: some View {
        Text(text)
            .font(.themePill)
            .foregroundStyle(.ink)
            .padding(.horizontal, Theme.RefText.trailingPadding)
            .padding(.vertical, Theme.RefText.extraHeight / 2)
            .background(Capsule().fill(Color(nsColor: PillLabel.ground)))
    }

    /// The muted kinds' pill ground (commit, path, stash) from `RefText`, resolved for whichever appearance draws it.
    @MainActor private static let ground = NSColor(name: nil) { appearance in
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            color = MainActor.assumeIsolated { Theme.inkMuted.mixed(into: Theme.surface0, fraction: Theme.Pill.tint.plain) }
        }
        return color
    }
}
