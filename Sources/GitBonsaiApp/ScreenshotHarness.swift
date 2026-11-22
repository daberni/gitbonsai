import AppKit
import GitEngine

/// Agent-facing verification: with `GITBONSAI_SCREENSHOT=/path/out.png` the app renders its window to a PNG once loading has finished and quits.
/// The README lists the switches that set up a state or drive the UI with real events before the capture.
@MainActor
enum ScreenshotHarness {
    static var outputPath: String? { environment["GITBONSAI_SCREENSHOT"] }
    static var isActive: Bool { outputPath != nil }
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var didRunOneTimeAction = false
    private static var didDragTab = false

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
        // Give the last batch of rows and the asynchronously loaded file list time to lay out and draw.
        let delay = environment["GITBONSAI_CAPTURE_DELAY"].flatMap(Double.init) ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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

    /// `GITBONSAI_SIDEBAR_SCROLL=<points>` scrolls the sidebar down and prints where its scroller and status slot column lie.
    /// The capture does not draw an overlay scroller, so the printed edges show whether it would cover the slot.
    static func scrollSidebar(_ sidebar: SidebarView) {
        guard let offset = environment["GITBONSAI_SIDEBAR_SCROLL"].flatMap(Double.init), let scrollView = sidebar.enclosingScrollView else { return }
        sidebar.scroll(CGPoint(x: 0, y: offset))
        let scroller = scrollView.verticalScroller.map { sidebar.convert($0.bounds, from: $0) }
        let style = scrollView.scrollerStyle == .overlay ? "overlay" : "legacy"
        print("sidebar \(style) scroller x \(scroller.map { "\($0.minX)" } ?? "none"), slot right \(sidebar.slotRight), width \(sidebar.bounds.width)")
    }

    /// `GITBONSAI_OPEN_FILE=<path>` with `GITBONSAI_OPEN_SOURCE=unstaged|staged|untracked` opens a file of the working directory, or of the selected commit without a source.
    /// `GITBONSAI_HUNK_ACTION=<n>` then stages or unstages hunk n.
    static func openDiff(on tab: RepositoryViewController) {
        guard let path = environment["GITBONSAI_OPEN_FILE"] else { return }
        let row = tab.history.selectedRow
        let source: DiffSource
        switch environment["GITBONSAI_OPEN_SOURCE"] {
        case "unstaged": source = .unstaged
        case "staged": source = .staged
        case "untracked": source = .untracked
        default:
            guard row >= 0 else { return }
            source = .commit(tab.viewModel.commits[row])
        }
        tab.openFile(FileSelection(path: path, originalPath: nil, source: source))
        if let hunk = environment["GITBONSAI_HUNK_ACTION"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tab.diff.runHunkAction(hunk) }
        }
    }

    /// `GITBONSAI_CLICK_FILE=<n>` clicks the n-th file in the detail panel with real mouse events and reports whether its diff opened.
    static func clickFile(on tab: RepositoryViewController) {
        guard let index = environment["GITBONSAI_CLICK_FILE"].flatMap(Int.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = tab.view.window else { return }
            var rows: [FileRowView] = []
            func collect(_ view: NSView) {
                if let row = view as? FileRowView { rows.append(row) }
                view.subviews.forEach(collect)
            }
            collect(window.contentView!)
            guard rows.indices.contains(index) else {
                FileHandle.standardError.write(Data("only \(rows.count) file rows\n".utf8))
                return
            }
            let row = rows[index]
            let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let hit = window.contentView?.superview?.hitTest(point).map { "\(type(of: $0))" } ?? "nothing"
            click(in: window, at: point)
            // The release is still queued; the result is there once it has been handled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let opened = tab.diff.selection?.path
                FileHandle.standardError.write(Data("clicked \(row.model.selection.path) (hit \(hit)), diff shows \(opened ?? "nothing")\n".utf8))
            }
        }
    }

    /// `GITBONSAI_COMMIT_SUBJECT` and `GITBONSAI_COMMIT_BODY` fill the commit form, `GITBONSAI_AMEND=1` ticks amend,
    /// `GITBONSAI_COMMIT_RUN=1` clicks the commit button.
    static func fillCommit(on tab: RepositoryViewController) {
        let form = tab.commitController.form
        if environment["GITBONSAI_AMEND"] == "1" { form.pressAmend() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let subject = environment["GITBONSAI_COMMIT_SUBJECT"] { form.subjectText = subject }
            if let body = environment["GITBONSAI_COMMIT_BODY"] { form.bodyText = body.replacingOccurrences(of: "\\n", with: "\n") }
            form.onEdit?()
            if environment["GITBONSAI_COMMIT_RUN"] == "1" { form.pressCommit() }
        }
    }

    /// `GITBONSAI_NEW_TAB=1` opens the empty tab after the launch arguments or the saved session.
    static var wantsNewTab: Bool { environment["GITBONSAI_NEW_TAB"] != nil }

    /// `GITBONSAI_CLICK_TAB=n` clicks tab n and `GITBONSAI_DRAG_TAB=from:to` drags a tab, both with real events through the window.
    /// Returns false while a clicked tab is still loading; the caller asks again once it has loaded.
    static func driveTabRow(_ tabBar: TabBarView, in window: NSWindow, tabs: () -> TabList) -> Bool {
        // A real click through the window proves that the tab row receives events under the title bar.
        if let target = environment["GITBONSAI_CLICK_TAB"].flatMap(Int.init), target != tabs().activeIndex, let frame = tabBar.frameOfTab(target) {
            click(in: window, at: tabBar.convert(CGPoint(x: frame.midX - 10, y: frame.midY), to: nil))
            if tabs().activeIndex != target { FileHandle.standardError.write(Data("click on tab \(target) did not reach the tab row\n".utf8)) }
            guard tabs().active?.isLoaded == true else { return false }
        }
        // `from:to` drags the tab at `from` onto the place of the tab at `to`. Selecting it calls back in here, so the flag keeps the drag from starting twice.
        if !didDragTab, let spec = environment["GITBONSAI_DRAG_TAB"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let source = tabBar.frameOfTab(parts[0]), let target = tabBar.frameOfTab(parts[1]) {
                didDragTab = true
                let start = tabBar.convert(CGPoint(x: source.midX, y: source.midY), to: nil)
                let end = tabBar.convert(CGPoint(x: target.midX + (parts[1] > parts[0] ? 8 : -8), y: target.midY), to: nil)
                drag(in: window, from: start, to: end, steps: 12)
                let after = tabs()
                FileHandle.standardError.write(Data("tab order after drag: \(after.tabs.map(\.title).joined(separator: ", ")), active \(after.active?.title ?? "")\n".utf8))
            }
        }
        return true
    }

    // MARK: Discarding

    /// `GITBONSAI_CLICK_HUNK_DISCARD=<n>` clicks "Hunk verwerfen" of hunk n in the open diff, `GITBONSAI_HOVER_FILE=<n>` moves the mouse onto file row n,
    /// `GITBONSAI_CLICK_FILE_DISCARD=<n>` also clicks that row's discard button; all with real mouse events through the window.
    static func discard(on tab: RepositoryViewController, attempt: Int = 0) {
        let environment = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = tab.view.window else { return }
            if let index = environment["GITBONSAI_CLICK_HUNK_DISCARD"].flatMap(Int.init) {
                // The diff loads asynchronously; try again until its hunk rows are there.
                if views(of: DiffHunkView.self, in: window).count <= index, attempt < 10 {
                    discard(on: tab, attempt: attempt + 1)
                    return
                }
                let hunks = views(of: DiffHunkView.self, in: window).sorted { $0.convert(CGPoint.zero, to: nil).y > $1.convert(CGPoint.zero, to: nil).y }
                guard hunks.indices.contains(index), !hunks[index].discard.isHidden else {
                    FileHandle.standardError.write(Data("no discard button on hunk \(index) of \(hunks.count)\n".utf8))
                    return
                }
                let button = hunks[index].discard
                click(in: window, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            }
            let rowIndex = environment["GITBONSAI_CLICK_FILE_DISCARD"].flatMap(Int.init) ?? environment["GITBONSAI_HOVER_FILE"].flatMap(Int.init)
            if let rowIndex {
                let rows = views(of: FileRowView.self, in: window)
                guard rows.indices.contains(rowIndex), let discardIndex = rows[rowIndex].model.actions.firstIndex(of: .discard) else {
                    FileHandle.standardError.write(Data("no discard button on file row \(rowIndex) of \(rows.count)\n".utf8))
                    return
                }
                let row = rows[rowIndex]
                let rect = row.actionRect(discardIndex)
                let point = row.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                // Tracking areas follow the real cursor only, so the move goes to the view under the point the way tracking would deliver it.
                if let moved = mouseEvent(.mouseMoved, at: point, in: window) { window.contentView?.superview?.hitTest(point)?.mouseMoved(with: moved) }
                if environment["GITBONSAI_CLICK_FILE_DISCARD"] != nil { click(in: window, at: point) }
            }
        }
    }

    /// The confirmation sheet for discarding. `GITBONSAI_DISCARD_ANSWER=confirm|cancel` clicks its button with real mouse events;
    /// without an answer `GITBONSAI_SHEET_SCREENSHOT=<path>` writes the sheet to a PNG while it is up.
    static func answerDiscardSheet(_ alert: NSAlert) {
        guard outputPath != nil else { return }
        let environment = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let sheet = alert.window
            FileHandle.standardError.write(Data("discard sheet: \(alert.messageText) — \(alert.informativeText)\n".utf8))
            switch environment["GITBONSAI_DISCARD_ANSWER"] {
            case "confirm", "cancel":
                let button = alert.buttons[environment["GITBONSAI_DISCARD_ANSWER"] == "confirm" ? 0 : 1]
                click(in: sheet, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            default:
                guard let path = environment["GITBONSAI_SHEET_SCREENSHOT"], let view = sheet.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
                // The sheet's glass and vibrant text blend with what lies behind them; on an empty bitmap they vanish, so a window background goes underneath.
                sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                view.displayIgnoringOpacity(view.bounds, in: context)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func views<V: NSView>(of type: V.Type, in window: NSWindow) -> [V] {
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
