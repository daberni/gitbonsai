import AppKit

/// Subject, body, co-authors and sign-off, the signing note, amend and the commit button. It only shows and collects; `CommitController` decides what happens.
final class CommitFormView: BarView, NSTextFieldDelegate, NSTextViewDelegate {
    private typealias M = Theme.CommitForm

    var onCommit: (() -> Void)?
    /// ⌥⌘⏎: commit as an amend of the last commit, with the message as typed.
    var onAmendCommit: (() -> Void)?
    /// ⇧⌘⏎, or the button clicked with ⇧: stage every change and commit.
    var onCommitAll: (() -> Void)?
    /// ⇧ was pressed or released while the window is active; the button shows "Commit All" while it is held.
    var onShiftChanged: (() -> Void)?
    private(set) var isShiftHeld = false
    private var flagsMonitor: Any?
    /// The co-author button was pressed; the controller shows the menu of known authors.
    var onCoAuthorMenu: ((NSView) -> Void)?
    var onAmendChanged: ((Bool) -> Void)?
    /// Typing changed subject or body.
    var onEdit: (() -> Void)?

    private let subjectBox = FieldBox()
    private let subject = PlainTextField()
    private let counter = NSTextField(labelWithString: "")
    private let bodyBox = FieldBox()
    private let bodyScroll = NSScrollView()
    private let body = PlainTextView()
    private let signing = NSTextField(labelWithString: "")
    private let amend = LabeledCheckbox(title: String(localized: "commit.form.amend", defaultValue: "Amend", bundle: .module, comment: "Checkbox: amend the last commit instead of making a new one."))
    private let coAuthorButton = LinkButton(frame: .zero)
    private let coAuthorList = NSTextField(labelWithString: "")
    private let signOff = LabeledCheckbox(title: String(localized: "commit.form.signOff", defaultValue: "Sign off", bundle: .module, comment: "Checkbox: add a Signed-off-by trailer with the committer's name."))
    private let commit = PrimaryButton(title: String(localized: "commit.form.commit", defaultValue: "Commit", bundle: .module, comment: "Button that commits."))

    init() {
        super.init(edge: .top)
        buildSubject()
        buildBody()
        signing.font = Theme.caption
        signing.textColor = Theme.inkMuted
        signing.lineBreakMode = .byTruncatingTail
        signing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        amend.target = self
        amend.action = #selector(amendChanged(_:))
        commit.target = self
        commit.action = #selector(commitPressed(_:))
        commit.respondsToCommandReturn = true
        commit.toolTip = String(localized: "commit.form.commitToolTip", defaultValue: "Commit (⌘⏎), commit all changes (⇧⌘⏎), amend the last Commit with this message (⌥⌘⏎)", bundle: .module, comment: "Tooltip of the commit button with its shortcuts.")
        buildTrailers()
        layout(views: [subjectBox, bodyBox, coAuthorButton, coAuthorList, signOff, signing, amend, commit])
        updateCounter()
    }

    required init?(coder: NSCoder) { nil }

    private func buildSubject() {
        subject.placeholderString = String(localized: "commit.message.subject", defaultValue: "Subject", bundle: .module, comment: "Placeholder of the commit message subject.")
        subject.delegate = self
        subject.onFocusChange = { [weak self] focused in self?.subjectBox.isFocused = focused }
        counter.font = Theme.captionDigits
        counter.alignment = .right
        for view in [subject, counter] {
            view.translatesAutoresizingMaskIntoConstraints = false
            subjectBox.addSubview(view)
        }
        // The counter sits inside the field in room the field keeps free, so the field never changes size.
        NSLayoutConstraint.activate([
            subject.leadingAnchor.constraint(equalTo: subjectBox.leadingAnchor, constant: M.fieldInset.width),
            subject.trailingAnchor.constraint(equalTo: counter.leadingAnchor, constant: -Theme.Space.xs),
            subject.centerYAnchor.constraint(equalTo: subjectBox.centerYAnchor),
            counter.trailingAnchor.constraint(equalTo: subjectBox.trailingAnchor, constant: -M.fieldInset.width),
            counter.centerYAnchor.constraint(equalTo: subjectBox.centerYAnchor),
            counter.widthAnchor.constraint(equalToConstant: M.counterWidth),
        ])
    }

    private func buildBody() {
        body.placeholder = String(localized: "commit.message.body", defaultValue: "Body (optional)", bundle: .module, comment: "Placeholder of the commit message body.")
        body.font = Theme.body
        body.textColor = Theme.ink
        body.insertionPointColor = Theme.ink
        body.drawsBackground = false
        body.isRichText = false
        body.allowsUndo = true
        // Text starts where the subject's does: the field inset minus the room the focus border takes, and no extra line padding.
        body.textContainer?.lineFragmentPadding = 0
        body.textContainerInset = NSSize(width: M.fieldInset.width - Theme.Control.focusWidth, height: M.fieldInset.height)
        body.delegate = self
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.focusRingType = .none
        body.onFocusChange = { [weak self] focused in self?.bodyBox.isFocused = focused }
        bodyScroll.documentView = body
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyBox.addSubview(bodyScroll)
        let inset = Theme.Control.focusWidth
        NSLayoutConstraint.activate([
            bodyScroll.topAnchor.constraint(equalTo: bodyBox.topAnchor, constant: inset),
            bodyScroll.leadingAnchor.constraint(equalTo: bodyBox.leadingAnchor, constant: inset),
            bodyScroll.trailingAnchor.constraint(equalTo: bodyBox.trailingAnchor, constant: -inset),
            bodyScroll.bottomAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: -inset),
        ])
    }

    private func buildTrailers() {
        coAuthorButton.isBordered = false
        coAuthorButton.target = self
        coAuthorButton.action = #selector(coAuthorPressed(_:))
        coAuthorButton.attributedTitle = NSAttributedString(string: String(localized: "commit.form.addCoAuthor", defaultValue: "Add Co-Author…", bundle: .module, comment: "Link that opens the list of the repository's authors to add as co-author."), attributes: [.font: Theme.caption, .foregroundColor: Theme.moss])
        coAuthorButton.setAccessibilityIdentifier("commit.form.coAuthor")
        coAuthorList.font = Theme.caption
        coAuthorList.textColor = Theme.inkMuted
        coAuthorList.lineBreakMode = .byTruncatingTail
        coAuthorList.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        signOff.setAccessibilityIdentifier("commit.form.signOff")
        signOff.target = self
        signOff.action = #selector(signOffChanged(_:))
    }

    /// Subject, body, the co-author and sign-off row, then one row: the signing note on the left, amend and the button on the right.
    private func layout(views: [NSView]) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            subjectBox.topAnchor.constraint(equalTo: topAnchor, constant: M.padding),
            subjectBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.padding),
            subjectBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.padding),
            subjectBox.heightAnchor.constraint(equalToConstant: M.subjectHeight),
            bodyBox.topAnchor.constraint(equalTo: subjectBox.bottomAnchor, constant: M.spacing),
            bodyBox.leadingAnchor.constraint(equalTo: subjectBox.leadingAnchor),
            bodyBox.trailingAnchor.constraint(equalTo: subjectBox.trailingAnchor),
            bodyBox.heightAnchor.constraint(equalToConstant: M.bodyHeight),
            signOff.topAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: M.spacing),
            signOff.trailingAnchor.constraint(equalTo: subjectBox.trailingAnchor),
            coAuthorButton.leadingAnchor.constraint(equalTo: subjectBox.leadingAnchor),
            coAuthorButton.centerYAnchor.constraint(equalTo: signOff.centerYAnchor),
            coAuthorList.leadingAnchor.constraint(equalTo: coAuthorButton.trailingAnchor, constant: Theme.Space.s),
            coAuthorList.centerYAnchor.constraint(equalTo: signOff.centerYAnchor),
            coAuthorList.trailingAnchor.constraint(lessThanOrEqualTo: signOff.leadingAnchor, constant: -Theme.Space.s),
            commit.topAnchor.constraint(equalTo: signOff.bottomAnchor, constant: M.spacing),
            commit.trailingAnchor.constraint(equalTo: subjectBox.trailingAnchor),
            commit.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -M.padding),
            amend.trailingAnchor.constraint(equalTo: commit.leadingAnchor, constant: -Theme.Space.m),
            amend.centerYAnchor.constraint(equalTo: commit.centerYAnchor),
            signing.leadingAnchor.constraint(equalTo: subjectBox.leadingAnchor),
            signing.centerYAnchor.constraint(equalTo: commit.centerYAnchor),
            signing.trailingAnchor.constraint(lessThanOrEqualTo: amend.leadingAnchor, constant: -Theme.Space.s),
        ])
    }

    // MARK: Content

    var subjectText: String {
        get { subject.stringValue }
        set { subject.stringValue = newValue; updateCounter() }
    }

    var bodyText: String {
        get { body.string }
        set { body.string = newValue; body.needsDisplay = true }
    }

    var isAmend: Bool {
        get { amend.isOn }
        set { amend.isOn = newValue }
    }

    var isSignOff: Bool {
        get { signOff.isOn }
        set { signOff.isOn = newValue }
    }

    /// The names of the chosen co-authors beside the add link.
    func show(coAuthors names: [String]) {
        coAuthorList.stringValue = names.isEmpty ? "" : String(localized: "commit.form.coAuthors", defaultValue: "With \(names.formatted(.list(type: .and).locale(AppLanguage.locale)))", bundle: .module, comment: "The co-authors chosen for the next commit, as a list of names.")
        coAuthorList.toolTip = names.joined(separator: "\n")
    }

    func show(signing format: String?, canCommit: Bool, buttonTitle: LocalizedStringResource) {
        signing.stringValue = format.map { String(localized: "commit.form.signedWith", defaultValue: "Signed with \($0)", bundle: .module, comment: "The signing format, such as ssh or openpgp.") } ?? ""
        commit.isEnabled = canCommit
        commit.title = buttonTitle.text
    }

    /// Clicks the commit button, for the screenshot harness.
    func pressCommit() {
        commit.performClick(nil)
    }

    /// Puts the cursor into the subject, for the command bar's Commit and Amend.
    func focusSubject() {
        window?.makeFirstResponder(subject)
    }

    /// Toggles amend through its checkbox, for the screenshot harness.
    func pressAmend() {
        amend.performClick(nil)
    }

    private func updateCounter() {
        let count = subject.stringValue.count
        counter.stringValue = count > 0 ? "\(count)" : ""
        counter.textColor = count > M.subjectLimit ? Theme.persimmon : count > M.subjectWarning ? Theme.ochre : Theme.inkFaint
    }

    // MARK: Events

    func controlTextDidChange(_ notification: Notification) {
        updateCounter()
        onEdit?()
    }

    func textDidChange(_ notification: Notification) {
        body.needsDisplay = true
        onEdit?()
    }

    @objc private func amendChanged(_ sender: Any?) {
        onAmendChanged?(isAmend)
    }

    @objc private func commitPressed(_ sender: Any?) {
        if isShiftHeld, !isAmend, let onCommitAll { onCommitAll() } else { onCommit?() }
    }

    /// Follows ⇧ through the app's events, wherever the focus is, so the button title changes while it is held.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        setShiftHeld(false)
        guard window != nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setShiftHeld(event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift)
            return event
        }
    }

    private func setShiftHeld(_ held: Bool) {
        guard held != isShiftHeld else { return }
        isShiftHeld = held
        onShiftChanged?()
    }

    @objc private func signOffChanged(_ sender: Any?) {
        onEdit?()
    }

    @objc private func coAuthorPressed(_ sender: NSView) {
        onCoAuthorMenu?(sender)
    }

    /// ⇧⌘⏎ and ⌥⌘⏎ anywhere in the window while the form shows; ⌘⏎ belongs to the commit button.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.keyCode == KeyCode.return, !isHiddenOrHasHiddenAncestor else { return super.performKeyEquivalent(with: event) }
        switch event.modifierFlags.intersection(.deviceIndependentFlagsMask) {
        case [.command, .shift] where onCommitAll != nil: onCommitAll?()
        case [.command, .option] where onAmendCommit != nil: onAmendCommit?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
