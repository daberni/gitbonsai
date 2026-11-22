import AppKit

/// A sheet that asks for the few values of an action: labeled text fields, an optional checkbox and an optional multi-line message.
/// The confirm button stays disabled while a required value is empty.
@MainActor
final class ActionForm: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    struct Values {
        let text: [String: String]
        let isChecked: Bool

        /// The trimmed value of a field, or nil when it was left empty.
        func value(_ key: String) -> String? {
            let trimmed = text[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static let messageKey = "message"
    static let checkboxKey = "checked"

    let alert = NSAlert()
    private let stack = NSStackView()
    private var fields: [(key: String, field: NSTextField, required: Bool)] = []
    private var checkbox: NSButton?
    private var choices: [(key: String, popup: NSPopUpButton, values: [String])] = []
    private var messageView: NSTextView?

    init(title: String, info: String, confirm: String) {
        super.init()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Abbrechen")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.ActionSheet.rowSpacing
        alert.accessoryView = stack
    }

    func addField(key: String, label: String, value: String = "", placeholder: String = "", required: Bool = true) {
        let field = makeField(key: key, value: value, placeholder: placeholder, required: required)
        addRow(label: label, control: field)
    }

    /// A text field that also offers `suggestions` in a list, for a ref that may be typed or picked.
    func addComboField(key: String, label: String, value: String, suggestions: [String], required: Bool = true) {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: suggestions)
        combo.completes = true
        combo.numberOfVisibleItems = Theme.ActionSheet.visibleSuggestions
        configure(combo, key: key, value: value, placeholder: "", required: required)
        addRow(label: label, control: combo)
    }

    /// A pop-up of exclusive options; `values.text[key]` holds the chosen option's value.
    func addChoice(key: String, label: String, options: [(value: String, title: String)], selected: String) {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options.map(\.title))
        popup.selectItem(at: options.firstIndex { $0.value == selected } ?? 0)
        choices.append((key, popup, options.map(\.value)))
        addRow(label: label, control: popup)
    }

    /// A folder field with a button that picks the new folder's place and name in a save panel.
    func addFolderField(key: String, label: String, value: String) {
        let field = makeField(key: key, value: value, placeholder: "", required: true)
        let choose = NSButton(title: "Wählen …", target: self, action: #selector(chooseFolder(_:)))
        choose.identifier = NSUserInterfaceItemIdentifier(key)
        let row = NSStackView(views: [field, choose])
        row.spacing = Theme.ActionSheet.labelSpacing
        addRow(label: label, control: row)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func addCheckbox(_ title: String, checked: Bool) {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = checked ? .on : .off
        checkbox = box
        stack.addArrangedSubview(box)
    }

    func addMessage(label: String, value: String = "") {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = Theme.body
        text.isRichText = false
        text.allowsUndo = true
        text.string = value
        text.delegate = self
        messageView = text
        addRow(label: label, control: scroll)
        scroll.heightAnchor.constraint(equalToConstant: Theme.ActionSheet.messageHeight).isActive = true
        updateConfirm()
    }

    var values: Values {
        var text = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.field.stringValue) })
        if let messageView { text[Self.messageKey] = messageView.string }
        for choice in choices { text[choice.key] = choice.values[max(choice.popup.indexOfSelectedItem, 0)] }
        return Values(text: text, isChecked: checkbox?.state == .on)
    }

    /// Fills the form as a user would; the harness answers sheets this way.
    func fill(_ answers: [String: String]) {
        for (key, field, _) in fields { if let answer = answers[key] { field.stringValue = answer } }
        if let message = answers[Self.messageKey] { messageView?.string = message.replacingOccurrences(of: "\\n", with: "\n") }
        if let checked = answers[Self.checkboxKey] { checkbox?.state = checked == "1" ? .on : .off }
        for choice in choices { if let answer = answers[choice.key], let index = choice.values.firstIndex(of: answer) { choice.popup.selectItem(at: index) } }
        updateConfirm()
    }

    var isComplete: Bool {
        let fieldsComplete = fields.allSatisfy { !$0.required || !$0.field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
        let messageComplete = messageView.map { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        return fieldsComplete && messageComplete
    }

    /// Sizes the accessory to its content and lays the alert out; called before the sheet is shown or rendered.
    func prepare() {
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.layout()
        alert.window.initialFirstResponder = fields.first?.field
    }

    func controlTextDidChange(_ notification: Notification) { updateConfirm() }
    func textDidChange(_ notification: Notification) { updateConfirm() }

    /// A focused field gets Esc and Return before the alert's key equivalents, so the form presses the buttons itself: Esc cancels with the text kept as typed, Return in a single-line field confirms.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let confirm = alert.buttons.first, confirm.isEnabled {
            confirm.performClick(nil)
            return true
        }
        return cancels(commandSelector)
    }

    /// The multi-line message keeps Return for new lines.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        cancels(commandSelector)
    }

    private func cancels(_ commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let cancel = alert.cancelButton else { return false }
        cancel.performClick(nil)
        return true
    }

    private func updateConfirm() {
        alert.buttons.first?.isEnabled = isComplete
    }

    private func makeField(key: String, value: String, placeholder: String, required: Bool) -> NSTextField {
        let field = NSTextField()
        configure(field, key: key, value: value, placeholder: placeholder, required: required)
        return field
    }

    private func configure(_ field: NSTextField, key: String, value: String, placeholder: String, required: Bool) {
        field.stringValue = value
        field.placeholderString = placeholder
        field.delegate = self
        fields.append((key, field, required))
        updateConfirm()
    }

    private func addRow(label: String, control: NSView) {
        let caption = NSTextField(labelWithString: label)
        caption.font = Theme.caption
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [caption, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Theme.ActionSheet.labelSpacing
        control.widthAnchor.constraint(equalToConstant: Theme.ActionSheet.fieldWidth).isActive = true
        stack.addArrangedSubview(row)
    }

    @objc private func chooseFolder(_ sender: NSButton) {
        guard let field = fields.first(where: { $0.key == sender.identifier?.rawValue })?.field else { return }
        let current = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath)
        let panel = NSSavePanel()
        panel.title = "Ordner für den Worktree"
        panel.prompt = "Wählen"
        panel.canCreateDirectories = true
        panel.directoryURL = current.deletingLastPathComponent()
        panel.nameFieldStringValue = current.lastPathComponent
        panel.beginSheetModal(for: alert.window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            field.stringValue = url.path
            self?.updateConfirm()
        }
    }
}
