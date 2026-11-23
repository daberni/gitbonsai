import AppKit
import GitEngine

/// The right panel. It has no tabs: it follows the selection in the history (a commit, or the working directory).
final class DetailView: NSView {
    private typealias M = Theme.Detail
    var onNavigate: ((String) -> Void)?
    /// A file was chosen; the history pane shows its diff.
    var onSelectFile: ((FileSelection) -> Void)?
    var onStage: (([String]) -> Void)?
    var onUnstage: (([String]) -> Void)?
    /// Discard the unstaged changes of one file, or delete it when it is untracked.
    var onDiscard: ((FileSelection) -> Void)?
    /// The entries of a file's context menu.
    var fileMenuItems: ((FileRowView.Model) -> [NSMenuItem])?
    /// Whether the shown commit's message can be edited; nil offers nothing, for commits off the current branch's line.
    var messageAccess: ((Commit) -> InteractiveRebaseController.RewordAccess?)?
    /// The pencil or a double click on the subject asks to edit the shown commit's message.
    var onEditMessage: (() -> Void)?
    /// Kept across redraws of the same commit or working directory, cleared otherwise.
    var selectedFile: FileSelection? { didSet { fileList?.selected = selectedFile } }

    private let stack = NSStackView()
    var loadTask: Task<Void, Never>?
    var loadingNoteTask: Task<Void, Never>?
    var parentTargets: [String] = []
    var copySHA = (full: "", short: "")
    /// Reached by the harness for real clicks.
    var copyButton: NSButton?
    var parentLinks: [NSButton] = []
    var fileList: FileListView?
    /// The file section of the commit shown last. The next commit keeps it on screen until its own files and stats are known and replace both at once.
    var commitFiles: (commitID: String, header: NSTextField, list: FileListView)?
    /// When the shown file list stopped matching the selection; quick stepping through the history does not push the loading note further out.
    var filesOutdatedSince = ContinuousClock.now
    private var isShowingWorkingDirectory = false
    /// The shown commit's subject and body labels, which the message editor takes the place of.
    var message: (commitID: String, views: [NSView])?
    private(set) var messageEditor: CommitMessageEditor?
    /// Reached by the harness for real clicks.
    private(set) var editMessageButton: NSButton?
    var subjectLabel: NSTextField?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = M.spacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: M.padding, bottom: M.padding, right: M.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
    }

    @discardableResult
    func reset(title: String) -> NSView {
        isShowingWorkingDirectory = false
        message = nil
        messageEditor = nil
        editMessageButton = nil
        subjectLabel = nil
        loadTask?.cancel()
        loadingNoteTask?.cancel()
        commitFiles = nil
        fileList = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = label("", font: Theme.label, color: Theme.inkMuted)
        header.attributedStringValue = NSAttributedString(string: title.uppercased(with: AppLanguage.locale), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.heightAnchor.constraint(equalToConstant: M.headerHeight), header.centerYAnchor.constraint(equalTo: box.centerYAnchor), header.leadingAnchor.constraint(equalTo: box.leadingAnchor)])
        stack.addArrangedSubview(box)
        return box
    }

    func label(_ string: String, font: NSFont, color: NSColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = wraps
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Theme.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: Theme.Stroke.hairline).isActive = true
        return line
    }

    func add(_ view: NSView, fill: Bool = true) {
        stack.addArrangedSubview(view)
        if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true }
    }

    // MARK: Message editing

    /// The pencil at the right of the panel's title; disabled with the reason as tooltip where the message cannot be edited.
    func addEditButton(to header: NSView, access: InteractiveRebaseController.RewordAccess) {
        let button = LinkButton(target: self, action: #selector(editMessagePressed(_:)))
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.MessageEditor.pencilSymbol, weight: .regular)
        button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: String(localized: "commit.action.editMessage", defaultValue: "Edit Message", bundle: .module))?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.contentTintColor = Theme.inkMuted
        switch access {
        case .allowed:
            button.toolTip = String(localized: "detail.commit.editToolTip", defaultValue: "Edit message (\(CommandShortcut.editMessage.display))", bundle: .module)
        case let .disabled(reason):
            button.isEnabled = false
            button.toolTip = String(localized: "detail.commit.editDisabledToolTip", defaultValue: "Can’t edit the message: \(reason)", bundle: .module)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: Theme.MessageEditor.pencil),
            button.heightAnchor.constraint(equalToConstant: Theme.MessageEditor.pencil),
        ])
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true
        editMessageButton = button
    }

    @objc private func editMessagePressed(_ sender: NSButton) {
        onEditMessage?()
    }

    /// Puts the editor where the subject and body of `commitID` are; false when another commit is shown.
    func beginEditingMessage(of commitID: String, with editor: CommitMessageEditor) -> Bool {
        guard messageEditor == nil, let message, message.commitID == commitID, let first = message.views.first, let index = stack.arrangedSubviews.firstIndex(of: first) else { return false }
        message.views.forEach { $0.removeFromSuperview() }
        stack.insertArrangedSubview(editor, at: index)
        editor.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true
        messageEditor = editor
        editMessageButton?.isHidden = true
        layoutSubtreeIfNeeded()
        return true
    }

    /// Puts the subject and body back in place of the editor.
    func endEditingMessage() {
        guard let editor = messageEditor, let message, let index = stack.arrangedSubviews.firstIndex(of: editor) else { return }
        editor.removeFromSuperview()
        for (offset, view) in message.views.enumerated() {
            stack.insertArrangedSubview(view, at: index + offset)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true
        }
        messageEditor = nil
        editMessageButton?.isHidden = false
    }

    // MARK: Working directory

    /// Shown again for a changed status, the panel stays and the file list is replaced once its line counts are known, in one step.
    func showWorkingDirectory(status: RepositoryStatus, repository: Repository) {
        let isUpdate = isShowingWorkingDirectory && fileList != nil
        let list: FileListView
        if isUpdate, let fileList {
            list = fileList
        } else {
            reset(title: String(localized: "common.workingDirectory", defaultValue: "Working Directory", bundle: .module, comment: "Detail panel title for uncommitted changes"))
            isShowingWorkingDirectory = true
            list = makeFileList()
        }
        let unstaged = status.unstaged
        let staged = status.staged
        func sections(unstagedStats: [String: DiffStat], stagedStats: [String: DiffStat]) -> [FileListView.Section] {
            let unstagedRows = unstaged.map { entry in
                entry.isUntracked
                    ? FileRowView.Model(selection: FileSelection(path: entry.path, originalPath: nil, source: .untracked), letter: "?", color: Theme.inkMuted, stat: nil, note: String(localized: "files.state.untracked", defaultValue: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet"), actions: [.stage, .discard], state: nil)
                    : FileRowView.Model(selection: FileSelection(path: entry.path, originalPath: nil, source: .unstaged), letter: String(entry.worktreeState.rawValue), color: entry.worktreeState.tint, stat: unstagedStats[entry.path], note: nil, actions: [.stage, .discard], state: entry.worktreeState)
            }
            let stagedRows = staged.map { entry in
                FileRowView.Model(selection: FileSelection(path: entry.path, originalPath: entry.originalPath, source: .staged), letter: String(entry.indexState.rawValue), color: entry.indexState.tint, stat: stagedStats[entry.path], note: nil, actions: [.unstage], state: entry.indexState)
            }
            var result = [
                FileListView.Section(title: String(localized: "detail.files.unstaged", defaultValue: "Unstaged  \(unstaged.count)", bundle: .module, comment: "File list section header with its count"), rows: unstagedRows, action: unstaged.isEmpty ? nil : (String(localized: "detail.files.stageAll", defaultValue: "Stage all", bundle: .module, comment: "Link in the Unstaged section header"), { [weak self] in self?.onStage?(unstaged.map(\.path)) })),
                FileListView.Section(title: String(localized: "detail.files.staged", defaultValue: "Staged  \(staged.count)", bundle: .module, comment: "File list section header with its count"), rows: stagedRows, action: staged.isEmpty ? nil : (String(localized: "detail.files.unstageAll", defaultValue: "Unstage all", bundle: .module, comment: "Link in the Staged section header"), { [weak self] in self?.onUnstage?(staged.map(\.path)) })),
            ]
            if status.hasConflicts {
                let conflictRows = status.conflicted.map { FileRowView.Model(selection: FileSelection(path: $0.path, originalPath: nil, source: .unstaged), letter: "U", color: Theme.persimmon, stat: nil, note: String(localized: "files.state.conflict", defaultValue: "conflict", bundle: .module, comment: "Note on a file row: the file has unresolved conflicts"), state: .unmerged) }
                result.append(FileListView.Section(title: String(localized: "detail.files.conflicts", defaultValue: "Conflicts  \(conflictRows.count)", bundle: .module, comment: "File list section header with its count"), rows: conflictRows, action: nil))
            }
            return result
        }
        if !isUpdate { list.show(sections(unstagedStats: [:], stagedStats: [:])) }
        loadTask?.cancel()
        loadTask = Task {
            async let unstagedStats = repository.workingStats(staged: false)
            async let stagedStats = repository.workingStats(staged: true)
            let counted = ((try? await unstagedStats) ?? [:], (try? await stagedStats) ?? [:])
            guard !Task.isCancelled else { return }
            list.show(sections(unstagedStats: counted.0, stagedStats: counted.1))
        }
    }

    func makeFileList() -> FileListView {
        let list = FileListView()
        list.selected = selectedFile
        list.onSelect = { [weak self] selection in
            self?.selectedFile = selection
            self?.onSelectFile?(selection)
        }
        list.onAction = { [weak self] selection, action in
            switch action {
            case .stage: self?.onStage?([selection.path])
            case .unstage: self?.onUnstage?([selection.path])
            case .discard: self?.onDiscard?(selection)
            }
        }
        list.menuItems = { [weak self] model in self?.fileMenuItems?(model) ?? [] }
        fileList = list
        add(list)
        return list
    }

    /// The short SHA of the commit the panel shows, for the harness.
    var shownShortSHA: String { copySHA.short }

    func showNothing() {
        reset(title: String(localized: "detail.selection.title", defaultValue: "Selection", bundle: .module, comment: "Detail panel title when nothing is selected"))
    }
}
