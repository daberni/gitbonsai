import AppKit
import GitEngine

/// The form of the "New Branch" sheet: name with live validation, start point in a ref picker, and either a new worktree or whether to switch here.
/// As "New Worktree" it always creates a worktree: from the picked local branch when the name stays empty, otherwise from a new branch starting there.
/// It validates and collects; `NewBranchController` runs git.
@MainActor
final class NewBranchViewController: NSViewController {
    private typealias N = Theme.NewBranch

    enum Purpose {
        case branch
        /// `freeBranches` are the local branches no worktree has checked out; only those can get a worktree of their own.
        case worktree(freeBranches: Set<String>)
    }

    let nameInput = TextInput(placeholder: "feature/…")
    let picker: RefPicker
    let worktreeBox = LabeledCheckbox(title: String(localized: "branch.new.inWorktree", defaultValue: "Check out in a new worktree", bundle: .module))
    let checkoutBox = LabeledCheckbox(title: String(localized: "branch.new.checkout", defaultValue: "Check out", bundle: .module, comment: "Checkbox in the New Branch sheet: switch to the new branch."))
    private(set) lazy var pathInput = TextInput(placeholder: String(localized: "common.folder", defaultValue: "Folder", bundle: .module, comment: "Placeholder of the worktree folder field."), accessory: FieldIconButton(symbol: "folder", label: String(localized: "branch.new.chooseFolder", defaultValue: "Choose Folder…", bundle: .module), target: self, action: #selector(choosePath(_:))))
    private(set) lazy var createButton = PrimaryButton(title: isWorktree ? String(localized: "worktree.new.create", defaultValue: "Create Worktree", bundle: .module) : String(localized: "branch.new.create", defaultValue: "Create Branch", bundle: .module))
    let cancelButton = SecondaryButton(title: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
    let nameMessage = NSTextField(wrappingLabelWithString: "")
    let pathMessage = NSTextField(wrappingLabelWithString: "")
    private let worktreeHint = NSTextField(wrappingLabelWithString: String(localized: "branch.new.worktreeInfo", defaultValue: "The branch gets a folder of its own; this one stays as it is.", bundle: .module))
    private var pathGroup: NSView!

    var onFinish: ((NewBranchRequest?) -> Void)?
    var onResize: (() -> Void)?

    private let repository: Repository
    let purpose: Purpose
    private let existingBranches: Set<String>
    private let defaultPath: (String) -> String
    /// Once the folder was edited by hand it no longer follows the name.
    private var pathEdited = false
    /// Each edit of the name starts a new check; only the latest one may update the form.
    private var check = 0
    private(set) var isNameValid = false

    init(repository: Repository, purpose: Purpose = .branch, existingBranches: Set<String>, picker: RefPicker, defaultPath: @escaping (String) -> String) {
        self.repository = repository
        self.purpose = purpose
        self.existingBranches = existingBranches
        self.picker = picker
        self.defaultPath = defaultPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    var isWorktree: Bool {
        if case .worktree = purpose { true } else { false }
    }

    var sheetTitle: String {
        isWorktree ? String(localized: "worktree.new.title", defaultValue: "New Worktree", bundle: .module, comment: "Title of the sheet that creates a worktree.") : String(localized: "branch.new.title", defaultValue: "New Branch", bundle: .module, comment: "Title of the sheet that creates a branch.")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: sheetTitle)
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
        picker.onChange = { [weak self] _ in
            self?.followDefaultPath()
            self?.updateState()
        }

        let nameCaption = isWorktree ? String(localized: "worktree.new.newBranch", defaultValue: "New Branch", bundle: .module, comment: "Caption of the optional name of a branch the new worktree creates.") : String(localized: "common.name", defaultValue: "Name", bundle: .module, comment: "Caption of the branch name field.")
        let startCaption = isWorktree ? String(localized: "worktree.new.branch", defaultValue: "Branch", bundle: .module, comment: "Caption of the branch, tag or commit the new worktree checks out.") : String(localized: "branch.new.startPoint", defaultValue: "Start point", bundle: .module, comment: "Where a new branch starts: a branch, tag or commit.")
        let name = field(caption: nameCaption, control: nameInput, message: nameMessage)
        let start = field(caption: startCaption, control: picker.button, message: nil)
        pathGroup = stack([pathInput, pathMessage, worktreeHint], spacing: Theme.TextField.captionGap)
        pathGroup.isHidden = true
        let follow = stack([worktreeBox, pathGroup, checkoutBox], spacing: Theme.Space.s)
        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.spacing = N.buttonGap
        let footer = NSStackView(views: [NSView(), buttons])
        footer.distribution = .fill

        if isWorktree {
            worktreeBox.isOn = true
            worktreeBox.isHidden = true
            checkoutBox.isHidden = true
            pathGroup.isHidden = false
            worktreeHint.stringValue = String(localized: "worktree.new.info", defaultValue: "Leave the new branch empty to check out the picked local branch itself. The current folder stays unchanged.", bundle: .module)
        }
        // A worktree is chosen by its branch first; a new branch only when the picked one cannot be used.
        let fields = isWorktree ? [start, name] : [name, start]
        let form = stack([title] + fields + [follow, footer], spacing: N.groupSpacing)
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
        // A worktree can start on a free branch before anything is typed.
        followDefaultPath()
        updateState()
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

    /// The local branch a worktree checks out as it is: the picked one, when no worktree has it and no new name is given.
    private var reusedBranch: String? {
        guard case .worktree(let free) = purpose, name.isEmpty, case .localBranch = picker.selection?.kind, let branch = picker.selection?.revision, free.contains(branch) else { return nil }
        return branch
    }

    private func followDefaultPath() {
        guard !pathEdited else { return }
        let suffix = name.isEmpty ? reusedBranch ?? "" : name
        pathInput.stringValue = suffix.isEmpty ? "" : (defaultPath(suffix) as NSString).abbreviatingWithTildeInPath
    }

    private func nameChanged() {
        followDefaultPath()
        check += 1
        let current = check
        let candidate = name
        isNameValid = false
        guard !candidate.isEmpty else {
            show(nil, in: nameMessage, input: nameInput)
            return
        }
        if existingBranches.contains(candidate) {
            show(RefString(LocalizedStringResource("branch.new.exists", defaultValue: "A branch \(RefName.branch(candidate)) already exists.", bundle: .module)), in: nameMessage, input: nameInput)
            return
        }
        Task {
            let valid = await repository.isValidBranchName(candidate)
            guard current == check else { return }
            isNameValid = valid
            show(valid ? nil : RefString(LocalizedStringResource("branch.new.invalidName", defaultValue: "Not a valid branch name. Spaces, ~ ^ : ? * [ \\ and “..” are not allowed.", bundle: .module)), in: nameMessage, input: nameInput)
        }
        updateState()
    }

    /// Why the worktree folder cannot be used, or nil.
    private var pathProblem: String? {
        let path = (pathInput.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        switch FolderDestination.at(path) {
        case .missing, .emptyFolder: return nil
        case .file, .occupiedFolder, .unreadableFolder: return String(localized: "branch.new.folderNotEmpty", defaultValue: "Something is already there. git only creates a worktree in a new or empty folder.", bundle: .module)
        }
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
        createButton.isEnabled = (isNameValid || reusedBranch != nil) && pathReady && picker.selection != nil
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
        let title = String(localized: "branch.new.folderPanelTitle", defaultValue: "Worktree Folder", bundle: .module)
        let current = (pathInput.stringValue as NSString).expandingTildeInPath
        let directory = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent)
        SheetSupport.chooseFolder(title: title, directory: directory, name: (current as NSString).lastPathComponent, on: window) { [weak self] url in
            guard let self else { return }
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
        // An empty name takes the picked local branch as it is; `NewBranchController` checks it out instead of creating one.
        onFinish?(NewBranchRequest(name: reusedBranch == nil ? name : "", start: start, follow: follow))
    }

    func cancel() {
        picker.close()
        onFinish?(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }
}
