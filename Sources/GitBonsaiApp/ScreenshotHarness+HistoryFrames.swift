import AppKit
import GitEngine
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

    /// `GITBONSAI_CHECK_ORDER=1` compares the shown commits with a fresh `git log` over the same starting points after loading and after each delay of `GITBONSAI_PRINT_HISTORY`, and prints the first commit where they differ.
    static func checkHistoryOrder(of tab: RepositoryViewController, when: String) {
        guard environment["GITBONSAI_CHECK_ORDER"] == "1" else { return }
        let viewModel = tab.viewModel
        let shown = viewModel.commits.filter { $0.id != GraphViewModel.wipID }.map(\.id)
        // The row views draw what they were last given; a table update that misses a row leaves it drawing another commit than the model has there.
        let table = tab.history.tableView
        var stale: [String] = []
        for row in 0..<table.numberOfRows {
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? GraphRowView, let drawn = view.model?.commit.id else { continue }
            let expected = viewModel.commits.indices.contains(row) ? viewModel.commits[row].id : "none"
            if drawn != expected { stale.append("row \(row) draws \(drawn.prefix(7)), model \(expected.prefix(7))") }
        }
        FileHandle.standardError.write(Data("order \(when): table \(table.numberOfRows) rows, model \(viewModel.commits.count); \(stale.isEmpty ? "every row view draws its model's commit" : stale.prefix(8).joined(separator: "; "))\n".utf8))
        Task {
            var options = LogOptions()
            options.extraArguments = viewModel.stashesByCommit.keys.sorted()
            var expected: [String] = []
            do {
                for try await commit in viewModel.repository.log(options) { expected.append(commit.id) }
            } catch {
                FileHandle.standardError.write(Data("order \(when): git log failed: \(error)\n".utf8))
                return
            }
            // Helper commits of stashes are hidden in the history; they count as not shown.
            let shownSet = Set(shown)
            let gitOrder = expected.filter { shownSet.contains($0) }
            let missing = expected.count - gitOrder.count
            guard let index = zip(shown, gitOrder).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else {
                FileHandle.standardError.write(Data("order \(when): \(shown.count) shown commits in git's order, \(missing) of git's not shown\n".utf8))
                return
            }
            let gitPosition = gitOrder.firstIndex(of: shown[index]) ?? -1
            FileHandle.standardError.write(Data("order \(when): differs at row \(index): shown \(shown[index].prefix(9)), git \(gitOrder[index].prefix(9)); git has the shown one at \(gitPosition); \(missing) of git's not shown\n".utf8))
        }
    }
}
