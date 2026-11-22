import AppKit

/// Design tokens from docs/design/tokens.json. Colors resolve per appearance; metrics are the graph and sidebar grid.
@MainActor
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? hex(dark, darkAlpha) : hex(light, lightAlpha)
        }
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: alpha)
    }

    static let surface0 = dynamic(0xf8f4ee, 0x1e1a17)
    static let surface1 = dynamic(0xf1ebe2, 0x26211d)
    static let surface2 = dynamic(0xffffff, 0x2f2924)
    static let surfaceSelected = dynamic(0x456f45, 0x8fbe86, lightAlpha: 0.12, darkAlpha: 0.16)
    static let hairline = dynamic(0xe4dccf, 0x3a332c)
    static let ink = dynamic(0x2a241e, 0xf1eae1)
    static let inkMuted = dynamic(0x6b6156, 0xb3a89b)
    static let inkFaint = dynamic(0x8f857a, 0x857a6e)
    static let moss = dynamic(0x456f45, 0x8fbe86)
    static let onMoss = dynamic(0xffffff, 0x15200f)
    static let clay = dynamic(0x9a4f33, 0xd9906f)
    static let claySoft = dynamic(0xf0dccf, 0x43302a)
    static let persimmonSoft = dynamic(0xf6dcd4, 0x4a2a24)
    static let ochre = dynamic(0x8c6212, 0xe0b04a)
    static let persimmon = dynamic(0xb53d27, 0xea7d64)
    static let sky = dynamic(0x2f6f96, 0x7fb4d8)

    /// Twelve strand colors, cycled in this order so neighbouring strands never share a hue family.
    private static let strands: [NSColor] = [
        dynamic(0x5a9458, 0x6fae6b), dynamic(0xdd7446, 0xde8f6b), dynamic(0x9657a6, 0xad8bbb), dynamic(0x4489c2, 0x7aa6cf),
        dynamic(0xd19f2a, 0xd1b05e), dynamic(0xd25f78, 0xd68aa0), dynamic(0x2c8b7c, 0x6aae9f), dynamic(0x8577cf, 0x9f98d4),
        dynamic(0xe39a5c, 0xdfb18a), dynamic(0x35a3b1, 0x74bcc6), dynamic(0xad4a7c, 0xbf86a6), dynamic(0x86943a, 0xaab46e),
    ]

    static func strand(_ index: Int) -> NSColor {
        strands[((index % strands.count) + strands.count) % strands.count]
    }

    // MARK: Type (type in tokens.json)

    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyStrong = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let bodyDigits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 11)
    static let captionDigits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Tracking of `label` (0.06 em at 11 pt).
    static let labelKern: CGFloat = 0.66
    static let pill = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let pillStrong = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let heading = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoStrong = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    /// Initials inside avatar rings.
    static let initials = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let initialsSmall = NSFont.systemFont(ofSize: 8.5, weight: .semibold)

    // MARK: Scales (spacing, radius and stroke in tokens.json)

    enum Space {
        /// space-1
        static let xs: CGFloat = 4
        /// space-2
        static let s: CGFloat = 8
        /// space-3
        static let m: CGFloat = 12
        /// space-4
        static let l: CGFloat = 16
        /// space-6
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let icon: CGFloat = 1.5
        static let strand: CGFloat = 2
        /// Dash pattern of parked strands (stash, working directory) and their nodes.
        static let dash: [CGFloat] = [3, 3]
        static let nodeDash: [CGFloat] = [2.5, 2]
    }

    /// Glyph boxes.
    enum Icon {
        static let small: CGFloat = 14
        static let regular: CGFloat = 16
        static let large: CGFloat = 18
    }

    /// Alpha of ink washes for hover and press feedback.
    enum Wash {
        static let hover: CGFloat = 0.06
        static let hoverStrong: CGFloat = 0.08
        static let pressed: CGFloat = 0.12
        static let guide: CGFloat = 0.18
    }

    /// Rows and lanes outside the current focus, such as commits a search does not match or everything but source and target during a drag-and-drop merge.
    enum Focus {
        static let dimmedAlpha: CGFloat = 0.35
    }

    /// Movement or distance in points before a press becomes a drag, and the reach of a draggable boundary.
    static let dragThreshold: CGFloat = 4
}

extension NSColor {
    /// Mixes this color into `ground` and returns an opaque result, resolved for the current drawing appearance.
    func mixed(into ground: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = ground.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: b.redComponent + (a.redComponent - b.redComponent) * fraction, green: b.greenComponent + (a.greenComponent - b.greenComponent) * fraction, blue: b.blueComponent + (a.blueComponent - b.blueComponent) * fraction, alpha: 1)
    }
}
