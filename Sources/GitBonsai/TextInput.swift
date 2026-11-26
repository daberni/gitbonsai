import AppKit

/// The app's one-line text field: a `FieldBox` with a borderless `PlainTextField`, the commit form's style.
/// An optional accessory, such as a folder button, sits inside the box on the right; the box turns persimmon while `isInvalid`.
final class TextInput: NSView, NSTextFieldDelegate, DrawsOwnFocus {
    private typealias T = Theme.TextField

    let field = PlainTextField()
    private let box = FieldBox()
    private(set) var accessory: NSView?
    private var fieldLeading: NSLayoutConstraint!

    /// A view inside the box before the text, such as the command bar's mode; nil gives the text the whole box.
    var leadingAddon: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            fieldLeading.isActive = false
            if let addon = leadingAddon {
                addon.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(addon)
                fieldLeading = field.leadingAnchor.constraint(equalTo: addon.trailingAnchor, constant: T.accessoryGap)
                NSLayoutConstraint.activate([
                    addon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: T.addonInset),
                    addon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                    fieldLeading,
                ])
            } else {
                fieldLeading = field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: T.inset.width)
                fieldLeading.isActive = true
            }
        }
    }

    /// Every edit, with the new text.
    var onChange: ((String) -> Void)?
    /// Commands of the field editor such as `insertNewline:`, `cancelOperation:`, `moveUp:` and `moveDown:`; true when handled.
    var onCommand: ((Selector) -> Bool)?

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { field.placeholderString = newValue }
    }

    var font: NSFont? {
        get { field.font }
        set { field.font = newValue }
    }

    /// Whether the box draws its focus border.
    var showsFocus: Bool { box.isFocused }

    var isInvalid: Bool {
        get { box.isInvalid }
        set { box.isInvalid = newValue }
    }

    /// An accessory such as a counter can ask for its own `accessoryWidth`; icons take the standard square.
    init(placeholder: String = "", accessory: NSView? = nil, accessoryWidth: CGFloat? = nil) {
        self.accessory = accessory
        super.init(frame: .zero)
        field.placeholderString = placeholder
        field.delegate = self
        field.onFocusChange = { [weak self] focused in self?.box.isFocused = focused }
        box.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(field)
        fieldLeading = field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: T.inset.width)
        // Just below required, so a container can collapse a hidden field to zero height.
        let height = heightAnchor.constraint(equalToConstant: T.height)
        height.priority = .required - 1
        var constraints = [
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
            fieldLeading!,
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -T.inset.width + T.accessoryGap),
                accessory.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                accessory.widthAnchor.constraint(equalToConstant: accessoryWidth ?? T.accessory + T.accessoryGap),
                field.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -T.accessoryGap),
            ]
            if accessoryWidth == nil { constraints.append(accessory.heightAnchor.constraint(equalToConstant: T.accessory + T.accessoryGap)) }
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -T.inset.width))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks anywhere in the box, also beside the text, edit the field.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }
}

/// A borderless icon button for the accessory of a `TextInput`, such as the folder picker.
/// It follows the field in the key view loop with full keyboard access and shows its focus in moss, like the field.
final class FieldIconButton: NSButton, DrawsOwnFocus {
    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.TextField.accessorySymbol, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = Theme.inkMuted
        toolTip = label
        focusRingType = .none
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled && KeyboardControl.isFullKeyboardAccess }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    var showsFocus: Bool { window?.firstResponder === self }

    override func keyDown(with event: NSEvent) {
        if !moveFocus(for: event) { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsFocus else { return }
        let width = Theme.Control.focusWidth
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: Theme.Control.radius, yRadius: Theme.Control.radius)
        ring.lineWidth = width
        Theme.moss.setStroke()
        ring.stroke()
    }
}

/// The multi-line counterpart of `TextInput`: a `FieldBox` with a borderless, scrolling `PlainTextView`, the commit form body's style.
final class TextArea: NSView {
    let textView = PlainTextView()
    private let box = FieldBox()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        textView.font = Theme.body
        textView.textColor = Theme.ink
        textView.insertionPointColor = Theme.ink
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: Theme.TextField.inset.width - Theme.Control.focusWidth, height: Theme.TextField.inset.height)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.focusRingType = .none
        textView.onFocusChange = { [weak self] focused in self?.box.isFocused = focused }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // In a sheet the window's safe area would add a top content inset that scrolls the first line under the border.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        for view in [box, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(box)
        box.addSubview(scroll)
        let inset = Theme.Control.focusWidth
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The height that shows all of the text at `width`, insets and border included.
    func contentHeight(width: CGFloat) -> CGFloat {
        let font = textView.font ?? Theme.body
        let border = Theme.Control.focusWidth
        let inset = textView.textContainerInset
        let textWidth = width - 2 * border - 2 * inset.width
        let text = NSAttributedString(string: textView.string.isEmpty ? " " : textView.string, attributes: [.font: font])
        let bounds = text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height + 2 * inset.height + 2 * border)
    }

    func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Clicks anywhere in the box edit the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}
