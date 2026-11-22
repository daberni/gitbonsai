// Writes the classic .iconset (16–512 pt at @1x and @2x) from the app icon actool compiled into a bundle's Assets.car.
// Usage: swift scripts/app-icon-iconset.swift <GitBonsai.app> <out.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let bundle = Bundle(path: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: app-icon-iconset.swift <app bundle> <out.iconset>\n".utf8))
    exit(2)
}
guard let icon = bundle.image(forResource: "AppIcon") else {
    FileHandle.standardError.write(Data("no AppIcon in \(arguments[1])\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
