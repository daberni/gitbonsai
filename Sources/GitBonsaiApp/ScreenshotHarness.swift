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

    /// Captures the window once every pending step ran and the detail panel finished loading, then quits. `GITBONSAI_CAPTURE_DELAY=<seconds>` waits that much longer.
    static func captureAndQuit(window: NSWindow) {
        guard outputPath != nil else { return }
        if capturesSettingsInstead(of: window) { return }
        captureWindow = window
        let timeout = environment["GITBONSAI_TIMEOUT"].flatMap(Double.init) ?? 120
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated {
                guard captureWindow != nil, pendingSteps > 0 else { return }
                FileHandle.standardError.write(Data("harness: \(pendingSteps) steps still pending after \(Int(timeout)) s; capturing anyway\n".utf8))
                pendingSteps = 0
                captureWhenIdle()
            }
        }
        captureWhenIdle()
    }

    /// Steps scheduled with `after` or holding with `hold` that have not finished; the capture waits for them.
    private static var pendingSteps = 0
    private static var captureWindow: NSWindow?
    private static var beforeCaptureSteps: [@MainActor () -> Void] = []

    /// Runs `work` right before the capture, once nothing holds it any more.
    static func beforeCapture(_ work: @escaping @MainActor () -> Void) {
        beforeCaptureSteps.append(work)
    }

    /// Runs `work` after `seconds` and holds the capture until it ran. Steps it schedules in turn hold the capture too, so a chain of steps finishes before the capture.
    static func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let release = hold()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                work()
                release()
            }
        }
    }

    /// Holds the capture until the returned closure is called, for a step that waits on an event instead of a time.
    static func hold() -> @MainActor () -> Void {
        guard isActive else { return {} }
        pendingSteps += 1
        var released = false
        return {
            guard !released else { return }
            released = true
            pendingSteps = max(pendingSteps - 1, 0)
            captureWhenIdle()
        }
    }

    private static func captureWhenIdle() {
        guard pendingSteps == 0, let window = captureWindow, let outputPath, let view = window.contentView?.superview else { return }
        captureWindow = nil
        Task { @MainActor in
            // The file lists load asynchronously after the history; the capture shows them loaded.
            for detail in views(of: DetailView.self, in: window) { await detail.loadTask?.value }
            if let delay = environment["GITBONSAI_CAPTURE_DELAY"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
            // The frame view above the content view also holds the title bar, so the traffic lights are in the picture.
            beforeCaptureSteps.forEach { $0() }
            view.layoutSubtreeIfNeeded()
            writePNG(of: view, to: outputPath)
            // A sheet left unanswered keeps the app from quitting; aborting it answers like a cancel.
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            }
            NSApp.terminate(nil)
        }
    }

    /// Renders the view and its subviews as they would draw on screen and writes them as a PNG.
    static func writePNG(of view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
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
