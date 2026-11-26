import AppKit
import GitEngine

/// A sheet that asks for the few values of an action: labeled text fields, an optional checkbox and an optional multi-line message.
/// The confirm button stays disabled while a required value is empty.
@MainActor
final class ActionForm: NSObject, NSTextViewDelegate {
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
    private var fields: [(key: String, field: TextInput, required: Bool)] = []
    private var checkbox: NSButton?
    private var pickers: [(key: String, picker: RefPicker, catalog: RefCatalog)] = []
    private var choices: [(key: String, popup: NSPopUpButton, values: [String])] = []
    private var messageView: NSTextView?
    private var messageArea: TextArea?
    private var messageHeight: NSLayoutConstraint?

    /// With `names`, the title stays short and the names show as full pills above `info`, as in a confirmation.
    init(title: LocalizedStringResource, names: RefString? = nil, info: LocalizedStringResource? = nil, confirm: LocalizedStringResource) {
        super.init()
        if names == nil { alert.setText(RefString(title), info: info.map(RefString.init) ?? RefString(verbatim: "")) }
        alert.addButton(withTitle: confirm.text)
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.ActionSheet.rowSpacing
        alert.accessoryView = stack
        if let names {
            alert.messageText = RefString(title).plain
            stack.addArrangedSubview(ConfirmationBody(names: names, info: info.map(RefString.init) ?? RefString(verbatim: "")))
        }
    }

    /// `placeholder` is example input such as `feature/…`, shown as it is.
    func addField(key: String, label: LocalizedStringResource, value: String = "", placeholder: String = "", required: Bool = true) {
        let field = makeField(key: key, value: value, placeholder: placeholder, required: required)
        addRow(label: label, control: field)
    }

    /// A `RefPicker` over `catalog`; `values.text[key]` holds the chosen item's revision, empty when nothing is chosen.
    func addRefPicker(key: String, label: LocalizedStringResource, repository: Repository, catalog: RefCatalog, selection: RefCatalog.Item?) {
        let picker = RefPicker(repository: repository)
        picker.setCatalog(catalog, selection: selection)
        picker.onChange = { [weak self] _ in self?.updateConfirm() }
        picker.button.setAccessibilityIdentifier("actionForm.\(key)")
        pickers.append((key, picker, catalog))
        addRow(label: label, control: picker.button)
    }

    /// A pop-up of exclusive options; `values.text[key]` holds the chosen option's value.
    func addChoice(key: String, label: LocalizedStringResource, options: [(value: String, title: LocalizedStringResource)], selected: String) {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options.map(\.title.text))
        popup.selectItem(at: options.firstIndex { $0.value == selected } ?? 0)
        choices.append((key, popup, options.map(\.value)))
        addRow(label: label, control: popup)
    }

    /// A folder field with a button that picks the new folder's place and name in a save panel.
    func addFolderField(key: String, label: LocalizedStringResource, value: String) {
        let choose = FieldIconButton(symbol: "folder", label: String(localized: "common.chooseEllipsis", defaultValue: "Choose …", bundle: .module), target: self, action: #selector(chooseFolder(_:)))
        choose.identifier = NSUserInterfaceItemIdentifier(key)
        let field = makeField(key: key, value: value, placeholder: "", required: true, accessory: choose)
        addRow(label: label, control: field)
    }

    func addCheckbox(_ title: LocalizedStringResource, checked: Bool) {
        let title = RefString(title)
        let box = NSButton(checkboxWithTitle: title.plain, target: nil, action: nil)
        if title.containsNames, let font = box.font { box.attributedTitle = RefText.attributed(title, font: font, color: Theme.ink) }
        box.state = checked ? .on : .off
        checkbox = box
        stack.addArrangedSubview(box)
    }

    func addMessage(label: LocalizedStringResource, value: String = "") {
        let area = TextArea()
        area.textView.string = value
        area.textView.delegate = self
        messageView = area.textView
        messageArea = area
        addRow(label: label, control: area)
        let height = area.heightAnchor.constraint(equalToConstant: Theme.ActionSheet.messageMinHeight)
        height.isActive = true
        messageHeight = height
        updateConfirm()
    }

    var values: Values {
        var text = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.field.stringValue) })
        if let messageView { text[Self.messageKey] = messageView.string }
        for choice in choices { text[choice.key] = choice.values[max(choice.popup.indexOfSelectedItem, 0)] }
        for (key, picker, _) in pickers { text[key] = picker.selection?.revision ?? "" }
        return Values(text: text, isChecked: checkbox?.state == .on)
    }

    /// Fills the form as a user would.
    func fill(_ answers: [String: String]) {
        for (key, field, _) in fields { if let answer = answers[key] { field.stringValue = answer } }
        if let message = answers[Self.messageKey] { messageView?.string = message.replacingOccurrences(of: "\\n", with: "\n") }
        fitMessage()
        if let checked = answers[Self.checkboxKey] { checkbox?.state = checked == "1" ? .on : .off }
        for choice in choices { if let answer = answers[choice.key], let index = choice.values.firstIndex(of: answer) { choice.popup.selectItem(at: index) } }
        for (key, picker, catalog) in pickers { if let answer = answers[key] { picker.setCatalog(catalog, selection: catalog.item(titled: answer)) } }
        updateConfirm()
    }

    var isComplete: Bool {
        let fieldsComplete = fields.allSatisfy { !$0.required || !$0.field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
        let messageComplete = messageView.map { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        return fieldsComplete && messageComplete
    }

    /// Sizes the accessory to its content and lays the alert out; called before the sheet is shown or rendered.
    func prepare() {
        fitMessage()
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.layout()
        alert.window.initialFirstResponder = fields.first?.field.field ?? messageView
        // A long message opens at its first line, not wherever the text system scrolled while it was filled in.
        messageView?.setSelectedRange(NSRange(location: 0, length: 0))
        messageArea?.scrollToTop()
        // Showing the sheet lays the alert out once more and moves the clip view; scroll back once it is up.
        DispatchQueue.main.async { [weak self] in self?.messageArea?.scrollToTop() }
    }

    func textDidChange(_ notification: Notification) {
        updateConfirm()
        if fitMessage() { alert.layout() }
    }

    /// Lets the message box follow its text between its minimum and maximum height; true when the height changed.
    @discardableResult
    private func fitMessage() -> Bool {
        guard let area = messageArea, let height = messageHeight else { return false }
        let wanted = min(max(area.contentHeight(width: Theme.ActionSheet.fieldWidth), Theme.ActionSheet.messageMinHeight), Theme.ActionSheet.messageMaxHeight)
        guard wanted != height.constant else { return false }
        height.constant = wanted
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        return true
    }

    /// A focused field gets Esc and Return before the alert's key equivalents, so the form presses the buttons itself: Esc cancels with the text kept as typed, Return in a single-line field confirms.
    private func fieldCommand(_ commandSelector: Selector) -> Bool {
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

    private func makeField(key: String, value: String, placeholder: String, required: Bool, accessory: NSView? = nil) -> TextInput {
        let field = TextInput(placeholder: placeholder, accessory: accessory)
        field.stringValue = value
        field.onChange = { [weak self] _ in self?.updateConfirm() }
        field.onCommand = { [weak self] command in self?.fieldCommand(command) ?? false }
        field.setAccessibilityIdentifier("actionForm.\(key)")
        fields.append((key, field, required))
        updateConfirm()
        return field
    }

    private func addRow(label: LocalizedStringResource, control: NSView) {
        stack.addArrangedSubview(SheetSupport.captionRow(label, control: control, width: Theme.ActionSheet.fieldWidth))
    }

    @objc private func chooseFolder(_ sender: NSButton) {
        guard let field = fields.first(where: { $0.key == sender.identifier?.rawValue })?.field else { return }
        let current = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath)
        let title = String(localized: "worktree.folderPanel.title", defaultValue: "Folder for the Worktree", bundle: .module)
        SheetSupport.chooseFolder(title: title, directory: current.deletingLastPathComponent(), name: current.lastPathComponent, on: alert.window) { [weak self] url in
            field.stringValue = url.path
            self?.updateConfirm()
        }
    }
}
