import AppKit
import GitEngine

/// The header of one commit: subject, body, trailers, author, committer and co-authors, SHA and parents, then its files.
extension DetailView {
    private typealias M = Theme.Detail

    // MARK: Commit

    /// The header is known at once and replaces the old one; the file list and its stats line follow together once git has answered.
    /// A stash lists its files like the working directory it was taken from, staged and unstaged, and names only the commit it was made on as its parent.
    func show(commit: Commit, strand: NSColor, repository: Repository, isStash: Bool = false) {
        let previous = commitFiles
        let header = reset(title: String(localized: "detail.commit.title", defaultValue: "Commit", bundle: .module, comment: "Detail panel title for one commit"))
        let access = messageAccess?(commit)
        if let access { addEditButton(to: header, access: access) }
        addMeta(commit: (commit.id, commit.shortID), parents: isStash ? Array(commit.parents.prefix(1)) : commit.parents)
        let subject = SubjectLabel(wrappingLabelWithString: commit.subject)
        subject.font = Theme.title
        subject.textColor = Theme.ink
        // Selectable and copyable like the body below it.
        subject.isSelectable = true
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if access == .allowed {
            subject.onDoubleClick = { [weak self] in self?.onEditMessage?() }
            subject.toolTip = String(localized: "detail.commit.subjectToolTip", defaultValue: "Double-click to edit the message (\(CommandShortcut.editMessage.display))", bundle: .module)
        }
        add(subject)
        subjectLabel = subject
        var messageViews: [NSView] = [subject]
        // Trailers read as data, not prose: co-authors join the people below, the rest form a key/value block.
        let body = CommitTrailer.body(commit.body, without: commit.trailers).trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let bodyLabel = MessageBodyView(body)
            add(bodyLabel)
            messageViews.append(bodyLabel)
        }
        let otherTrailers = commit.trailers.filter { !$0.isCoAuthor }
        if !otherTrailers.isEmpty {
            let block = trailerBlock(otherTrailers)
            add(block, fill: false)
            messageViews.append(block)
        }
        message = (commit.id, messageViews)

        // Author and committer appear separately as soon as anything differs; otherwise one line says both.
        let samePerson = commit.authorName == commit.committerName && commit.authorEmail == commit.committerEmail
        let sameTime = abs(commit.authorDate.timeIntervalSince(commit.committerDate)) < 1
        if samePerson && sameTime {
            add(person(commit.authorName, role: String(localized: "detail.commit.authoredAndCommitted", defaultValue: "Authored and committed", bundle: .module, comment: "Detail panel: role of the one person who wrote and committed a commit, followed by the date"), date: commit.authorDate, ring: strand, avatar: AvatarView.Source(email: commit.authorEmail, commit: commit.id, repository: repository, store: avatars)))
        } else {
            add(person(commit.authorName, role: String(localized: "detail.commit.authored", defaultValue: "Authored", bundle: .module, comment: "Detail panel: role of the commit's author, followed by the date"), date: commit.authorDate, ring: strand, avatar: AvatarView.Source(email: commit.authorEmail, commit: commit.id, repository: repository, store: avatars)))
            add(person(commit.committerName, role: String(localized: "detail.commit.committed", defaultValue: "Committed", bundle: .module, comment: "Detail panel: role of the commit's committer, followed by the date"), date: commit.committerDate, ring: Theme.hairline, avatar: AvatarView.Source(email: commit.committerEmail, commit: commit.id, repository: repository, store: avatars)))
        }
        for coAuthor in commit.coAuthors {
            let identity = coAuthor.person
            add(person(identity.name, role: String(localized: "detail.commit.coAuthored", defaultValue: "Co-Author", bundle: .module, comment: "Detail panel: role of a person named in a Co-authored-by trailer"), date: nil, ring: Theme.hairline, avatar: AvatarView.Source(email: identity.email, commit: commit.id, repository: repository, store: avatars)))
        }

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
            let sections: [FileListView.Section]
            let all: [ChangedFile]
            if isStash {
                let changes = (try? await repository.stashChanges(of: commit)) ?? StashChanges(staged: [], unstaged: [], untracked: [], untrackedCommit: nil)
                sections = Self.stashSections(changes, of: commit)
                all = changes.staged + changes.unstaged + changes.untracked
            } else {
                all = (try? await repository.changedFiles(of: commit)) ?? []
                sections = [FileListView.Section(title: String(localized: "detail.files.title", defaultValue: "Files", bundle: .module, comment: "Section header of a file list"), rows: all.map { Self.row($0, source: .commit(commit)) })]
            }
            guard let self, !Task.isCancelled else { return }
            loadingNoteTask?.cancel()
            let total = all.compactMap(\.stat).reduce(DiffStat(added: 0, removed: 0)) { DiffStat(added: $0.added + $1.added, removed: $0.removed + $1.removed) }
            let summary = NSMutableAttributedString(string: String(localized: "detail.files.count", defaultValue: "\(all.count) files", bundle: .module) + " · ", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
            summary.append(FileRowView.statText(total))
            filesHeader.attributedStringValue = summary
            list.show(sections)
        }
        // A quick answer swaps the lists without anything in between; a slow one gets a note in place, at the old height.
        let deadline = filesOutdatedSince + M.loadingDelay
        loadingNoteTask = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            filesHeader.stringValue = String(localized: "detail.files.loading", defaultValue: "Loading files…", bundle: .module)
            list.freshness = .loading
        }
    }

    // MARK: Parts

    /// The SHA beside the panel's title and the parent links at the right of its title line, so the parent link sits in one place for commits, merges, stashes and the working directory, whose parent is HEAD.
    func addMeta(commit: (id: String, shortID: String)?, parents: [String]) {
        guard let row = titleRow?.lead, let parentRow = titleRow?.parents else { return }
        if let title = row.arrangedSubviews.first { row.setCustomSpacing(Theme.Space.m, after: title) }
        func keep(_ view: NSView, in row: NSStackView) {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(view)
        }
        if let commit {
            copySHA = (full: commit.id, short: commit.shortID)
            let copy = LinkButton(target: self, action: #selector(copyCommitSHA(_:)))
            copy.attributedTitle = NSAttributedString(string: commit.shortID, attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.ink])
            copy.imagePosition = .imageTrailing
            showCopyIcon(on: copy, copied: false)
            keep(copy, in: row)
            copyButton = copy
        } else {
            copyButton = nil
        }
        parentTargets = parents
        parentLinks = []
        if !parents.isEmpty {
            // After the title, the word before the parents gives way; the SHAs stay readable.
            let caption = label(parents.count == 1 ? String(localized: "detail.meta.parent", defaultValue: "Parent", bundle: .module, comment: "Label before the one parent SHA") : String(localized: "detail.meta.parents", defaultValue: "Parents", bundle: .module, comment: "Label before the parent SHAs of a merge"), font: Theme.caption, color: Theme.inkMuted)
            caption.lineBreakMode = .byTruncatingTail
            caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            parentRow.addArrangedSubview(caption)
        }
        for (index, parent) in parents.enumerated() {
            let link = LinkButton(target: self, action: #selector(openParent(_:)))
            link.tag = index
            link.attributedTitle = NSAttributedString(string: String(parent.prefix(RefString.shortSHA)), attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.moss, .underlineStyle: NSUnderlineStyle.single.rawValue])
            link.toolTip = String(localized: "detail.meta.parentToolTip", defaultValue: "Jump to the parent commit in the graph", bundle: .module)
            keep(link, in: parentRow)
            parentLinks.append(link)
        }
        addTitleSeparator()
    }

    private static func row(_ file: ChangedFile, source: DiffSource) -> FileRowView.Model {
        FileRowView.Model(selection: FileSelection(path: file.path, originalPath: file.originalPath, source: source), letter: String(file.state.rawValue), color: file.state.tint, stat: file.stat, note: file.stat == nil && file.state != .deleted ? String(localized: "detail.files.binary", defaultValue: "binary", bundle: .module, comment: "Note on a file row: a binary file without line counts") : nil, state: file.state)
    }

    /// The areas of the working directory in its order: the working tree's changes with the untracked files, then the index. Files are only looked at, not staged.
    private static func stashSections(_ changes: StashChanges, of stash: Commit) -> [FileListView.Section] {
        let base = stash.parents[0]
        let index = stash.parents.count > 1 ? stash.parents[1] : base
        var unstaged = changes.unstaged.map { row($0, source: .revisions(base: index, target: stash.id)) }
        if let untrackedCommit = changes.untrackedCommit {
            unstaged += changes.untracked.map { file in
                FileRowView.Model(selection: FileSelection(path: file.path, originalPath: nil, source: .added(commit: untrackedCommit)), letter: "?", color: Theme.inkMuted, stat: file.stat, note: String(localized: "files.state.untracked", defaultValue: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet"), state: nil)
            }
        }
        let staged = changes.staged.map { row($0, source: .revisions(base: base, target: index)) }
        return [
            FileListView.Section(title: String(localized: "detail.files.unstaged", defaultValue: "Unstaged  \(unstaged.count)", bundle: .module, comment: "File list section header with its count"), rows: unstaged),
            FileListView.Section(title: String(localized: "detail.files.staged", defaultValue: "Staged  \(staged.count)", bundle: .module, comment: "File list section header with its count"), rows: staged),
        ]
    }

    /// `date` is nil for a co-author, whose trailer has none.
    private func person(_ name: String, role: String, date: Date?, ring: NSColor, avatar source: AvatarView.Source) -> NSView {
        let avatar = AvatarView(initials: GraphRowView.initials(name), ring: ring, source: source)
        let nameLabel = label(name, font: Theme.body, color: Theme.ink)
        let detail = label(date.map { "\(role) · \(DateText.relative($0))" } ?? role, font: Theme.caption, color: Theme.inkMuted)
        detail.toolTip = date.map(DateText.exact)
        let text = NSStackView(views: [nameLabel, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = M.personLineGap
        let row = NSStackView(views: [avatar, text])
        row.orientation = .horizontal
        row.spacing = M.spacing
        return row
    }

    /// Keys muted in one column, values selectable beside them, as git wrote them.
    private func trailerBlock(_ trailers: [CommitTrailer]) -> NSView {
        let rows = trailers.map { trailer -> [NSView] in
            let value = label(trailer.value, font: Theme.caption, color: Theme.ink)
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingTail
            value.toolTip = trailer.line
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [label(trailer.key, font: Theme.caption, color: Theme.inkMuted), value]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = M.trailerRowGap
        grid.columnSpacing = Theme.Space.s
        grid.setAccessibilityIdentifier("detail.commit.trailers")
        return grid
    }

    /// A click copies the full SHA, ⌥-click the short one; the icon turns into a checkmark for a moment as the confirmation.
    @objc private func copyCommitSHA(_ sender: NSButton) {
        let short = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        pasteboard.copy(short ? copySHA.short : copySHA.full)
        showCopyIcon(on: sender, copied: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + M.copiedFeedback) { [weak self, weak sender] in
            guard let self, let sender else { return }
            showCopyIcon(on: sender, copied: false)
        }
    }

    private func showCopyIcon(on button: NSButton, copied: Bool) {
        button.image = Self.copyIcon(copied: copied)
        button.toolTip = copied ? String(localized: "common.copied", defaultValue: "Copied", bundle: .module) : String(localized: "detail.meta.copySHAToolTip", defaultValue: "Copy the full SHA, with ⌥ the short one: \(copySHA.full)", bundle: .module)
    }

    /// Both states share the box and the alignment rect of the copy symbol, so the checkmark changes neither the button's size nor its baseline and nothing around it moves.
    private static func copyIcon(copied: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Theme.monoSmall.pointSize, weight: .regular).applying(.init(paletteColors: [copied ? Theme.moss : Theme.inkMuted]))
        guard let copy = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        guard copied, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            copy.accessibilityDescription = String(localized: "common.copySHA", defaultValue: "Copy SHA", bundle: .module)
            return copy
        }
        let box = copy.size
        let icon = NSImage(size: box, flipped: false) { rect in
            let size = check.size
            check.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.alignmentRect = copy.alignmentRect
        icon.accessibilityDescription = String(localized: "common.copied", defaultValue: "Copied", bundle: .module)
        return icon
    }

    @objc private func openParent(_ sender: NSButton) {
        guard sender.tag < parentTargets.count else { return }
        onNavigate?(parentTargets[sender.tag])
    }
}

/// The subject of the shown commit, selectable like the body; a double click asks to edit the message.
/// Once a click made the field selectable, later clicks go to the window's field editor, so the double click is caught before it reaches it.
private final class SubjectLabel: NSTextField {
    var onDoubleClick: (() -> Void)? {
        didSet { updateMonitor() }
    }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitor()
    }

    private func updateMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil, onDoubleClick != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount == 2, event.window === window, let onDoubleClick else { return event }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
            onDoubleClick()
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let onDoubleClick else { return super.mouseDown(with: event) }
        onDoubleClick()
    }
}
