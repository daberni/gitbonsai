import AppKit

/// Hover under overlays: whether the history's column boundaries still react while something lies over them.
extension ScreenshotHarness {
    /// `GITBONSAI_COVERED_HOVER=1` moves onto the graph boundary of the first row the way AppKit's tracking areas deliver it, to every view that tracks the point whatever lies above,
    /// first uncovered, then with the command bar open over the history, and prints after each whether the guide line shows and which cursor is set.
    static func driveCoveredHover(on tab: RepositoryViewController) {
        guard environment["GITBONSAI_COVERED_HOVER"] == "1" else { return }
        let table = tab.history.tableView
        func trackingMove(_ step: String) {
            guard let window = table.window, let root = window.contentView else { return }
            let boundary = tab.history.columnsController.columns.layout(in: table.bounds.width).dividers.first { $0.0 == .graph }?.1 ?? 0
            let location = table.convert(NSPoint(x: boundary, y: table.rect(ofRow: 0).midY), to: nil)
            guard let event = mouseEvent(.mouseMoved, at: location, in: window) else { return }
            var trackers: [NSView] = []
            func collect(_ view: NSView) {
                if view is ColumnGuideView || view is HistoryTableView || view is HistoryHeaderView, view.convert(view.bounds, to: nil).contains(location) { trackers.append(view) }
                view.subviews.forEach(collect)
            }
            collect(root)
            trackers.forEach { $0.mouseMoved(with: event) }
            let guide = trackers.compactMap { $0 as? ColumnGuideView }.first
            let cursor = NSCursor.current == NSCursor.resizeLeftRight ? "resize" : "arrow"
            FileHandle.standardError.write(Data("covered hover \(step): guide \(guide?.hovered.map { "boundary \($0)" } ?? "hidden"), cursor \(cursor), ref pills \(tab.history.refOverlay.shownRow.map { "row \($0)" } ?? "collapsed")\n".utf8))
        }
        let release = hold()
        after(0.5) {
            trackingMove("uncovered")
            guard let window = table.window else { return release() }
            tab.context.commandBar.open(in: window, commands: [])
            after(0.5) {
                trackingMove("under the command bar")
                tab.context.commandBar.close()
                after(0.3) {
                    trackingMove("after closing")
                    release()
                }
            }
        }
    }

    /// `GITBONSAI_PRINT_FETCH_STATE=<seconds>,…` prints the toolbar's fetch state after each delay, with `[spinner]` while it turns.
    static func printFetchState(of tab: RepositoryViewController) {
        guard let delays = environment["GITBONSAI_PRINT_FETCH_STATE"]?.split(separator: ",").compactMap({ Double($0) }) else { return }
        for delay in delays {
            after(delay) { FileHandle.standardError.write(Data("fetch state after \(delay)s: \(tab.toolbar.fetchStateText)\n".utf8)) }
        }
    }
}
