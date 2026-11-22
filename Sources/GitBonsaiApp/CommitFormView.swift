import AppKit

/// Subject, body, the signing note, amend and the commit button. It only shows and collects; `CommitController` decides what happens.
final class CommitFormView: BarView, NSTextFieldDelegate, NSTextViewDelegate {
    private typealias M = Theme.CommitForm

    var onCommit: (() -> Void)?
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
    private let amend = LabeledCheckbox(title: "Amend")
    private let commit = PrimaryButton(title: "Commit")

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
        commit.toolTip = "Commit (⌘⏎)"
        layout(views: [subjectBox, bodyBox, signing, amend, commit])
        updateCounter()
    }

    required init?(coder: NSCoder) { nil }

    private func buildSubject() {
        subject.placeholderString = "Subject"
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
        body.placeholder = "Body (optional)"
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

    /// Subject, body, then one row: the signing note on the left, amend and the button on the right.
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
            commit.topAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: M.spacing),
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

    func show(signing format: String?, canCommit: Bool, buttonTitle: String) {
        signing.stringValue = format.map { "Signiert mit \($0)" } ?? ""
        commit.isEnabled = canCommit
        commit.title = buttonTitle
    }

    /// Clicks the commit button, for the screenshot harness.
    func pressCommit() {
        commit.performClick(nil)
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
        onCommit?()
    }
}
