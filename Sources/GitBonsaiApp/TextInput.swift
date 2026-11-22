import AppKit

/// The app's one-line text field: a `FieldBox` with a borderless `PlainTextField`, the commit form's style.
/// An optional accessory, such as a folder button, sits inside the box on the right; the box turns persimmon while `isInvalid`.
final class TextInput: NSView, NSTextFieldDelegate {
    private typealias T = Theme.TextField

    let field = PlainTextField()
    private let box = FieldBox()
    private var accessory: NSView?

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
        var constraints = [
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: T.height),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: T.inset.width),
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
final class FieldIconButton: NSButton {
    init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.TextField.accessorySymbol, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = Theme.inkMuted
        toolTip = label
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { nil }
}
