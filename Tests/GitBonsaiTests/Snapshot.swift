import AppKit
import CoreImage
import XCTest
@testable import GitBonsai

/// Renders views off screen in light and dark and compares them with reference PNGs in `Tests/__Snapshots__`, outside the test target, which stay on the machine and out of the repository.
/// A missing reference is recorded on the first run and compared on later ones; delete the folder to record anew after an intended change or an OS update. The references belong to the machine and OS build that recorded them (`machine.txt`); on another the comparison is skipped.
/// `GITBONSAI_RECORD_SNAPSHOTS=1 swift test --filter Snapshot` records all of them anew.
@MainActor
enum Snapshot {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("__Snapshots__", isDirectory: true)
    static var records: Bool { ProcessInfo.processInfo.environment["GITBONSAI_RECORD_SNAPSHOTS"] == "1" }

    /// The machine the references were recorded on.
    static var machine: String {
        let build = (try? String(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"), encoding: .utf8)).flatMap { plist in
            plist.range(of: "<key>ProductBuildVersion</key>").flatMap { key in
                plist[key.upperBound...].range(of: "<string>").flatMap { open in
                    plist[open.upperBound...].range(of: "</string>").map { close in String(plist[open.upperBound..<close.lowerBound]) }
                }
            }
        } ?? "unknown"
        return "macOS \(build) @\(Int(NSScreen.main?.backingScaleFactor ?? 2))x"
    }

    /// An off-screen window of `size` in `appearance` holding `view`.
    static func window(for view: NSView, size: CGSize, appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    /// Compares `view` with the reference `name`. Text fields whose text matches `volatile` (load times and relative dates by default) are blanked first.
    /// A sheet's window with its frame view; the glass and vibrant text of sheets blend with what lies behind them, so the window background goes underneath.
    static func assert(sheet window: NSWindow, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView, file: file, line: line)
        view.layoutSubtreeIfNeeded()
        try assert(view, named: name, background: true, file: file, line: line)
    }

    static func assert(_ view: NSView, named name: String, volatile: String = #"\d+(\.\d+)? ms|\d+ \w+\.? ago|yesterday"#, background: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let machineFile = directory.appendingPathComponent("machine.txt")
        let recorded = (try? String(contentsOf: machineFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !records, let recorded, recorded != machine { throw XCTSkip("snapshots were recorded on \(recorded), this is \(machine); delete \(directory.path) to record them here") }
        blank(view, matching: try Regex(volatile))
        view.window?.layoutIfNeeded()
        view.window?.displayIfNeeded()
        guard let rep = background ? renderOverBackground(view) : render(view), let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("could not render \(name)", file: file, line: line) }
        let reference = directory.appendingPathComponent("\(name).png")
        guard !records, FileManager.default.fileExists(atPath: reference.path) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: reference)
            try machine.write(to: machineFile, atomically: true, encoding: .utf8)
            print("Recorded snapshot \(reference.path)")
            return
        }
        let difference = differingPixels(png, try Data(contentsOf: reference))
        guard difference.count > 0 else { return }
        let actual = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(name).png")
        try png.write(to: actual)
        XCTFail("\(name): \(difference.count) pixels differ in \(difference.bounds); rendered: \(actual.path)", file: file, line: line)
    }

    private static func blank(_ view: NSView, matching volatile: Regex<AnyRegexOutput>) {
        if let field = view as? NSTextField, field.stringValue.contains(volatile) { field.stringValue = field.stringValue.replacing(volatile, with: "—") }
        view.subviews.forEach { blank($0, matching: volatile) }
    }

    private static func differingPixels(_ a: Data, _ b: Data) -> (count: Int, bounds: CGRect) {
        guard let x = pixels(a), let y = pixels(b) else { return (1, .null) }
        guard x.width == y.width, x.height == y.height else { return (max(x.bytes.count, y.bytes.count) / 4, .null) }
        var count = 0
        var bounds = CGRect.null
        for index in stride(from: 0, to: x.bytes.count, by: 4) where x.bytes[index..<index + 4] != y.bytes[index..<index + 4] {
            count += 1
            let pixel = index / 4
            bounds = bounds.union(CGRect(x: pixel % x.width, y: pixel / x.width, width: 1, height: 1))
        }
        return (count, bounds)
    }

    private static func pixels(_ data: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    private static func renderOverBackground(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }

    // MARK: Liquid Glass

    /// `cacheDisplay` cannot draw a glass view, whose backdrop only the window server composites. The view is rendered without its glass views, and each one is composited over the result: the backdrop blurred and saturated, the tint, its content and a hairline rim.
    static func render(_ view: NSView) -> NSBitmapImageRep? {
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
        let frosted = backdrop.clampedToExtent().applyingGaussianBlur(sigma: 12 * scale).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6]).cropped(to: pixels)
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
