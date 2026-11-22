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
    private var loadTask: Task<Void, Never>?
    private var loadingNoteTask: Task<Void, Never>?
    private var parentTargets: [String] = []
    private var copySHA = (full: "", short: "")
    /// Reached by the harness for real clicks.
    private(set) var copyButton: NSButton?
    private(set) var parentLinks: [NSButton] = []
    /// Harness runs copy into a pasteboard of their own instead of the user's clipboard.
    static var pasteboard = NSPasteboard.general
    private var fileList: FileListView?
    /// The file section of the commit shown last. The next commit keeps it on screen until its own files and stats are known and replace both at once.
    private var commitFiles: (commitID: String, header: NSTextField, list: FileListView)?
    /// When the shown file list stopped matching the selection; quick stepping through the history does not push the loading note further out.
    private var filesOutdatedSince = ContinuousClock.now
    private var isShowingWorkingDirectory = false
    /// The shown commit's subject and body labels, which the message editor takes the place of.
    private var message: (commitID: String, views: [NSView])?
    private(set) var messageEditor: CommitMessageEditor?
    /// Reached by the harness for real clicks.
    private(set) var editMessageButton: NSButton?
    private(set) var subjectLabel: NSTextField?

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
        let header = label(title.uppercased(with: AppLanguage.locale), font: Theme.label, color: Theme.inkMuted)
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

    // MARK: Commit

    /// The header is known at once and replaces the old one; the file list and its stats line follow together once git has answered.
    func show(commit: Commit, strand: NSColor, repository: Repository) {
        let previous = commitFiles
        let header = reset(title: String(localized: "Commit", bundle: .module, comment: "Detail panel title for one commit"))
        let access = messageAccess?(commit)
        if let access { addEditButton(to: header, access: access) }
        let subject = SubjectLabel(wrappingLabelWithString: commit.subject)
        subject.font = Theme.title
        subject.textColor = Theme.ink
        subject.isSelectable = false
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if access == .allowed {
            subject.onDoubleClick = { [weak self] in self?.onEditMessage?() }
            subject.toolTip = String(localized: "Double-click to edit the message (\(CommandShortcut.editMessage.display))", bundle: .module)
        }
        add(subject)
        subjectLabel = subject
        var messageViews: [NSView] = [subject]
        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let bodyLabel = label(body, font: Theme.body, color: Theme.inkMuted, wraps: true)
            add(bodyLabel)
            messageViews.append(bodyLabel)
        }
        message = (commit.id, messageViews)

        // Author and committer appear separately as soon as anything differs; otherwise one line says both.
        let samePerson = commit.authorName == commit.committerName && commit.authorEmail == commit.committerEmail
        let sameTime = abs(commit.authorDate.timeIntervalSince(commit.committerDate)) < 1
        if samePerson && sameTime {
            add(person(commit.authorName, role: String(localized: "Authored and committed", bundle: .module, comment: "Detail panel: role of the one person who wrote and committed a commit, followed by the date"), date: commit.authorDate, ring: strand, avatar: AvatarView.Source(email: commit.authorEmail, commit: commit.id, repository: repository)))
        } else {
            add(person(commit.authorName, role: String(localized: "Authored", bundle: .module, comment: "Detail panel: role of the commit's author, followed by the date"), date: commit.authorDate, ring: strand, avatar: AvatarView.Source(email: commit.authorEmail, commit: commit.id, repository: repository)))
            add(person(commit.committerName, role: String(localized: "Committed", bundle: .module, comment: "Detail panel: role of the commit's committer, followed by the date"), date: commit.committerDate, ring: Theme.hairline, avatar: AvatarView.Source(email: commit.committerEmail, commit: commit.id, repository: repository)))
        }

        add(divider())
        let meta = NSStackView()
        meta.orientation = .horizontal
        meta.spacing = Theme.Space.s
        meta.addArrangedSubview(label(String(localized: "Commit", bundle: .module, comment: "Detail panel title for one commit"), font: Theme.caption, color: Theme.inkMuted))
        copySHA = (full: commit.id, short: commit.shortID)
        let copy = LinkButton(target: self, action: #selector(copyCommitSHA(_:)))
        copy.attributedTitle = NSAttributedString(string: commit.shortID, attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.ink])
        copy.imagePosition = .imageTrailing
        showCopyIcon(on: copy, copied: false)
        meta.addArrangedSubview(copy)
        copyButton = copy
        parentTargets = commit.parents
        parentLinks = []
        if !commit.parents.isEmpty { meta.addArrangedSubview(label(commit.parents.count == 1 ? String(localized: "Parent", bundle: .module, comment: "Label before the one parent SHA") : String(localized: "Parents", bundle: .module, comment: "Label before the parent SHAs of a merge"), font: Theme.caption, color: Theme.inkMuted)) }
        for (index, parent) in commit.parents.enumerated() {
            let link = LinkButton(target: self, action: #selector(openParent(_:)))
            link.tag = index
            link.attributedTitle = NSAttributedString(string: String(parent.prefix(7)), attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.moss, .underlineStyle: NSUnderlineStyle.single.rawValue])
            link.toolTip = String(localized: "Jump to the parent commit in the graph", bundle: .module)
            meta.addArrangedSubview(link)
            parentLinks.append(link)
        }
        add(meta, fill: false)
        add(divider())

        let filesHeader: NSTextField
        let list: FileListView
        if let previous {
            filesHeader = previous.header
            list = previous.list
            if list.freshness == .current {
                list.freshness = .stale
                filesOutdatedSince = .now
            }
            add(filesHeader)
            add(list)
            fileList = list
        } else {
            filesHeader = label("", font: Theme.caption, color: Theme.inkMuted)
            add(filesHeader)
            list = makeFileList()
            filesOutdatedSince = .now
        }
        commitFiles = (commit.id, filesHeader, list)
        if previous?.commitID != commit.id { scroll(.zero) }
        loadTask = Task { [weak self] in
            let files = (try? await repository.changedFiles(of: commit)) ?? []
            guard let self, !Task.isCancelled else { return }
            loadingNoteTask?.cancel()
            let total = files.compactMap(\.stat).reduce(DiffStat(added: 0, removed: 0)) { DiffStat(added: $0.added + $1.added, removed: $0.removed + $1.removed) }
            let summary = NSMutableAttributedString(string: String(localized: "\(files.count) files", bundle: .module) + " · ", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
            summary.append(FileRowView.statText(total))
            let rows = files.map { file in
                FileRowView.Model(selection: FileSelection(path: file.path, originalPath: file.originalPath, source: .commit(commit)), letter: String(file.state.rawValue), color: file.state.tint, stat: file.stat, note: file.stat == nil && file.state != .deleted ? String(localized: "binary", bundle: .module, comment: "Note on a file row: a binary file without line counts") : nil, state: file.state)
            }
            filesHeader.attributedStringValue = summary
            list.show([FileListView.Section(title: String(localized: "Files", bundle: .module, comment: "Section header of a file list"), rows: rows, action: nil)])
        }
        // A quick answer swaps the lists without anything in between; a slow one gets a note in place, at the old height.
        let deadline = filesOutdatedSince + M.loadingDelay
        loadingNoteTask = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            filesHeader.stringValue = String(localized: "Loading files…", bundle: .module)
            list.freshness = .loading
        }
    }

    // MARK: Message editing

    /// The pencil at the right of the panel's title; disabled with the reason as tooltip where the message cannot be edited.
    private func addEditButton(to header: NSView, access: InteractiveRebaseController.RewordAccess) {
        let button = LinkButton(target: self, action: #selector(editMessagePressed(_:)))
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.MessageEditor.pencilSymbol, weight: .regular)
        button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: String(localized: "Edit Message", bundle: .module))?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.contentTintColor = Theme.inkMuted
        switch access {
        case .allowed:
            button.toolTip = String(localized: "Edit message (\(CommandShortcut.editMessage.display))", bundle: .module)
        case let .disabled(reason):
            button.isEnabled = false
            button.toolTip = String(localized: "Can’t edit the message: \(reason)", bundle: .module)
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
            reset(title: String(localized: "Working Directory", bundle: .module, comment: "Detail panel title for uncommitted changes"))
            isShowingWorkingDirectory = true
            list = makeFileList()
        }
        let unstaged = status.unstaged
        let staged = status.staged
        func sections(unstagedStats: [String: DiffStat], stagedStats: [String: DiffStat]) -> [FileListView.Section] {
            let unstagedRows = unstaged.map { entry in
                entry.isUntracked
                    ? FileRowView.Model(selection: FileSelection(path: entry.path, originalPath: nil, source: .untracked), letter: "?", color: Theme.inkMuted, stat: nil, note: String(localized: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet"), actions: [.stage, .discard], state: nil)
                    : FileRowView.Model(selection: FileSelection(path: entry.path, originalPath: nil, source: .unstaged), letter: String(entry.worktreeState.rawValue), color: entry.worktreeState.tint, stat: unstagedStats[entry.path], note: nil, actions: [.stage, .discard], state: entry.worktreeState)
            }
            let stagedRows = staged.map { entry in
                FileRowView.Model(selection: FileSelection(path: entry.path, originalPath: entry.originalPath, source: .staged), letter: String(entry.indexState.rawValue), color: entry.indexState.tint, stat: stagedStats[entry.path], note: nil, actions: [.unstage], state: entry.indexState)
            }
            var result = [
                FileListView.Section(title: String(localized: "Unstaged  \(unstaged.count)", bundle: .module, comment: "File list section header with its count"), rows: unstagedRows, action: unstaged.isEmpty ? nil : (String(localized: "Stage all", bundle: .module, comment: "Link in the Unstaged section header"), { [weak self] in self?.onStage?(unstaged.map(\.path)) })),
                FileListView.Section(title: String(localized: "Staged  \(staged.count)", bundle: .module, comment: "File list section header with its count"), rows: stagedRows, action: staged.isEmpty ? nil : (String(localized: "Unstage all", bundle: .module, comment: "Link in the Staged section header"), { [weak self] in self?.onUnstage?(staged.map(\.path)) })),
            ]
            if status.hasConflicts {
                let conflictRows = status.conflicted.map { FileRowView.Model(selection: FileSelection(path: $0.path, originalPath: nil, source: .unstaged), letter: "U", color: Theme.persimmon, stat: nil, note: String(localized: "conflict", bundle: .module, comment: "Note on a file row: the file has unresolved conflicts"), state: .unmerged) }
                result.append(FileListView.Section(title: String(localized: "Conflicts  \(conflictRows.count)", bundle: .module, comment: "File list section header with its count"), rows: conflictRows, action: nil))
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

    /// What the panel shows right now, for the harness trace.
    var traceState: (header: String, files: String, filesCommit: String?, rows: Int, freshness: FileListView.Freshness, height: CGFloat) {
        let commits = Set((fileList?.models ?? []).compactMap { model -> String? in
            if case .commit(let commit) = model.selection.source { return commit.shortID }
            return nil
        })
        return (copySHA.short, commitFiles?.header.stringValue ?? "", commits.count == 1 ? commits.first : nil, fileList?.models.count ?? 0, fileList?.freshness ?? .current, frame.height)
    }

    func showNothing() {
        reset(title: String(localized: "Selection", bundle: .module, comment: "Detail panel title when nothing is selected"))
    }

    // MARK: Parts

    private func person(_ name: String, role: String, date: Date, ring: NSColor, avatar source: AvatarView.Source) -> NSView {
        let avatar = AvatarView(initials: GraphRowView.initials(name), ring: ring, source: source)
        let nameLabel = label(name, font: Theme.body, color: Theme.ink)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.locale
        let detail = label("\(role) · \(formatter.localizedString(for: date, relativeTo: Date()))", font: Theme.caption, color: Theme.inkMuted)
        detail.toolTip = GraphRowView.exactFormatter.string(from: date)
        let text = NSStackView(views: [nameLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = M.personLineGap
        let row = NSStackView(views: [avatar, text])
        row.orientation = .horizontal
        row.spacing = M.spacing
        return row
    }

    /// A click copies the full SHA, ⌥-click the short one; the icon turns into a checkmark for a moment as the confirmation.
    @objc private func copyCommitSHA(_ sender: NSButton) {
        let short = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(short ? copySHA.short : copySHA.full, forType: .string)
        showCopyIcon(on: sender, copied: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + M.copiedFeedback) { [weak self, weak sender] in
            guard let self, let sender else { return }
            showCopyIcon(on: sender, copied: false)
        }
    }

    private func showCopyIcon(on button: NSButton, copied: Bool) {
        button.image = Self.copyIcon(copied: copied)
        button.toolTip = copied ? String(localized: "Copied", bundle: .module) : String(localized: "Copy the full SHA, with ⌥ the short one: \(copySHA.full)", bundle: .module)
    }

    /// Both states share the box of the copy symbol, so the checkmark does not shift the parents beside it.
    private static func copyIcon(copied: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.monoSmall.pointSize, weight: .regular).applying(.init(paletteColors: [copied ? Theme.moss : Theme.inkMuted]))
        guard let copy = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        guard copied, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            copy.accessibilityDescription = String(localized: "Copy SHA", bundle: .module)
            return copy
        }
        let box = copy.size
        let icon = NSImage(size: box, flipped: false) { rect in
            let size = check.size
            check.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.accessibilityDescription = String(localized: "Copied", bundle: .module)
        return icon
    }

    @objc private func openParent(_ sender: NSButton) {
        guard sender.tag < parentTargets.count else { return }
        onNavigate?(parentTargets[sender.tag])
    }
}

/// The subject of the shown commit; a double click asks to edit the message.
private final class SubjectLabel: NSTextField {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let onDoubleClick else { return super.mouseDown(with: event) }
        onDoubleClick()
    }
}

private final class AvatarView: NSView {
    /// Whose picture to show, as the avatar store looks it up.
    struct Source {
        let email: String
        let commit: String
        let repository: Repository
    }

    private let initials: String
    private let ring: NSColor
    private let source: Source
    private var observer: NSObjectProtocol?

    init(initials: String, ring: NSColor, source: Source) {
        self.initials = initials
        self.ring = ring
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Detail.avatar, height: Theme.Detail.avatar))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Theme.Detail.avatar), heightAnchor.constraint(equalToConstant: Theme.Detail.avatar)])
        observer = NotificationCenter.default.addObserver(forName: AvatarStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: Theme.Stroke.strand / 2, dy: Theme.Stroke.strand / 2))
        Theme.surface2.setFill(); circle.fill()
        if let image = AvatarStore.shared.image(email: source.email, commit: source.commit, in: source.repository), let context = NSGraphicsContext.current?.cgContext {
            AvatarDrawing.draw(image, in: bounds, ring: Theme.Stroke.strand, context: context)
        } else {
            let text = NSAttributedString(string: initials, attributes: [.font: Theme.initials, .foregroundColor: Theme.inkMuted])
            let size = text.size()
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
        ring.setStroke(); circle.lineWidth = Theme.Stroke.strand; circle.stroke()
    }
}
