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

/// A drawn control that takes the keyboard focus like its system counterpart: while enabled and only with full keyboard access (System Settings → Keyboard → Keyboard navigation), and Space presses it.
class KeyboardControl: NSControl {
    static var isFullKeyboardAccess: Bool { NSApp.isFullKeyboardAccessEnabled || ScreenshotHarness.simulatesFullKeyboardAccess }

    override var acceptsFirstResponder: Bool { isEnabled && Self.isFullKeyboardAccess }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    /// Whether it draws its focus, in the app's moss like a focused `FieldBox`.
    var showsFocus: Bool { window?.firstResponder === self }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if moveFocus(for: event) { return }
        guard event.keyCode == 49, isEnabled else { return super.keyDown(with: event) }
        performClick(nil)
    }
}

/// A control that draws its keyboard focus itself instead of the system focus ring.
@MainActor
protocol DrawsOwnFocus: NSView {
    var showsFocus: Bool { get }
}

extension KeyboardControl: DrawsOwnFocus {}

extension NSView {
    /// Tab and ⇧Tab move along the key view loop; a control that does not edit text has to ask for that itself. True when `event` was one of them.
    func moveFocus(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 48, modifiers.subtracting(.shift).isEmpty, let window else { return false }
        if modifiers.contains(.shift) { window.selectPreviousKeyView(self) } else { window.selectNextKeyView(self) }
        return true
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
final class PrimaryButton: KeyboardControl {
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
        // The fill is moss already, so the focus is a ring in the text's color, a focus width inside the edge.
        if showsFocus {
            let inset = Theme.Control.focusWidth * 1.5
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: Theme.Control.radius - inset / 2, yRadius: Theme.Control.radius - inset / 2)
            ring.lineWidth = Theme.Control.focusWidth
            Theme.onMoss.setStroke()
            ring.stroke()
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

/// The quiet button beside `PrimaryButton`, such as Cancel: `surface-2` with a hairline and ink text, persimmon for a destructive choice.
final class SecondaryButton: KeyboardControl {
    let title: String
    var tint = Theme.ink { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Theme.body, .foregroundColor: tint])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: attributedTitle.size().width + 2 * Theme.Control.padding, height: Theme.Control.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focus = showsFocus
        let width = focus ? Theme.Control.focusWidth : Theme.Stroke.hairline
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: Theme.Control.radius, yRadius: Theme.Control.radius)
        (isPressed ? Theme.surface2.blended(withFraction: Theme.Wash.pressed, of: Theme.ink) ?? Theme.surface2 : Theme.surface2).setFill()
        path.fill()
        (focus ? Theme.moss : Theme.hairline).setStroke()
        path.lineWidth = width
        path.stroke()
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

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}

/// A label followed by a rounded box that fills with moss and a check when on; a moss ring around the box shows the keyboard focus.
final class LabeledCheckbox: KeyboardControl {
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
        return NSSize(width: attributedTitle.size().width + C.labelGap + C.checkbox + Self.ringRoom, height: C.height)
    }

    /// The focus ring sits a focus width outside the box and is a focus width wide.
    private static let ringRoom = 2 * Theme.Control.focusWidth

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        typealias C = Theme.Control
        let text = attributedTitle
        text.draw(at: CGPoint(x: 0, y: bounds.midY - text.size().height / 2))
        let box = CGRect(x: bounds.maxX - Self.ringRoom - C.checkbox, y: bounds.midY - C.checkbox / 2, width: C.checkbox, height: C.checkbox)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: C.checkboxRadius, yRadius: C.checkboxRadius)
        (isOn ? Theme.moss : Theme.surface2).setFill()
        path.fill()
        (isOn ? Theme.moss : Theme.hairline).setStroke()
        path.stroke()
        if isOn { Glyph.check.draw(in: box.insetBy(dx: Theme.Stroke.icon * 2, dy: Theme.Stroke.icon * 2), color: Theme.onMoss, context: context) }
        guard showsFocus else { return }
        let outset = Self.ringRoom - C.focusWidth / 2
        let ring = NSBezierPath(roundedRect: box.insetBy(dx: -outset, dy: -outset), xRadius: C.checkboxRadius + outset, yRadius: C.checkboxRadius + outset)
        ring.lineWidth = C.focusWidth
        Theme.moss.setStroke()
        ring.stroke()
    }

    /// Like a system checkbox, a click toggles it also while its window is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }
}
