import AppKit

/// Scrolling the history graph and diffs: whether every row the table keeps follows the sideways offset.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SCROLL_CHECK=graph|diff,…` drives each list with synthetic wheel events at a fixed pointer and prints what the rows show afterwards.
    static func driveScrollChecks(on tab: RepositoryViewController) {
        guard let checks = environment["GITBONSAI_SCROLL_CHECK"]?.split(separator: ",").map(String.init) else { return }
        let release = hold()
        var remaining = checks
        func next() {
            guard !remaining.isEmpty else { return release() }
            let check = remaining.removeFirst()
            switch check {
            case "graph": checkGraphScroll(on: tab, then: next)
            case "diff": checkDiffScroll(on: tab, then: next)
            default: next()
            }
        }
        after(1, next)
    }

    /// A wheel event at `point` in window coordinates, delivered to the view under it; positive deltas scroll content right and down.
    static func wheel(dx: CGFloat, dy: CGFloat, at point: CGPoint, in window: NSWindow) {
        guard let source = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        let height = NSScreen.screens.first?.frame.height ?? 0
        // Without a window AppKit reports the event's screen location as its location in the window, so the window point goes in as the screen point.
        source.location = CGPoint(x: point.x, y: height - point.y)
        guard let event = NSEvent(cgEvent: source), let view = window.contentView?.superview?.hitTest(point) else { return }
        view.scrollWheel(with: event)
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("scroll check \(text)\n".utf8))
    }

    /// Diagonal and vertical wheel events over the graph column; every row view the table keeps must draw the offset the columns hold.
    private static func checkGraphScroll(on tab: RepositoryViewController, then next: @escaping @MainActor () -> Void) {
        let table = tab.history.tableView
        guard let window = table.window, let graph = tab.history.columnsController.columns.layout(in: table.bounds.width).graph else { return next() }
        let point = table.convert(NSPoint(x: (graph.lowerBound + graph.upperBound) / 2, y: table.visibleRect.midY), to: nil)
        func report(_ step: String) {
            let offset = tab.history.columnsController.columns.graphScrollX
            var stale: [Int] = []
            var count = 0
            table.enumerateAvailableRowViews { rowView, row in
                count += 1
                guard let cell = rowView.view(atColumn: 0) as? GraphRowView else { return }
                if cell.model?.columns.graphScrollX != offset { stale.append(row) }
            }
            log("graph \(step): offset \(offset), top \(table.visibleRect.minY), \(count) row views, stale rows \(stale)")
        }
        report("start")
        wheel(dx: 30, dy: 50, at: point, in: window)
        after(0.2) {
            report("after diagonal")
            // Responsive scrolling keeps rows below the visible ones prepared; a background window does not, so the harness asks for them.
            table.prepareRows(beyondVisible: 10)
            wheel(dx: 40, dy: 0, at: point, in: window)
            report("right after sideways")
            after(0.2) {
                report("after sideways")
                wheel(dx: 0, dy: 400, at: point, in: window)
                after(0.3) {
                    report("after scrolling down")
                    next()
                }
            }
        }
    }

    /// Scrolls the open diff sideways, then down; every hunk header the table keeps must place its button for the new sideways offset.
    private static func checkDiffScroll(on tab: RepositoryViewController, then next: @escaping @MainActor () -> Void) {
        guard let window = tab.view.window, let hunk = views(of: DiffHunkView.self, in: window).first, let scroll = hunk.enclosingScrollView else { log("diff: no hunk"); return next() }
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        func report(_ step: String) {
            let hunks = views(of: DiffHunkView.self, in: window).filter { $0.window != nil }
            hunks.forEach { $0.layoutSubtreeIfNeeded() }
            let stale = hunks.filter { hunk in
                let clip = hunk.convert(scroll.contentView.bounds, from: scroll.contentView)
                return abs(hunk.action.frame.maxX - (min(clip.maxX, hunk.bounds.maxX) - Theme.Space.m)) > 0.5
            }.count
            log("diff \(step): sideways \(scroll.contentView.bounds.minX), top \(scroll.contentView.bounds.minY), \(hunks.count) hunk headers, stale \(stale)")
        }
        hunk.enclosingTable?.prepareRows(beyondVisible: 300)
        wheel(dx: 120, dy: 0, at: point, in: window)
        report("right after sideways")
        after(0.2) {
            report("after sideways")
            wheel(dx: 40, dy: 30, at: point, in: window)
        }
        after(0.4) {
            report("after diagonal")
            wheel(dx: 0, dy: 600, at: point, in: window)
            after(0.3) {
                report("after scrolling down")
                next()
            }
        }
    }
}

private extension NSView {
    var enclosingTable: NSTableView? {
        var current = superview
        while let view = current, !(view is NSTableView) { current = view.superview }
        return current as? NSTableView
    }
}

private extension NSTableView {
    func prepareRows(beyondVisible count: Int) {
        let visible = rows(in: visibleRect)
        for row in (visible.location + visible.length)..<min(visible.location + visible.length + count, numberOfRows) { _ = rowView(atRow: row, makeIfNecessary: true) }
    }
}
