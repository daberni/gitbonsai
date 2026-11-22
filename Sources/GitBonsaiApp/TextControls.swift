import AppKit

/// A rounded field background in `surface-2` with a hairline border that turns moss while its field has focus, and persimmon while its value is invalid.
final class FieldBox: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    var isInvalid = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        typealias C = Theme.Control
        let inset = (isFocused ? C.focusWidth : Theme.Stroke.hairline) / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: C.radius, yRadius: C.radius)
        Theme.surface2.setFill()
        path.fill()
        (isInvalid ? Theme.persimmon : isFocused ? Theme.moss : Theme.hairline).setStroke()
        path.lineWidth = isFocused ? C.focusWidth : Theme.Stroke.hairline
        path.stroke()
    }
}

/// A one-line text field without its own border, meant to sit in a `FieldBox`.
final class PlainTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = Theme.body
        textColor = Theme.ink
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
    }

    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    /// Tab without another key view ends editing and AppKit edits the same field again without `becomeFirstResponder`, so the focus follows the field editor.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(currentEditor() != nil)
    }
}

/// A multi-line text view without border or focus ring, with a placeholder, meant to sit in a `FieldBox`.
final class PlainTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        NSAttributedString(string: placeholder, attributes: [.font: font ?? Theme.body, .foregroundColor: Theme.inkFaint]).draw(at: origin)
    }
}
