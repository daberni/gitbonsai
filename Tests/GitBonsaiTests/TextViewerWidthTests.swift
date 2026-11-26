import AppKit
import TextViewerModel
import XCTest
@testable import GitBonsai

@MainActor
final class TextViewerWidthTests: XCTestCase {
    /// CodeEditTextView 0.12.1 never records its widest line; without the viewer's own measure the text stays as wide as the view and cannot scroll sideways.
    func testLongLinesMakeTheTextScrollSideways() throws {
        let viewer = TextViewer()
        let window = Snapshot.window(for: viewer, size: CGSize(width: 500, height: 300), appearance: .aqua)
        defer { window.close() }
        viewer.show(.init(document: TextDocument(lines: ["short", String(repeating: "x", count: 300)]), language: nil))
        viewer.layoutSubtreeIfNeeded()
        viewer.textView.updateFrameIfNeeded()
        XCTAssertGreaterThan(viewer.textView.frame.width, viewer.scroll.contentView.bounds.width * 3)
        viewer.scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        XCTAssertEqual(viewer.scroll.contentView.bounds.minX, 200)
    }
}
