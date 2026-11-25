import AppKit
import GitEngine

/// The right panel. It has no tabs: it follows the selection in the history (a commit, or the working directory).
final class DetailView: NSView {
    private typealias M = Theme.Detail
    var onNavigate: ((String) -> Void)?
    /// The chosen files changed; the history pane shows their diffs, or the graph again when none is left.
    var onSelectFiles: (([FileSelection]) -> Void)?
    var onStage: (([String]) -> Void)?
    var onUnstage: (([String]) -> Void)?
    /// Discard the unstaged changes of files, or delete them when they are untracked.
    var onDiscard: (([FileSelection]) -> Void)?
    /// "Discard all": the trash in the working directory's title, or the Unstaged header's link.
    var onDiscardAll: ((StagingUseCase.DiscardScope) -> Void)?
    /// The entries of the context menu for the files it acts on.
    var fileMenuItems: (([FileRowView.Model]) -> [NSMenuItem])?
    /// Whether the shown commit's message can be edited; nil offers nothing, for commits off the current branch's line.
    var messageAccess: ((Commit) -> InteractiveRebaseUseCase.RewordAccess?)?
    /// The pencil or a double click on the subject asks to edit the shown commit's message.
    var onEditMessage: (() -> Void)?
    /// Kept across redraws of the same commit or working directory, cleared otherwise.
    var selectedFiles: [FileSelection] = [] { didSet { fileList?.selection = selectedFiles } }

    private let stack = NSStackView()
    var loadTask: Task<Void, Never>?
    var loadingNoteTask: Task<Void, Never>?
    var parentTargets: [String] = []
    var copySHA = (full: "", short: "")
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
    var subjectLabel: NSTextField?
    /// The title line: the title with the SHA (or the working directory's trash) at the left, the parent links at its right end, in the same place for every row.
    var titleRow: (lead: NSStackView, parents: NSStackView)?

    override var isFlipped: Bool { true }

    /// Pictures of the commit's people.
    let avatars: AvatarStore
    let pasteboard: Pasteboard

    init(avatars: AvatarStore, pasteboard: Pasteboard) {
        self.avatars = avatars
        self.pasteboard = pasteboard
        super.init(frame: .zero)
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

    func reset(title: String) {
        isShowingWorkingDirectory = false
        message = nil
        messageEditor = nil
        subjectLabel = nil
        loadTask?.cancel()
        loadingNoteTask?.cancel()
        commitFiles = nil
        fileList = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = label("", font: Theme.label, color: Theme.inkMuted)
        header.attributedStringValue = NSAttributedString(string: title.uppercased(with: AppLanguage.locale), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        // The title gives way first when the SHA and parents do not fit beside it.
        header.lineBreakMode = .byTruncatingTail
        header.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        func line(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = Theme.Space.s
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }
        let lead = line([header])
        let parents = line([])
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(lead)
        box.addSubview(parents)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: M.headerHeight),
            lead.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            lead.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            parents.firstBaselineAnchor.constraint(equalTo: lead.firstBaselineAnchor),
            parents.leadingAnchor.constraint(greaterThanOrEqualTo: lead.trailingAnchor, constant: Theme.Space.m),
            parents.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true
        titleRow = (lead, parents)
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

    /// The separator right under the title line.
    func addTitleSeparator() {
        if let title = stack.arrangedSubviews.first { stack.setCustomSpacing(M.titleSeparatorGap, after: title) }
        add(divider())
    }

    func add(_ view: NSView, fill: Bool = true) {
        stack.addArrangedSubview(view)
        if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true }
    }

    // MARK: Message editing

    /// The pencil after the subject, where editing the message belongs; disabled with the reason as tooltip where the message cannot be edited.
    func editButton(access: InteractiveRebaseUseCase.RewordAccess) -> NSButton {
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
        return button
    }

    /// The subject with the pencil at the right, centred on its first line; the editor replaces both.
    func subjectRow(_ subject: NSTextField, edit button: NSButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in [subject, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        let firstLineMiddle = NSLayoutManager().defaultLineHeight(for: Theme.title) / 2
        NSLayoutConstraint.activate([
            subject.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            subject.topAnchor.constraint(equalTo: row.topAnchor),
            subject.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -Theme.Space.s),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: subject.topAnchor, constant: firstLineMiddle),
            button.widthAnchor.constraint(equalToConstant: Theme.MessageEditor.pencil),
            button.heightAnchor.constraint(equalToConstant: Theme.MessageEditor.pencil),
        ])
        return row
    }

    /// The trash beside the working directory's title: discards staged and unstaged changes after asking.
    private func addDiscardAllButton() {
        guard let lead = titleRow?.lead else { return }
        let button = LinkButton(target: self, action: #selector(discardAllPressed(_:)))
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.Detail.DiscardAll.symbol, weight: .regular)
        let title = String(localized: "detail.workingDirectory.discardAll", defaultValue: "Discard all Changes…", bundle: .module, comment: "Tooltip of the trash in the working directory's title")
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: title)?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.contentTintColor = Theme.inkMuted
        button.toolTip = title
        button.setAccessibilityIdentifier("detail.discardAll")
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Theme.Detail.DiscardAll.button),
            button.heightAnchor.constraint(equalToConstant: Theme.Detail.DiscardAll.button),
        ])
        lead.addArrangedSubview(button)
    }

    @objc private func discardAllPressed(_ sender: NSButton) {
        onDiscardAll?(.everything)
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
    }

    // MARK: Working directory

    /// The file list appears with its line counts; shown again for a changed status, the panel stays and the list is replaced once the new counts are known, in one step.
    func showWorkingDirectory(status: RepositoryStatus, repository: Repository) {
        let head = status.branch.headSHA
        let isUpdate = isShowingWorkingDirectory && fileList != nil && parentTargets == (head.map { [$0] } ?? [])
        let list: FileListView
        if isUpdate, let fileList {
            list = fileList
        } else {
            reset(title: String(localized: "common.workingDirectory", defaultValue: "Working Directory", bundle: .module, comment: "Detail panel title for uncommitted changes"))
            addDiscardAllButton()
            isShowingWorkingDirectory = true
            addMeta(commit: nil, parents: head.map { [$0] } ?? [])
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
                FileListView.Section(title: String(localized: "detail.files.unstaged", defaultValue: "Unstaged  \(unstaged.count)", bundle: .module, comment: "File list section header with its count"), rows: unstagedRows, actions: unstaged.isEmpty ? [] : [
                    .init(title: String(localized: "detail.files.discardAll", defaultValue: "Discard all…", bundle: .module, comment: "Link in the Unstaged section header"), isDestructive: true) { [weak self] in self?.onDiscardAll?(.unstaged) },
                    .init(title: String(localized: "detail.files.stageAll", defaultValue: "Stage all", bundle: .module, comment: "Link in the Unstaged section header")) { [weak self] in self?.onStage?(unstaged.map(\.path)) },
                ]),
                FileListView.Section(title: String(localized: "detail.files.staged", defaultValue: "Staged  \(staged.count)", bundle: .module, comment: "File list section header with its count"), rows: stagedRows, actions: staged.isEmpty ? [] : [.init(title: String(localized: "detail.files.unstageAll", defaultValue: "Unstage all", bundle: .module, comment: "Link in the Staged section header")) { [weak self] in self?.onUnstage?(staged.map(\.path)) }]),
            ]
            if status.hasConflicts {
                let conflictRows = status.conflicted.map { FileRowView.Model(selection: FileSelection(path: $0.path, originalPath: nil, source: .unstaged), letter: "U", color: Theme.persimmon, stat: nil, note: String(localized: "files.state.conflict", defaultValue: "conflict", bundle: .module, comment: "Note on a file row: the file has unresolved conflicts"), state: .unmerged) }
                result.append(FileListView.Section(title: String(localized: "detail.files.conflicts", defaultValue: "Conflicts  \(conflictRows.count)", bundle: .module, comment: "File list section header with its count"), rows: conflictRows))
            }
            return result
        }
        loadTask?.cancel()
        loadTask = Task {
            let counting = Task {
                async let unstagedStats = repository.workingStats(staged: false)
                async let stagedStats = repository.workingStats(staged: true)
                return ((try? await unstagedStats) ?? [:], (try? await stagedStats) ?? [:])
            }
            // Names and counts appear together; only when counting takes longer do the names show first, so a huge change set is not left blank.
            let namesFirst: Task<Void, Never>? = isUpdate ? nil : Task {
                try? await Task.sleep(for: Self.countWait)
                guard !Task.isCancelled else { return }
                list.show(sections(unstagedStats: [:], stagedStats: [:]))
            }
            let counted = await withTaskCancellationHandler { await counting.value } onCancel: {
                counting.cancel()
                namesFirst?.cancel()
            }
            namesFirst?.cancel()
            guard !Task.isCancelled else { return }
            list.show(sections(unstagedStats: counted.0, stagedStats: counted.1))
        }
    }

    /// How long a newly shown file list waits for its line counts before it shows the names alone.
    private static let countWait = Duration.milliseconds(150)

    func makeFileList() -> FileListView {
        let list = FileListView()
        list.selection = selectedFiles
        list.onSelect = { [weak self] files in
            self?.selectedFiles = files
            self?.onSelectFiles?(files)
        }
        list.onAction = { [weak self] files, action in
            switch action {
            case .stage: self?.onStage?(files.map(\.path))
            case .unstage: self?.onUnstage?(files.map(\.path))
            case .discard: self?.onDiscard?(files)
            }
        }
        list.menuItems = { [weak self] models in self?.fileMenuItems?(models) ?? [] }
        fileList = list
        add(list)
        return list
    }

    func showNothing() {
        reset(title: String(localized: "detail.selection.title", defaultValue: "Selection", bundle: .module, comment: "Detail panel title when nothing is selected"))
    }
}
