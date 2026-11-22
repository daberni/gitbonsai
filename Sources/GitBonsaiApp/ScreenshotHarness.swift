import AppKit

/// Agent-facing verification: with `GITBONSAI_SCREENSHOT=/path/out.png` the app renders its window to a PNG once loading has finished and quits.
/// `GITBONSAI_APPEARANCE=light|dark` forces the appearance, `GITBONSAI_SELECT_ROW=n` selects a history row first.
enum ScreenshotHarness {
    static var outputPath: String? { ProcessInfo.processInfo.environment["GITBONSAI_SCREENSHOT"] }
    static var selectRow: Int? { ProcessInfo.processInfo.environment["GITBONSAI_SELECT_ROW"].flatMap(Int.init) }

    @MainActor
    static func applyAppearance() {
        switch ProcessInfo.processInfo.environment["GITBONSAI_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    @MainActor
    static func captureAndQuit(window: NSWindow) {
        guard let outputPath, let view = window.contentView else { return }
        // Give the last batch of rows and the asynchronously loaded file list time to lay out and draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outputPath))
            }
            NSApp.terminate(nil)
        }
    }
}
