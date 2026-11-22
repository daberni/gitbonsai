import AppKit

private nonisolated(unsafe) var messageKey: UInt8 = 0
private nonisolated(unsafe) var infoKey: UInt8 = 0

private final class RefStringBox {
    let string: RefString
    init(_ string: RefString) { self.string = string }
}

extension NSAlert {
    /// Sets title and message with their names as pills. NSAlert itself only takes plain strings, which it keeps for VoiceOver and the harness;
    /// `applyRefText()` puts the pills into its labels before it is shown.
    func setText(_ message: RefString, info: RefString) {
        messageText = message.plain
        informativeText = info.plain
        objc_setAssociatedObject(self, &messageKey, RefStringBox(message), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(self, &infoKey, RefStringBox(info), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Lays the alert out and replaces the plain title and message in its labels with the pill versions; called right before it is shown or rendered.
    func applyRefText() {
        let message = (objc_getAssociatedObject(self, &messageKey) as? RefStringBox)?.string
        let info = (objc_getAssociatedObject(self, &infoKey) as? RefStringBox)?.string
        guard message?.containsNames == true || info?.containsNames == true else { return }
        layout()
        for field in Self.labels(in: window.contentView) {
            if let message, field.stringValue == message.plain { field.setText(message) }
            else if let info, field.stringValue == info.plain { field.setText(info) }
        }
        // The labels were sized for the plain text; the pills are taller, so the alert measures them again.
        layout()
    }

    private static func labels(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { $0.isEditable ? [] : [$0] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }
}
