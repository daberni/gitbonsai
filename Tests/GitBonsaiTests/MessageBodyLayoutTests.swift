import AppKit
import XCTest
@testable import GitBonsai

/// A message that wraps to one more line once a legacy scroller takes its width must still settle on one height; a launch with such a message selected crashed with AppKit's "more Layout Window passes than there are views" exception.
@MainActor
final class MessageBodyLayoutTests: XCTestCase {
    func testHeightSettlesWhenScrollerWidthChangesTheWrap() throws {
        let message = (1...40).map { "word\($0)" }.joined(separator: " ")
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let width = try XCTUnwrap(stride(from: CGFloat(200), through: 500, by: 1).first { height(of: message, width: $0) < height(of: message, width: $0 - scroller) && height(of: message, width: $0) < Theme.MessageEditor.bodyMaximumHeight })
        let body = MessageBodyView(message)
        body.scrollerStyle = .legacy
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.layoutIfNeeded()
        let settled = body.frame.height
        XCTAssertEqual(settled, height(of: message, width: width))
        window.layoutIfNeeded()
        XCTAssertEqual(body.frame.height, settled)
    }

    private func height(of string: String, width: CGFloat) -> CGFloat {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        text.string = string
        text.font = Theme.body
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        return ceil(text.layoutManager!.usedRect(for: text.textContainer!).height)
    }
}
