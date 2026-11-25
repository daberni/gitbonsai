import AppKit
import XCTest
import GitEngine
@testable import GitBonsai

/// The detail panel's file list creates views only for the rows on screen, so a huge commit opens as fast as a small one; the `files.10k.firstRows` benchmark measures how fast.
@MainActor
final class FileListViewTests: XCTestCase {
    func testTenThousandFilesCreateViewsOnlyForVisibleRows() {
        let fileCount = 10_000
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
        let rows = (0..<fileCount).map { index in
            FileRowView.Model(selection: FileSelection(path: "Sources/File\(index).swift", originalPath: nil, source: .unstaged), letter: "M", color: Theme.ochre, stat: DiffStat(added: 1, removed: 0), note: nil)
        }
        list.show([FileListView.Section(title: "Files", rows: rows)])
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()
        XCTAssertEqual(list.models.count, fileCount)
        XCTAssertGreaterThan(rowViews(in: list), 0)
        XCTAssertLessThan(rowViews(in: list), 100, "only the visible rows have views")
    }

    private func rowViews(in view: NSView) -> Int {
        view.subviews.reduce(view is FileRowView ? 1 : 0) { $0 + rowViews(in: $1) }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
