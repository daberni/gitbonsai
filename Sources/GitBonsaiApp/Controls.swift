import AppKit

/// A rounded field background in `surface-2` with a hairline border that turns moss while its field has focus.
final class FieldBox: NSView {
    var isFocused = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        typealias C = Theme.Control
        let inset = (isFocused ? C.focusWidth : Theme.Stroke.hairline) / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: C.radius, yRadius: C.radius)
        Theme.surface2.setFill()
        path.fill()
        (isFocused ? Theme.moss : Theme.hairline).setStroke()
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

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
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

/// The main action of a form: moss with dark text, faint when it cannot be used.
final class PrimaryButton: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Pressing ⌘⏎ anywhere in the window runs it.
    var respondsToCommandReturn = false
    private var isPressed = false { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Theme.bodyStrong, .foregroundColor: isEnabled ? Theme.onMoss : Theme.inkFaint])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: attributedTitle.size().width + 2 * Theme.Control.padding, height: Theme.Control.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.Control.radius, yRadius: Theme.Control.radius)
        let fill = isEnabled ? Theme.moss : Theme.surface2
        (isPressed ? fill.blended(withFraction: Theme.Wash.pressed, of: .black) ?? fill : fill).setFill()
        path.fill()
        if !isEnabled {
            Theme.hairline.setStroke()
            path.stroke()
        }
        let text = attributedTitle
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                isPressed = false
                if inside { sendAction(action, to: target) }
                return
            }
            isPressed = inside
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandReturn = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.keyCode == 36
        guard respondsToCommandReturn, isCommandReturn, isEnabled, !isHiddenOrHasHiddenAncestor else { return super.performKeyEquivalent(with: event) }
        sendAction(action, to: target)
        return true
    }

    /// Runs the action as a click would, for the screenshot harness.
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}

/// A label followed by a rounded box that fills with moss and a check when on.
final class LabeledCheckbox: NSControl {
    var isOn = false { didSet { needsDisplay = true } }
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Theme.body, .foregroundColor: Theme.ink])
    }

    override var intrinsicContentSize: NSSize {
        typealias C = Theme.Control
        return NSSize(width: attributedTitle.size().width + C.labelGap + C.checkbox, height: C.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        typealias C = Theme.Control
        let text = attributedTitle
        text.draw(at: CGPoint(x: 0, y: bounds.midY - text.size().height / 2))
        let box = CGRect(x: bounds.maxX - C.checkbox, y: bounds.midY - C.checkbox / 2, width: C.checkbox, height: C.checkbox)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: C.checkboxRadius, yRadius: C.checkboxRadius)
        (isOn ? Theme.moss : Theme.surface2).setFill()
        path.fill()
        (isOn ? Theme.moss : Theme.hairline).setStroke()
        path.stroke()
        if isOn { Glyph.check.draw(in: box.insetBy(dx: Theme.Stroke.icon * 2, dy: Theme.Stroke.icon * 2), color: Theme.onMoss, context: context) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func performClick(_ sender: Any?) {
        isOn.toggle()
        sendAction(action, to: target)
    }
}
