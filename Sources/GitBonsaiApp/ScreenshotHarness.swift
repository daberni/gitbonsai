import AppKit

/// Agent-facing verification: with `GITBONSAI_SCREENSHOT=/path/out.png` the app renders its window to a PNG once loading has finished and quits.
/// The README lists the switches that set up a state or drive the UI with real events before the capture.
@MainActor
enum ScreenshotHarness {
    static var outputPath: String? { environment["GITBONSAI_SCREENSHOT"] }
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var didRunOneTimeAction = false

    static func applyAppearance() {
        switch environment["GITBONSAI_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

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

    /// `GITBONSAI_CHECKOUT=<branch>` checks a local branch out and `GITBONSAI_SWITCH_WORKTREE=<folder or path>` switches the tab, once per run. Returns true when one ran.
    static func runOneTimeAction(on tab: RepositoryViewController) -> Bool {
        guard !didRunOneTimeAction else { return false }
        if let branch = environment["GITBONSAI_CHECKOUT"] {
            didRunOneTimeAction = true
            tab.checkoutController.checkout(.localBranch(branch))
            return true
        }
        if let folder = environment["GITBONSAI_SWITCH_WORKTREE"], let info = tab.viewModel.worktrees.first(where: { $0.worktree.path == folder || ($0.worktree.path as NSString).lastPathComponent == folder }) {
            didRunOneTimeAction = true
            tab.onSwitchWorktree?(info.worktree.path)
            return true
        }
        return false
    }

    /// Selection, column width, a real drag over the rows and the sideways scroll of the graph.
    static func prepare(_ history: HistoryViewController) {
        let table = history.tableView
        let columns = history.columnsController
        if let row = environment["GITBONSAI_SELECT_ROW"].flatMap(Int.init), row < table.numberOfRows { history.select(row: row, scroll: true) }
        if let width = environment["GITBONSAI_GRAPH_WIDTH"].flatMap(Double.init), let graph = columns.columns.layout(in: table.bounds.width).graph {
            columns.resize(.graph, to: graph.lowerBound + CGFloat(width))
        }
        if let target = environment["GITBONSAI_DRAG_GRAPH_TO"].flatMap(Double.init), let window = table.window {
            let graph = columns.columns.layout(in: table.bounds.width).graph ?? 0...0
            let y = table.visibleRect.midY
            let start = table.convert(NSPoint(x: graph.upperBound, y: y), to: nil)
            let end = table.convert(NSPoint(x: graph.lowerBound + CGFloat(target), y: y), to: nil)
            drag(in: window, from: start, to: end, steps: 1)
            FileHandle.standardError.write(Data("graph column after drag: \(columns.columns.graph)\n".utf8))
        }
        if let offset = environment["GITBONSAI_GRAPH_SCROLL"].flatMap(Double.init), let graph = columns.columns.layout(in: table.bounds.width).graph {
            _ = columns.scrollGraph(by: -CGFloat(offset), at: NSPoint(x: graph.lowerBound + 1, y: 1))
        }
    }

    /// Queues the movement and the release, then delivers the press. Views that follow the mouse in a tracking loop find the queued events there.
    static func drag(in window: NSWindow, from start: CGPoint, to end: CGPoint, steps: Int) {
        for step in 1...max(steps, 1) {
            let fraction = CGFloat(step) / CGFloat(max(steps, 1))
            if let event = mouseEvent(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction), in: window) { NSApp.postEvent(event, atStart: false) }
        }
        if let up = mouseEvent(.leftMouseUp, at: end, in: window) { NSApp.postEvent(up, atStart: false) }
        if let down = mouseEvent(.leftMouseDown, at: start, in: window) { window.sendEvent(down) }
    }

    static func click(in window: NSWindow, at point: CGPoint) {
        if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
        if let down = mouseEvent(.leftMouseDown, at: point, in: window) { window.sendEvent(down) }
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
