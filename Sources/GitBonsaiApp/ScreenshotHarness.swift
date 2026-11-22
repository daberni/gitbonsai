import AppKit
import GitEngine

/// Agent-facing verification: with `GITBONSAI_SCREENSHOT=/path/out.png` the app renders its window to a PNG once loading has finished and quits.
/// The README lists the switches that set up a state or drive the UI with real events before the capture.
@MainActor
enum ScreenshotHarness {
    static var outputPath: String? { environment["GITBONSAI_SCREENSHOT"] }
    static var isActive: Bool { outputPath != nil }
    /// Harness runs stay in the background unless `GITBONSAI_FOREGROUND=1` asks for a normal app with Dock icon, activation and its window in front, for checks that need it.
    static var runsInBackground: Bool { isActive && environment["GITBONSAI_FOREGROUND"] != "1" }
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var didRunOneTimeAction = false
    static var didDragTab = false
    /// True while `press` delivers a harness press into a window that is not key.
    static var isPressingWithoutKeyWindow = false

    /// Background runs never show a window: every window of the app, sheets and alerts included, stays fully transparent and lets real clicks through.
    /// Captures render the views themselves and the harness sends its events straight to the window, so both keep working.
    static func keepWindowsInvisible() {
        hideWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideWindows() }
        }
    }

    static func hideWindows() {
        for window in NSApp.windows where window.alphaValue > 0 || !window.ignoresMouseEvents {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    static func applyAppearance() {
        switch environment["GITBONSAI_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    static func captureAndQuit(window: NSWindow) {
        // The frame view above the content view also holds the title bar, so the traffic lights are in the picture.
        guard let outputPath, let view = window.contentView?.superview else { return }
        if capturesSettingsInstead(of: window) { return }
        // Give the last batch of rows and the asynchronously loaded file list time to lay out and draw.
        let delay = environment["GITBONSAI_CAPTURE_DELAY"].flatMap(Double.init) ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outputPath))
            }
            // A sheet left unanswered keeps the app from quitting; aborting it answers like a cancel.
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            }
            NSApp.terminate(nil)
        }
    }

    static func views<V: NSView>(of type: V.Type, in window: NSWindow) -> [V] {
        var found: [V] = []
        func collect(_ view: NSView) {
            if let match = view as? V { found.append(match) }
            view.subviews.forEach(collect)
        }
        if let content = window.contentView { collect(content) }
        return found
    }

    /// Queues the movement and the release, then delivers the press. Views that follow the mouse in a tracking loop find the queued events there.
    static func drag(in window: NSWindow, from start: CGPoint, to end: CGPoint, steps: Int) {
        for step in 1...max(steps, 1) {
            let fraction = CGFloat(step) / CGFloat(max(steps, 1))
            if let event = mouseEvent(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction), in: window) { NSApp.postEvent(event, atStart: false) }
        }
        if let up = mouseEvent(.leftMouseUp, at: end, in: window) { NSApp.postEvent(up, atStart: false) }
        if let down = mouseEvent(.leftMouseDown, at: start, in: window) { press(down, in: window) }
    }

    static func click(in window: NSWindow, at point: CGPoint) {
        if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
        if let down = mouseEvent(.leftMouseDown, at: point, in: window) { press(down, in: window) }
    }

    /// Delivers a press the way a key window would. A background run never has a key window, and AppKit takes a press on a control that refuses first mouse, such as a sheet's buttons, as a click that only activates the window.
    /// Such a press goes to the view under the point instead; its tracking loop then finds the queued release like it does in a key window. A table under the point becomes first responder first, as a key window's click would make it.
    static func press(_ event: NSEvent, in window: NSWindow) {
        guard !window.isKeyWindow, let view = window.contentView?.superview?.hitTest(event.locationInWindow) else {
            window.sendEvent(event)
            return
        }
        if let table = enclosingTable(of: view), table.acceptsFirstResponder { window.makeFirstResponder(table) }
        isPressingWithoutKeyWindow = true
        defer { isPressingWithoutKeyWindow = false }
        if view.acceptsFirstMouse(for: event) { window.sendEvent(event) } else { view.mouseDown(with: event) }
    }

    private static func enclosingTable(of view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let candidate = current, !(candidate is NSTableView) { current = candidate.superview }
        return current as? NSTableView
    }

    static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
