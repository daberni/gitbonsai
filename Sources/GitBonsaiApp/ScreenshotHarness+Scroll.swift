import AppKit

/// Scrolling under a still pointer: whether the graph's sideways offset and the lists' hover follow the content.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SCROLL_CHECK=graph|files|sidebar|diff,…` drives each list with synthetic wheel events at a fixed pointer and prints what the rows show afterwards.
    static func driveScrollChecks(on tab: RepositoryViewController) {
        guard let checks = environment["GITBONSAI_SCROLL_CHECK"]?.split(separator: ",").map(String.init) else { return }
        let release = hold()
        var remaining = checks
        func next() {
            guard !remaining.isEmpty else { return release() }
            let check = remaining.removeFirst()
            switch check {
            case "graph": checkGraphScroll(on: tab, then: next)
            case "files": checkFileHover(on: tab, then: next)
            case "sidebar": checkSidebarHover(on: tab, then: next)
            case "diff": checkDiffScroll(on: tab, then: next)
            default: next()
            }
        }
        after(1, next)
    }

    /// A wheel event at `point` in window coordinates, delivered to the view under it; positive deltas scroll content right and down.
    static func wheel(dx: CGFloat, dy: CGFloat, at point: CGPoint, in window: NSWindow) {
        guard let source = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        let screen = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        // Without a window AppKit reports the event's screen location as its location in the window, so the window point goes in as the screen point.
        source.location = CGPoint(x: point.x, y: height - point.y)
        guard let event = NSEvent(cgEvent: source), let view = window.contentView?.superview?.hitTest(point) else { return }
        ListHover.pointerLocation = { screen }
        view.scrollWheel(with: event)
    }

    /// A pointer move at `point` the way tracking areas deliver it: to the owner of every tracking area of a view under the point.
    /// A background window gets no `updateTrackingAreas`, so a hit view without pointer-move areas of its own gets the move itself, as its area would have delivered it.
    static func trackingMove(to point: CGPoint, in window: NSWindow) {
        guard let root = window.contentView, let event = mouseEvent(.mouseMoved, at: point, in: window) else { return }
        ListHover.pointerLocation = { window.convertPoint(toScreen: point) }
        func visit(_ view: NSView) {
            let local = view.convert(point, from: nil)
            for area in view.trackingAreas where area.options.contains(.mouseMoved) {
                let rect = area.options.contains(.inVisibleRect) ? view.bounds : area.rect
                if rect.contains(local) { (area.owner as? NSResponder)?.mouseMoved(with: event) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        if let hit = root.superview?.hitTest(point), !hit.trackingAreas.contains(where: { $0.options.contains(.mouseMoved) }) { hit.mouseMoved(with: event) }
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

    /// Hovers the second file row, then scrolls the detail panel under the still pointer; exactly the row under the pointer may show the hover.
    private static func checkFileHover(on tab: RepositoryViewController, then next: @escaping @MainActor () -> Void) {
        guard let window = tab.view.window else { return next() }
        let rows = fileRows(in: window)
        guard rows.count > 4 else { log("files: only \(rows.count) rows"); return next() }
        let row = rows[1]
        let point = row.convert(NSPoint(x: row.bounds.width / 3, y: row.bounds.midY), to: nil)
        func report(_ step: String) {
            let shown = fileRows(in: window)
            let hovered = shown.filter { $0.hover != nil }.map { $0.model.selection.path }
            let under = shown.first { $0.bounds.contains($0.convert(point, from: nil)) }?.model.selection.path ?? "none"
            log("files \(step): hovered \(hovered), under pointer \(under)")
        }
        trackingMove(to: point, in: window)
        after(0.2) {
            report("before scrolling")
            wheel(dx: 0, dy: 3 * Theme.FileList.rowHeight, at: point, in: window)
            after(0.3) {
                report("after scrolling down")
                next()
            }
        }
    }

    /// Hovers a sidebar row, then scrolls the sidebar under the still pointer; the hover must stay on the row under the pointer.
    private static func checkSidebarHover(on tab: RepositoryViewController, then next: @escaping @MainActor () -> Void) {
        let sidebar = tab.sidebar
        guard let window = sidebar.window, sidebar.frames.count > 6, let clip = sidebar.enclosingScrollView?.contentView else { return next() }
        let target = sidebar.frames[3]
        let point = sidebar.convert(NSPoint(x: target.midX, y: target.midY), to: nil)
        func report(_ step: String) {
            let local = sidebar.convert(point, from: nil)
            let under = sidebar.frames.firstIndex { $0.contains(local) }
            log("sidebar \(step): hovered \(sidebar.hovered.map(String.init) ?? "none"), under pointer \(under.map(String.init) ?? "none"), top \(clip.bounds.minY)")
        }
        trackingMove(to: point, in: window)
        after(0.2) {
            report("before scrolling")
            wheel(dx: 0, dy: 3 * target.height, at: point, in: window)
            after(0.3) {
                report("after scrolling down")
                next()
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
