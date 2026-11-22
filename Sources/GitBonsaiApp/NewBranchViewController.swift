import AppKit
import GitEngine

/// The form of the "New Branch" sheet: name with live validation, start point in a ref picker, and either a new worktree or whether to switch here.
/// It validates and collects; `NewBranchController` runs git.
@MainActor
final class NewBranchViewController: NSViewController {
    private typealias N = Theme.NewBranch

    let nameInput = TextInput(placeholder: "feature/…")
    let picker: RefPicker
    let worktreeBox = LabeledCheckbox(title: String(localized: "Check out in a new worktree", bundle: .module))
    let checkoutBox = LabeledCheckbox(title: String(localized: "Check out", bundle: .module, comment: "Checkbox in the New Branch sheet: switch to the new branch."))
    private(set) lazy var pathInput = TextInput(placeholder: String(localized: "Folder", bundle: .module, comment: "Placeholder of the worktree folder field."), accessory: FieldIconButton(symbol: "folder", label: String(localized: "Choose Folder…", bundle: .module), target: self, action: #selector(choosePath(_:))))
    let createButton = PrimaryButton(title: String(localized: "Create Branch", bundle: .module))
    let cancelButton = SecondaryButton(title: String(localized: "Cancel", bundle: .module))
    let nameMessage = NSTextField(wrappingLabelWithString: "")
    let pathMessage = NSTextField(wrappingLabelWithString: "")
    private let worktreeHint = NSTextField(wrappingLabelWithString: String(localized: "The branch is checked out in a folder of its own. The current folder stays unchanged.", bundle: .module))
    private var pathGroup: NSView!

    var onFinish: ((NewBranchRequest?) -> Void)?
    var onResize: (() -> Void)?

    private let repository: Repository
    private let existingBranches: Set<String>
    private let defaultPath: (String) -> String
    /// Once the folder was edited by hand it no longer follows the name.
    private var pathEdited = false
    /// Each edit of the name starts a new check; only the latest one may update the form.
    private var check = 0
    private(set) var isNameValid = false

    init(repository: Repository, existingBranches: Set<String>, picker: RefPicker, defaultPath: @escaping (String) -> String) {
        self.repository = repository
        self.existingBranches = existingBranches
        self.picker = picker
        self.defaultPath = defaultPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "New Branch", bundle: .module, comment: "Title of the sheet that creates a branch."))
        title.font = Theme.title
        title.textColor = Theme.ink

        nameInput.onChange = { [weak self] _ in self?.nameChanged() }
        nameInput.onCommand = { [weak self] command in self?.handle(command) ?? false }
        pathInput.font = Theme.mono
        // The end of a path names the new folder, so a long path gives up its beginning.
        pathInput.field.lineBreakMode = .byTruncatingHead
        pathInput.onChange = { [weak self] _ in
            self?.pathEdited = true
            self?.updateState()
        }
        pathInput.onCommand = { [weak self] command in self?.handle(command) ?? false }
        for message in [nameMessage, pathMessage] {
            message.font = Theme.caption
            message.textColor = Theme.persimmon
            message.isHidden = true
        }
        worktreeHint.font = Theme.caption
        worktreeHint.textColor = Theme.inkMuted
        worktreeBox.target = self
        worktreeBox.action = #selector(worktreeToggled(_:))
        checkoutBox.isOn = true
        createButton.target = self
        createButton.action = #selector(create(_:))
        createButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        picker.onChange = { [weak self] _ in self?.view.window?.makeFirstResponder(self?.nameInput.field) }

        let name = field(caption: String(localized: "Name", bundle: .module, comment: "Caption of the branch name field."), control: nameInput, message: nameMessage)
        let start = field(caption: String(localized: "Start point", bundle: .module, comment: "Where a new branch starts: a branch, tag or commit."), control: picker.button, message: nil)
        pathGroup = stack([pathInput, pathMessage, worktreeHint], spacing: Theme.TextField.captionGap)
        pathGroup.isHidden = true
        let follow = stack([worktreeBox, pathGroup, checkoutBox], spacing: Theme.Space.s)
        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.spacing = N.buttonGap
        let footer = NSStackView(views: [NSView(), buttons])
        footer.distribution = .fill

        let form = stack([title, name, start, follow, footer], spacing: N.groupSpacing)
        let root = NSView()
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: N.width),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: N.padding),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: N.padding),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -N.padding),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -N.padding),
        ])
        view = root
    }

    /// A caption above its control and, when given, the control's message below.
    private func field(caption: String, control: NSView, message: NSView?) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = Theme.caption
        label.textColor = Theme.inkMuted
        return stack([label, control] + [message].compactMap { $0 }, spacing: Theme.TextField.captionGap)
    }

    /// A vertical stack whose views take its full width, except checkboxes, which keep their box next to their title.
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

    // MARK: Validation

    private var name: String { nameInput.stringValue }

    private func nameChanged() {
        if !pathEdited { pathInput.stringValue = name.isEmpty ? "" : (defaultPath(name) as NSString).abbreviatingWithTildeInPath }
        check += 1
        let current = check
        let candidate = name
        isNameValid = false
        guard !candidate.isEmpty else {
            show(nil, in: nameMessage, input: nameInput)
            return
        }
        if existingBranches.contains(candidate) {
            show(RefString("A branch \(RefName.branch(candidate)) already exists."), in: nameMessage, input: nameInput)
            return
        }
        Task {
            let valid = await repository.isValidBranchName(candidate)
            guard current == check else { return }
            isNameValid = valid
            show(valid ? nil : RefString("Not a valid branch name. Spaces, ~ ^ : ? * [ \\ and “..” are not allowed."), in: nameMessage, input: nameInput)
        }
        updateState()
    }

    /// Why the worktree folder cannot be used, or nil.
    private var pathProblem: String? {
        let path = (pathInput.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let isEmptyFolder = isDirectory.boolValue && ((try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty ?? false)
        return isEmptyFolder ? nil : String(localized: "Something is already there. git only creates a worktree in a new or empty folder.", bundle: .module)
    }

    private func show(_ message: RefString?, in label: NSTextField, input: TextInput?) {
        label.setText(message ?? RefString(verbatim: ""))
        let changed = label.isHidden != (message == nil)
        label.isHidden = message == nil
        input?.isInvalid = message != nil
        updateState()
        if changed { onResize?() }
    }

    private func updateState() {
        let usesWorktree = worktreeBox.isOn
        if usesWorktree {
            let problem = pathProblem
            if pathMessage.stringValue != (problem ?? "") || pathMessage.isHidden != (problem == nil) {
                pathMessage.stringValue = problem ?? ""
                pathMessage.isHidden = problem == nil
                pathInput.isInvalid = problem != nil
                onResize?()
            }
        }
        let pathReady = !usesWorktree || (!pathInput.stringValue.isEmpty && pathProblem == nil)
        createButton.isEnabled = isNameValid && pathReady && picker.selection != nil
    }

    // MARK: Actions

    @objc private func worktreeToggled(_ sender: Any?) {
        pathGroup.isHidden = !worktreeBox.isOn
        checkoutBox.isHidden = worktreeBox.isOn
        updateState()
        onResize?()
    }

    @objc private func choosePath(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Worktree Folder", bundle: .module)
        panel.prompt = String(localized: "Choose", bundle: .module)
        panel.canCreateDirectories = true
        let current = (pathInput.stringValue as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent)
        panel.nameFieldStringValue = (current as NSString).lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            pathInput.stringValue = url.path
            pathEdited = true
            updateState()
        }
    }

    @objc private func create(_ sender: Any?) {
        confirm()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        cancel()
    }

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
        guard createButton.isEnabled, let start = picker.selection?.revision else { return }
        let path = (pathInput.stringValue as NSString).expandingTildeInPath
        let follow: NewBranchRequest.Follow = worktreeBox.isOn ? .worktree(path) : checkoutBox.isOn ? .checkout : .stay
        onFinish?(NewBranchRequest(name: name, start: start, follow: follow))
    }

    func cancel() {
        picker.close()
        onFinish?(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }
}
