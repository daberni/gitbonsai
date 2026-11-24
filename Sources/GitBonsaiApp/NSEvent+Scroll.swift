import AppKit

extension NSEvent {
    /// This scroll event with only its sideways or only its vertical part, so one gesture can move two scrolling views at once.
    func scrollingAxis(_ axis: NSEvent.GestureAxis) -> NSEvent? {
        guard let copy = cgEvent?.copy() else { return nil }
        let cleared: [CGEventField] = axis == .horizontal
            ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]
            : [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]
        for field in cleared {
            copy.setIntegerValueField(field, value: 0)
            copy.setDoubleValueField(field, value: 0)
        }
        return NSEvent(cgEvent: copy)
    }

    /// A nested scroll view takes the sideways part of `event` and hands the vertical part to `outer`; a diagonal gesture moves both.
    static func split(_ event: NSEvent, sideways: (NSEvent) -> Void, vertical: (NSEvent) -> Void) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard dx != 0, dy != 0 else { return dy != 0 ? vertical(event) : sideways(event) }
        if let part = event.scrollingAxis(.horizontal) { sideways(part) }
        if let part = event.scrollingAxis(.vertical) { vertical(part) }
    }
}
