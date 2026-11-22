import AppKit
import GraphLayout

/// Harness switch that traces the history table frame by frame, to see whether a refresh ever shows an empty, partial or shifted table.
@MainActor
extension ScreenshotHarness {
    /// What one turn of the main run loop leaves on screen in the history.
    private struct HistoryFrame: Equatable {
        var rowCount: Int
        var visible: Range<Int>
        var scrollY: Int
        var selected: String
        /// Commit and graph row of every visible row, so a row drawn differently with the same commit shows up.
        var rows: [GraphRow]
    }

    private nonisolated(unsafe) static var frameTraceStart: ContinuousClock.Instant?
    private nonisolated(unsafe) static var lastHistoryFrame: HistoryFrame?
    /// The graph row each commit last showed on screen, to tell a row that draws differently from one that only moved.
    private nonisolated(unsafe) static var shownGraphRows: [String: GraphRow] = [:]

    /// `GITBONSAI_FRAME_TRACE=1` prints the history table on every turn of the main run loop in which it changed (row count, visible rows, scroll position, selection, and which visible rows changed their commit or graph row),
    /// plus every whole-table reload and every row insertion or removal, each with the milliseconds since the trace began.
    static func traceHistoryFrames(on tab: RepositoryViewController) {
        guard environment["GITBONSAI_FRAME_TRACE"] == "1", frameTraceStart == nil else { return }
        frameTraceStart = .now
        let history = tab.history
        let viewModel = tab.viewModel
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                let table = history.tableView
                let range = table.rows(in: table.visibleRect)
                let visible = range.location..<(range.location + range.length)
                let rows = visible.filter { viewModel.rows.indices.contains($0) }.map { viewModel.rows[$0] }
                let selected = history.selectedID.map { "\(history.selectedRow) \($0.prefix(7))" } ?? "none"
                let frame = HistoryFrame(rowCount: table.numberOfRows, visible: visible, scrollY: Int(table.visibleRect.minY), selected: selected, rows: rows)
                guard frame != lastHistoryFrame else { return }
                defer { lastHistoryFrame = frame }
                var line = "frame: \(frame.rowCount) rows, visible \(frame.visible.lowerBound)..<\(frame.visible.upperBound), scroll y \(frame.scrollY), selected \(frame.selected)"
                if let last = lastHistoryFrame {
                    let moved = zip(last.rows, frame.rows).filter { $0.commitID != $1.commitID }.count
                    let redrawn = frame.rows.filter { row in shownGraphRows[row.commitID].map { $0 != row } ?? false }.map { String($0.commitID.prefix(7)) }
                    let added = frame.rows.filter { shownGraphRows[$0.commitID] == nil }.count
                    line += ", \(moved) visible rows show another commit, \(added) never on screen before, graph changed in \(redrawn.isEmpty ? "none" : redrawn.joined(separator: " "))"
                }
                for row in frame.rows { shownGraphRows[row.commitID] = row }
                traceHistory(line)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// One line of the frame trace; nothing without `GITBONSAI_FRAME_TRACE`.
    static func traceHistory(_ event: @autoclosure () -> String) {
        guard let start = frameTraceStart else { return }
        let duration = start.duration(to: .now)
        let milliseconds = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        FileHandle.standardError.write(Data("history +\(milliseconds) ms \(event())\n".utf8))
    }
}
