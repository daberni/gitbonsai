import Foundation

/// Branch strand colors in a saturated "rainbow" style, so neighbouring lanes stay distinct.
/// Ordered so that neighbouring strands never share a hue family.
public enum GraphPalette {
    public typealias RGB = (red: Double, green: Double, blue: Double)

    public static let colors: [RGB] = [
        (0.16, 0.76, 0.78), // teal
        (0.78, 0.33, 0.72), // magenta
        (0.95, 0.52, 0.22), // orange
        (0.27, 0.58, 1.00), // blue
        (0.90, 0.72, 0.23), // yellow
        (0.88, 0.30, 0.42), // raspberry
        (0.42, 0.78, 0.40), // green
        (0.58, 0.47, 0.95), // violet
        (0.98, 0.42, 0.62), // pink
        (0.35, 0.80, 0.60), // mint
        (0.86, 0.45, 0.30), // terracotta
        (0.45, 0.62, 0.85), // steel
    ]

    public static func color(for index: Int) -> RGB {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
