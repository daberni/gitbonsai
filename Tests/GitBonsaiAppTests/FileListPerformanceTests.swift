import AppKit
import XCTest
import GitEngine
@testable import GitBonsaiApp

/// The detail panel's file list creates views only for the rows on screen, so a huge commit opens and scrolls as fast as a small one.
@MainActor
final class FileListPerformanceTests: XCTestCase {
    private let fileCount = 10_000

    private func models() -> [FileRowView.Model] {
        (0..<fileCount).map { index in
            FileRowView.Model(selection: FileSelection(path: "Sources/Module\(index / 100)/File\(index).swift", originalPath: nil, source: .unstaged), letter: "M", color: Theme.ochre, stat: DiffStat(added: index % 50, removed: index % 7), note: nil, actions: [.stage, .discard], state: .modified)
        }
    }

    /// The list in a scroll view of the detail panel's size, as in the app.
    private func makeScroll() -> (NSScrollView, FileListView) {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        let document = FlippedView(frame: scroll.bounds)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let list = FileListView()
        document.addSubview(list)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalToConstant: 360),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        return (scroll, list)
    }

    private func rowViews(in view: NSView) -> Int {
        view.subviews.reduce(view is FileRowView ? 1 : 0) { $0 + rowViews(in: $1) }
    }

    func testTenThousandFilesShowFirstRowsWithinBudget() {
        let rows = models()
        let (scroll, list) = makeScroll()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            list.show([FileListView.Section(title: "Files", rows: rows, action: nil)])
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
        }
        print("10,000 files, first rows: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertEqual(list.models.count, fileCount)
        XCTAssertGreaterThan(rowViews(in: list), 0)
        XCTAssertLessThan(rowViews(in: list), 100, "only the visible rows have views")
    }

    func testTenThousandFilesScrollWithoutHitch() {
        let (scroll, list) = makeScroll()
        list.show([FileListView.Section(title: "Files", rows: models(), action: nil)])
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()
        let clock = ContinuousClock()
        var slowest = Duration.zero
        // One page at a time from top to bottom; each step must fit well into a frame.
        let step = scroll.contentView.bounds.height
        var y: CGFloat = 0
        let end = list.frame.height - step
        XCTAssertGreaterThan(end, CGFloat(fileCount - 100) * Theme.FileList.rowHeight)
        while y < end {
            y = min(y + step, end)
            let elapsed = clock.measure {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.layoutSubtreeIfNeeded()
                scroll.displayIfNeeded()
            }
            slowest = max(slowest, elapsed)
        }
        print("10,000 files, slowest page scroll: \(slowest)")
        XCTAssertLessThan(slowest, .milliseconds(16))
        XCTAssertLessThan(rowViews(in: list), 150, "scrolled-out rows are reused")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
