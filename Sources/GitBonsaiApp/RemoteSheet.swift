import AppKit
import GitEngine

/// What the remote sheet asks git to do: add a remote, or give an existing one another name or URL.
struct RemoteRequest: Equatable {
    let name: String
    let url: String
    /// Fetches the new remote right away; only when adding.
    let fetch: Bool
}

/// The "Add Remote" and "Edit Remote" sheet: name and URL with live validation and, when adding, whether to fetch afterwards.
/// It validates and collects; `RemoteActions` runs git.
@MainActor
final class RemoteSheet: NSViewController {
    private typealias R = Theme.RemoteForm

    enum Mode: Equatable {
        case add
        case edit(name: String, url: String)
    }

    let nameInput = TextInput(placeholder: "upstream")
    let urlInput = TextInput(placeholder: "https://github.com/owner/repository.git")
    let fetchBox = LabeledCheckbox(title: String(localized: "sidebar.remote.form.fetchAfterAdding", defaultValue: "Fetch after adding", bundle: .module))
    let confirmButton: PrimaryButton
    let cancelButton = SecondaryButton(title: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
    let nameMessage = NSTextField(wrappingLabelWithString: "")
    private(set) var window: SheetWindow!

    private let mode: Mode
    private let repository: Repository
    private let existing: Set<String>
    /// Each edit of the name starts a new check; only the latest one may update the form.
    private var check = 0
    private(set) var isNameValid = false
    private var request: RemoteRequest?

    init(mode: Mode, repository: Repository, existing: Set<String>) {
        self.mode = mode
        self.repository = repository
        self.existing = existing
        confirmButton = PrimaryButton(title: mode == .add ? String(localized: "sidebar.remote.add.title", defaultValue: "Add Remote", bundle: .module, comment: "Title of the sheet that adds a remote.") : String(localized: "sidebar.remote.form.save", defaultValue: "Save", bundle: .module, comment: "Button that saves a remote's new name and URL."))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private var sheetTitle: String {
        mode == .add ? String(localized: "sidebar.remote.add.title", defaultValue: "Add Remote", bundle: .module, comment: "Title of the sheet that adds a remote.") : String(localized: "sidebar.remote.edit.title", defaultValue: "Edit Remote", bundle: .module, comment: "Title of the sheet that renames a remote or changes its URL.")
    }

    // MARK: Layout

    override func loadView() {
        let title = NSTextField(labelWithString: sheetTitle)
        title.font = Theme.title
        title.textColor = Theme.ink

        if case let .edit(name, url) = mode {
            nameInput.stringValue = name
            urlInput.stringValue = url
            isNameValid = true
        }
        urlInput.font = Theme.mono
        nameInput.onChange = { [weak self] _ in self?.nameChanged() }
        urlInput.onChange = { [weak self] _ in self?.updateState() }
        for input in [nameInput, urlInput] { input.onCommand = { [weak self] command in self?.handle(command) ?? false } }
        nameMessage.font = Theme.caption
        nameMessage.textColor = Theme.persimmon
        nameMessage.isHidden = true
        fetchBox.isOn = true
        fetchBox.isHidden = mode != .add
        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        let name = field(caption: String(localized: "common.name", defaultValue: "Name", bundle: .module, comment: "Caption of the branch name field."), control: nameInput, message: nameMessage)
        let url = field(caption: String(localized: "sidebar.remote.form.url", defaultValue: "URL", bundle: .module, comment: "Caption of the field with the remote's address."), control: urlInput, message: nil)
        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.spacing = R.buttonGap
        let footer = NSStackView(views: [NSView(), buttons])
        footer.distribution = .fill

        let form = stack([title, name, url, fetchBox, footer], spacing: R.groupSpacing)
        let root = NSView()
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: R.width),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: R.padding),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: R.padding),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -R.padding),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -R.padding),
        ])
        view = root
        updateState()
    }

    private func field(caption: String, control: NSView, message: NSView?) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = Theme.caption
        label.textColor = Theme.inkMuted
        return stack([label, control] + [message].compactMap { $0 }, spacing: Theme.TextField.captionGap)
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views where !(view is LabeledCheckbox) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: Running

    /// Shows the sheet on `parent` and waits for the answer; nil when it was cancelled or nothing changed.
    func run(on parent: NSWindow) async -> RemoteRequest? {
        let window = SheetWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: R.width, height: R.width / 2)), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        window.contentViewController = self
        window.title = sheetTitle
        window.onCancel = { [weak self] in self?.cancel() }
        window.onReturn = { [weak self] in self?.confirm() }
        self.window = window
        fitToContent()
        window.initialFirstResponder = mode == .add ? nameInput.field : urlInput.field
        // harness: the harness drives this from outside through Accessibility and real events.
        ScreenshotHarness.driveRemoteSheet(self)
        let response = await withCheckedContinuation { continuation in
            parent.beginSheet(window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? request : nil
    }

    private func finish(_ request: RemoteRequest?) {
        self.request = request
        window.sheetParent?.endSheet(window, returnCode: request == nil ? .cancel : .OK)
    }

    /// The sheet takes the height its form needs; its top edge stays where it is.
    private func fitToContent() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: Validation

    private var name: String { nameInput.stringValue.trimmingCharacters(in: .whitespaces) }
    private var url: String { urlInput.stringValue.trimmingCharacters(in: .whitespaces) }

    private var originalName: String? {
        if case let .edit(name, _) = mode { name } else { nil }
    }

    private func nameChanged() {
        check += 1
        let current = check
        let candidate = name
        isNameValid = false
        guard !candidate.isEmpty else { return show(nil) }
        if candidate == originalName {
            isNameValid = true
            return show(nil)
        }
        if existing.contains(candidate) {
            return show(RefString(LocalizedStringResource("sidebar.remote.form.exists", defaultValue: "A remote \(RefName.remote(candidate)) already exists.", bundle: .module)))
        }
        updateState()
        Task {
            let valid = await repository.isValidRemoteName(candidate)
            guard current == check else { return }
            isNameValid = valid
            show(valid ? nil : RefString(LocalizedStringResource("sidebar.remote.form.invalidName", defaultValue: "Not a valid remote name. Spaces, ~ ^ : ? * [ \\ and “..” are not allowed.", bundle: .module)))
        }
    }

    private func show(_ message: RefString?) {
        nameMessage.setText(message ?? RefString(verbatim: ""))
        let changed = nameMessage.isHidden != (message == nil)
        nameMessage.isHidden = message == nil
        nameInput.isInvalid = message != nil
        updateState()
        if changed, window != nil { fitToContent() }
    }

    private func updateState() {
        let unchanged: Bool = if case let .edit(name, url) = mode { self.name == name && self.url == url } else { false }
        confirmButton.isEnabled = isNameValid && !url.isEmpty && !unchanged
    }

    // MARK: Actions

    @objc private func confirmPressed(_ sender: Any?) { confirm() }
    @objc private func cancelPressed(_ sender: Any?) { cancel() }

    /// ⏎ in a field confirms when the form is complete, Esc cancels.
    private func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            confirm()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func confirm() {
        guard confirmButton.isEnabled else { return }
        finish(RemoteRequest(name: name, url: url, fetch: mode == .add && fetchBox.isOn))
    }

    func cancel() { finish(nil) }

    override func cancelOperation(_ sender: Any?) { cancel() }
}
