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

    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyStrong = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let caption = NSFont.systemFont(ofSize: 11)
    static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let pill = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let pillStrong = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    enum Graph {
        static let rowHeight: CGFloat = 36
        static let lane: CGFloat = 28
        static let nodeRadius: CGFloat = 12
        static let mergeRadius: CGFloat = 5.5
        static let stashHalf: CGFloat = 9
        static let wipRadius: CGFloat = 7.5
        static let strandWidth: CGFloat = 2
        /// Height of the S transition between two lanes; outside it a strand runs straight.
        static let elbow: CGFloat = 12
        static let bandInset: CGFloat = 5
        static let labelColumn: CGFloat = 200
        static let firstLane: CGFloat = 22
        /// Wider graphs are clipped at this many lanes so the commit text keeps its room; horizontal scrolling comes later.
        static let maxVisibleLanes = 5
        static let authorColumn: CGFloat = 150
        static let dateColumn: CGFloat = 96
    }
}

extension NSColor {
    /// Mixes this color into `ground` and returns an opaque result, resolved for the current drawing appearance.
    func mixed(into ground: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = ground.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: b.redComponent + (a.redComponent - b.redComponent) * fraction, green: b.greenComponent + (a.greenComponent - b.greenComponent) * fraction, blue: b.blueComponent + (a.blueComponent - b.blueComponent) * fraction, alpha: 1)
    }
}
