import AppKit

/// The macOS convention for the pointer: things that look like links or bare clickable text and icons show the pointing hand,
/// bordered buttons, toolbar buttons, segmented controls, menus and table rows keep the arrow.
/// Views follow it through a `.cursorUpdate` tracking area and `set(overLink:)`, so every link-like part uses this one path.
@MainActor
enum LinkCursor {
    /// Asks `owner` for its cursor whenever the pointer enters it; add it in `updateTrackingAreas`.
    static func trackingArea(for owner: NSView) -> NSTrackingArea {
        NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: owner)
    }

    static func set(overLink: Bool) {
        (overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
}

/// A borderless button that reads as a link or a bare icon: underlined SHAs, "Stage all", the copy icon.
final class LinkButton: NSButton {
    private var cursorArea: NSTrackingArea?

    convenience init(target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = LinkCursor.trackingArea(for: self)
        addTrackingArea(area)
        cursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) { LinkCursor.set(overLink: true) }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        LinkCursor.set(overLink: false)
    }
}
