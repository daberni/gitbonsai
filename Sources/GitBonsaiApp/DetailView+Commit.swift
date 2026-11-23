import AppKit
import GitEngine

/// The header of one commit: subject, body, author and committer, SHA and parents, then its files.
extension DetailView {
    private typealias M = Theme.Detail

    // MARK: Commit

    /// The header is known at once and replaces the old one; the file list and its stats line follow together once git has answered.
    func show(commit: Commit, strand: NSColor, repository: Repository) {
        let previous = commitFiles
        let header = reset(title: String(localized: "detail.commit.title", defaultValue: "Commit", bundle: .module, comment: "Detail panel title for one commit"))
        let access = messageAccess?(commit)
        if let access { addEditButton(to: header, access: access) }
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
        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let bodyLabel = MessageBodyView(body)
            add(bodyLabel)
            messageViews.append(bodyLabel)
        }
        message = (commit.id, messageViews)

        // Author and committer appear separately as soon as anything differs; otherwise one line says both.
        let samePerson = commit.authorName == commit.committerName && commit.authorEmail == commit.committerEmail
        let sameTime = abs(commit.authorDate.timeIntervalSince(commit.committerDate)) < 1
        if samePerson && sameTime {
            add(person(commit.authorName, role: String(localized: "detail.commit.authoredAndCommitted", defaultValue: "Authored and committed", bundle: .module, comment: "Detail panel: role of the one person who wrote and committed a commit, followed by the date"), date: commit.authorDate, ring: strand, avatar: AvatarView.Source(email: commit.authorEmail, commit: commit.id, repository: repository)))
        } else {
            add(person(commit.authorName, role: String(localized: "detail.commit.authored", defaultValue: "Authored", bundle: .module, comment: "Detail panel: role of the commit's author, followed by the date"), date: commit.authorDate, ring: strand, avatar: AvatarView.Source(email: commit.authorEmail, commit: commit.id, repository: repository)))
            add(person(commit.committerName, role: String(localized: "detail.commit.committed", defaultValue: "Committed", bundle: .module, comment: "Detail panel: role of the commit's committer, followed by the date"), date: commit.committerDate, ring: Theme.hairline, avatar: AvatarView.Source(email: commit.committerEmail, commit: commit.id, repository: repository)))
        }

        add(divider())
        let meta = NSStackView()
        meta.orientation = .horizontal
        meta.spacing = Theme.Space.s
        meta.addArrangedSubview(label(String(localized: "detail.meta.commit", defaultValue: "Commit", bundle: .module, comment: "Detail panel title for one commit"), font: Theme.caption, color: Theme.inkMuted))
        copySHA = (full: commit.id, short: commit.shortID)
        let copy = LinkButton(target: self, action: #selector(copyCommitSHA(_:)))
        copy.attributedTitle = NSAttributedString(string: commit.shortID, attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.ink])
        copy.imagePosition = .imageTrailing
        showCopyIcon(on: copy, copied: false)
        meta.addArrangedSubview(copy)
        copyButton = copy
        parentTargets = commit.parents
        parentLinks = []
        if !commit.parents.isEmpty { meta.addArrangedSubview(label(commit.parents.count == 1 ? String(localized: "detail.meta.parent", defaultValue: "Parent", bundle: .module, comment: "Label before the one parent SHA") : String(localized: "detail.meta.parents", defaultValue: "Parents", bundle: .module, comment: "Label before the parent SHAs of a merge"), font: Theme.caption, color: Theme.inkMuted)) }
        for (index, parent) in commit.parents.enumerated() {
            let link = LinkButton(target: self, action: #selector(openParent(_:)))
            link.tag = index
            link.attributedTitle = NSAttributedString(string: String(parent.prefix(RefString.shortSHA)), attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.moss, .underlineStyle: NSUnderlineStyle.single.rawValue])
            link.toolTip = String(localized: "detail.meta.parentToolTip", defaultValue: "Jump to the parent commit in the graph", bundle: .module)
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
            let summary = NSMutableAttributedString(string: String(localized: "detail.files.count", defaultValue: "\(files.count) files", bundle: .module) + " · ", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
            summary.append(FileRowView.statText(total))
            let rows = files.map { file in
                FileRowView.Model(selection: FileSelection(path: file.path, originalPath: file.originalPath, source: .commit(commit)), letter: String(file.state.rawValue), color: file.state.tint, stat: file.stat, note: file.stat == nil && file.state != .deleted ? String(localized: "detail.files.binary", defaultValue: "binary", bundle: .module, comment: "Note on a file row: a binary file without line counts") : nil, state: file.state)
            }
            filesHeader.attributedStringValue = summary
            list.show([FileListView.Section(title: String(localized: "detail.files.title", defaultValue: "Files", bundle: .module, comment: "Section header of a file list"), rows: rows, action: nil)])
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

    private func person(_ name: String, role: String, date: Date, ring: NSColor, avatar source: AvatarView.Source) -> NSView {
        let avatar = AvatarView(initials: GraphRowView.initials(name), ring: ring, source: source)
        let nameLabel = label(name, font: Theme.body, color: Theme.ink)
        let detail = label("\(role) · \(DateText.relative(date))", font: Theme.caption, color: Theme.inkMuted)
        detail.toolTip = DateText.exact(date)
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
        ActionRunner.copy(short ? copySHA.short : copySHA.full)
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
