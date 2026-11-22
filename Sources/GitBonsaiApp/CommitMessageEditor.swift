import AppKit

/// The commit header of the detail panel while its message is edited in place: subject and body in the commit form's style, Sichern and Abbrechen right under them, and one quiet line on what saving rewrites.
/// It only shows and collects; `InlineRewordController` decides what happens.
final class CommitMessageEditor: NSView, NSTextViewDelegate {
    private typealias M = Theme.MessageEditor

    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private let counter = NSTextField(labelWithString: "")
    let subject: TextInput
    private let bodyBox = FieldBox()
    let body = PlainTextView()
    private var bodyHeight: NSLayoutConstraint!
    let saveButton = PrimaryButton(title: String(localized: "commit.editor.save", defaultValue: "Save", bundle: .module, comment: "Saves an edited commit message"))
    let cancelButton = SecondaryButton(title: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
    private let note = NSTextField(wrappingLabelWithString: "")
    private let original: String
    /// Saving waits for a plan; without one, or while git runs, the button stays off.
    var canSave = false { didSet { updateSaveButton() } }
    var isSaving = false {
        didSet {
            subject.field.isEditable = !isSaving
            body.isEditable = !isSaving
            cancelButton.isEnabled = !isSaving
            updateSaveButton()
        }
    }

    init(message: String) {
        original = message
        subject = TextInput(accessory: counter, accessoryWidth: M.counterWidth)
        super.init(frame: .zero)
        let (subjectText, bodyText) = Self.split(message)
        subject.stringValue = subjectText
        subject.font = Theme.title
        subject.placeholder = String(localized: "commit.message.subject", defaultValue: "Subject", bundle: .module, comment: "Placeholder: first line of a commit message")
        counter.font = Theme.captionDigits
        counter.alignment = .right
        subject.onChange = { [weak self] _ in self?.edited() }
        subject.onCommand = { [weak self] selector in self?.handle(selector) ?? false }
        buildBody(bodyText)
        note.font = Theme.caption
        note.textColor = Theme.inkMuted
        note.isSelectable = false
        note.stringValue = " "
        saveButton.respondsToCommandReturn = true
        saveButton.toolTip = String(localized: "commit.editor.saveToolTip", defaultValue: "Save (⌘⏎)", bundle: .module)
        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        cancelButton.toolTip = String(localized: "commit.editor.cancelToolTip", defaultValue: "Cancel (Esc)", bundle: .module)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        layout(views: [subject, bodyBox, saveButton, cancelButton, note])
        updateCounter()
        updateSaveButton()
    }

    required init?(coder: NSCoder) { nil }

    /// The edited message: the subject, and the body after a blank line when there is one.
    var message: String {
        let subjectText = subject.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return bodyText.isEmpty ? subjectText : "\(subjectText)\n\n\(bodyText)"
    }

    var isChanged: Bool { message != original.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What saving rewrites, in one line.
    func showNote(_ text: RefString) {
        note.setText(text)
    }

    var noteText: String { RefText.plain(note.stringValue) }

    /// The subject takes the focus with the cursor at its end.
    /// The window built its key view loop before the editor existed, so Tab reaches the editor's fields and buttons only once the loop is rebuilt.
    func focus() {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
        window?.makeFirstResponder(subject.field)
        subject.field.currentEditor()?.selectedRange = NSRange(location: (subject.stringValue as NSString).length, length: 0)
    }

    private static func split(_ message: String) -> (String, String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, "") }
        return (String(trimmed[..<newline]), trimmed[newline...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Layout

    private func buildBody(_ text: String) {
        body.string = text
        body.placeholder = String(localized: "commit.message.body", defaultValue: "Body (optional)", bundle: .module, comment: "Placeholder: the commit message after the subject")
        body.font = Theme.body
        body.textColor = Theme.ink
        body.insertionPointColor = Theme.ink
        body.drawsBackground = false
        body.isRichText = false
        body.allowsUndo = true
        // Text starts where the subject's does, as in the commit form.
        body.textContainer?.lineFragmentPadding = 0
        body.textContainerInset = NSSize(width: Theme.TextField.inset.width - Theme.Control.focusWidth, height: Theme.TextField.inset.height)
        body.textContainer?.widthTracksTextView = true
        body.isVerticallyResizable = false
        body.isHorizontallyResizable = false
        body.focusRingType = .none
        body.delegate = self
        body.onFocusChange = { [weak self] focused in self?.bodyBox.isFocused = focused }
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyBox.addSubview(body)
        let inset = Theme.Control.focusWidth
        bodyHeight = bodyBox.heightAnchor.constraint(equalToConstant: M.bodyMinimumHeight)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyBox.topAnchor, constant: inset),
            body.leadingAnchor.constraint(equalTo: bodyBox.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: bodyBox.trailingAnchor, constant: -inset),
            body.bottomAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: -inset),
            bodyHeight,
        ])
    }

    /// Subject, body, the buttons on the right right under them, then the note.
    private func layout(views: [NSView]) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            subject.topAnchor.constraint(equalTo: topAnchor),
            subject.leadingAnchor.constraint(equalTo: leadingAnchor),
            subject.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyBox.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: M.spacing),
            bodyBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: M.spacing),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -M.spacing),
            note.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: M.spacing),
            note.leadingAnchor.constraint(equalTo: leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
            note.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The body grows with its text; the width it wraps at follows the panel.
    override func layout() {
        super.layout()
        fitBody()
    }

    private func fitBody() {
        guard let manager = body.layoutManager, let container = body.textContainer else { return }
        manager.ensureLayout(for: container)
        let text = manager.usedRect(for: container).height + 2 * body.textContainerInset.height + 2 * Theme.Control.focusWidth
        let height = max(M.bodyMinimumHeight, ceil(text))
        if bodyHeight.constant != height { bodyHeight.constant = height }
    }

    // MARK: Events

    private func edited() {
        updateCounter()
        updateSaveButton()
    }

    func textDidChange(_ notification: Notification) {
        body.needsDisplay = true
        fitBody()
        updateSaveButton()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        commandSelector == #selector(cancelOperation(_:)) || commandSelector == #selector(NSTextView.complete(_:)) ? handle(commandSelector) : false
    }

    /// Escape cancels from either field; Return in the subject saves.
    private func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            guard !isSaving else { return true }
            onCancel?()
            return true
        case #selector(insertNewline(_:)):
            if saveButton.isEnabled { onSave?() }
            return true
        default:
            return false
        }
    }

    private func updateCounter() {
        typealias F = Theme.CommitForm
        let count = subject.stringValue.count
        counter.stringValue = count > 0 ? "\(count)" : ""
        counter.textColor = count > F.subjectLimit ? Theme.persimmon : count > F.subjectWarning ? Theme.ochre : Theme.inkFaint
    }

    private func updateSaveButton() {
        let hasSubject = !subject.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveButton.isEnabled = canSave && !isSaving && hasSubject && isChanged
    }

    @objc private func savePressed(_ sender: Any?) {
        onSave?()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel?()
    }
}
