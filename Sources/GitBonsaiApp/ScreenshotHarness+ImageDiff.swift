import AppKit

/// Harness switches for the image diff.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_CLICK_IMAGE_MODE=sideBySide|swipe|onionSkin|text` clicks that segment of the image toggle in the open diff; `GITBONSAI_IMAGE_SWIPE=<0…1>` then drags the swipe line to that share of the image; `GITBONSAI_IMAGE_OPACITY=<0…1>` drags the onion skin slider there. All with real mouse events; the state is printed after each step.
    static func driveImageDiff(on tab: RepositoryViewController) {
        let mode = environment["GITBONSAI_CLICK_IMAGE_MODE"].flatMap(ImageDiffMode.init)
        let swipe = environment["GITBONSAI_IMAGE_SWIPE"].flatMap(Double.init)
        let opacity = environment["GITBONSAI_IMAGE_OPACITY"].flatMap(Double.init)
        guard mode != nil || swipe != nil || opacity != nil else { return }
        let canvas = tab.diff.imageView.canvas
        func report(_ step: String) {
            let shown = !tab.diff.imageView.isHidden
            FileHandle.standardError.write(Data("\(step): images shown \(shown), mode \(canvas.drawnMode.rawValue), swipe \(String(format: "%.2f", canvas.swipe)), opacity \(String(format: "%.2f", canvas.opacity))\n".utf8))
        }
        func drive() {
            guard let window = tab.view.window else { return }
            if let swipe {
                let frame = canvas.swipeImageFrame
                let start = canvas.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
                let end = canvas.convert(CGPoint(x: frame.minX + frame.width * swipe, y: frame.midY), to: nil)
                drag(in: window, from: start, to: end, steps: 8)
                after(0.3) { report("dragged swipe") }
            }
            if let opacity {
                let slider = tab.diff.imageView.opacity
                let knob = slider.convert(CGPoint(x: slider.bounds.width * slider.doubleValue, y: slider.bounds.midY), to: nil)
                let end = slider.convert(CGPoint(x: slider.bounds.width * opacity, y: slider.bounds.midY), to: nil)
                drag(in: window, from: knob, to: end, steps: 8)
                after(0.3) { report("dragged opacity") }
            }
        }
        after(0.8) {
            report("loaded")
            guard let mode, let window = tab.view.window else { return drive() }
            let header = tab.diff.header
            guard !header.imageModes.isHidden, let index = header.offeredImageModes.firstIndex(of: mode) else {
                FileHandle.standardError.write(Data("no image mode \(mode.rawValue)\n".utf8))
                return
            }
            let segment = header.imageModes.bounds.width / CGFloat(header.offeredImageModes.count)
            click(in: window, at: header.imageModes.convert(CGPoint(x: segment * (CGFloat(index) + 0.5), y: header.imageModes.bounds.midY), to: nil))
            after(0.4) {
                report("clicked \(mode.rawValue)")
                drive()
            }
        }
    }
}
