import AppKit
import GitEngine

/// The right panel. It has no tabs: it follows the selection in the history (a commit, or the working directory).
final class DetailView: NSView {
    private typealias M = Theme.Detail
    var onNavigate: ((String) -> Void)?

    private let stack = NSStackView()
    private var loadTask: Task<Void, Never>?
    private var parentTargets: [String] = []
    private var copySHA = ""

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
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
    }

    private func reset(title: String) {
        loadTask?.cancel()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = label(title.uppercased(), font: Theme.label, color: Theme.inkMuted)
        header.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.heightAnchor.constraint(equalToConstant: M.headerHeight), header.centerYAnchor.constraint(equalTo: box.centerYAnchor), header.leadingAnchor.constraint(equalTo: box.leadingAnchor)])
        stack.addArrangedSubview(box)
    }

    private func label(_ string: String, font: NSFont, color: NSColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = wraps
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Theme.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: Theme.Stroke.hairline).isActive = true
        return line
    }

    private func add(_ view: NSView, fill: Bool = true) {
        stack.addArrangedSubview(view)
        if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.padding).isActive = true }
    }

    // MARK: Commit

    func show(commit: Commit, strand: NSColor, repository: Repository) {
        reset(title: "Commit")
        add(label(commit.subject, font: Theme.title, color: Theme.ink, wraps: true))
        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { add(label(body, font: Theme.body, color: Theme.inkMuted, wraps: true)) }

        // Author and committer appear separately as soon as anything differs; otherwise one line says both.
        let samePerson = commit.authorName == commit.committerName && commit.authorEmail == commit.committerEmail
        let sameTime = abs(commit.authorDate.timeIntervalSince(commit.committerDate)) < 1
        if samePerson && sameTime {
            add(person(commit.authorName, role: "Author und Committer", date: commit.authorDate, ring: strand))
        } else {
            add(person(commit.authorName, role: "Author", date: commit.authorDate, ring: strand))
            add(person(commit.committerName, role: "Committer", date: commit.committerDate, ring: Theme.hairline))
        }

        add(divider())
        let meta = NSStackView()
        meta.orientation = .horizontal
        meta.spacing = Theme.Space.s
        meta.addArrangedSubview(label("Commit", font: Theme.caption, color: Theme.inkMuted))
        copySHA = commit.id
        let copy = NSButton(title: commit.shortID + "  ⧉", target: self, action: #selector(copyCommitSHA(_:)))
        copy.bezelStyle = .inline
        copy.font = Theme.monoSmall
        copy.toolTip = "Vollen SHA kopieren: \(commit.id)"
        meta.addArrangedSubview(copy)
        parentTargets = commit.parents
        if !commit.parents.isEmpty { meta.addArrangedSubview(label(commit.parents.count > 1 ? "Parents" : "Parent", font: Theme.caption, color: Theme.inkMuted)) }
        for (index, parent) in commit.parents.enumerated() {
            let link = NSButton(title: "", target: self, action: #selector(openParent(_:)))
            link.isBordered = false
            link.tag = index
            link.attributedTitle = NSAttributedString(string: String(parent.prefix(7)), attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.moss, .underlineStyle: NSUnderlineStyle.single.rawValue])
            link.toolTip = "Zum Parent-Commit im Graph springen"
            meta.addArrangedSubview(link)
        }
        add(meta, fill: false)
        add(divider())

        let filesHeader = label("Dateien werden geladen …", font: Theme.caption, color: Theme.inkMuted)
        add(filesHeader)
        loadTask = Task { [weak self] in
            let files = (try? await repository.changedFiles(of: commit)) ?? []
            guard let self, !Task.isCancelled else { return }
            filesHeader.stringValue = files.count == 1 ? "1 Datei" : "\(files.count) Dateien"
            for file in files.prefix(M.maximumFiles) { add(fileRow(path: file.path, letter: String(file.state.rawValue), color: Self.color(for: file.state))) }
            if files.count > 200 { add(label("… und \(files.count - 200) weitere", font: Theme.caption, color: Theme.inkMuted)) }
        }
    }

    // MARK: Working directory

    func showWorkingDirectory(status: RepositoryStatus) {
        reset(title: "Working Directory")
        func list(_ title: String, _ entries: [StatusEntry], state: (StatusEntry) -> (String, NSColor)) {
            add(label("\(title.uppercased())  \(entries.count)", font: Theme.label, color: Theme.inkMuted))
            for entry in entries.prefix(M.maximumFiles) {
                let (letter, color) = state(entry)
                add(fileRow(path: entry.path, letter: letter, color: color))
            }
        }
        list("Unstaged", status.unstaged) { entry in
            entry.isUntracked ? ("?", Theme.inkMuted) : (String(entry.worktreeState.rawValue), Self.color(for: entry.worktreeState))
        }
        add(divider())
        list("Staged", status.staged) { entry in (String(entry.indexState.rawValue), Self.color(for: entry.indexState)) }
        if status.hasConflicts {
            add(divider())
            list("Konflikte", status.conflicted) { _ in ("U", Theme.persimmon) }
        }
    }

    func showNothing() {
        reset(title: "Auswahl")
    }

    // MARK: Parts

    private static func color(for state: FileState) -> NSColor {
        switch state {
        case .added: Theme.moss
        case .deleted, .unmerged: Theme.persimmon
        case .renamed, .copied: Theme.sky
        default: Theme.ochre
        }
    }

    private func person(_ name: String, role: String, date: Date, ring: NSColor) -> NSView {
        let avatar = AvatarView(initials: GraphRowView.initials(name), ring: ring)
        let nameLabel = label(name, font: Theme.body, color: Theme.ink)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
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

    private func fileRow(path: String, letter: String, color: NSColor) -> NSView {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let text = NSMutableAttributedString(string: letter + "  ", attributes: [.font: Theme.monoStrong, .foregroundColor: color])
        if !directory.isEmpty { text.append(NSAttributedString(string: directory + "/", attributes: [.font: Theme.mono, .foregroundColor: Theme.inkMuted])) }
        text.append(NSAttributedString(string: name, attributes: [.font: Theme.mono, .foregroundColor: Theme.ink]))
        let field = NSTextField(labelWithAttributedString: text)
        // When space runs out the folder path gives way, never the file name.
        field.lineBreakMode = .byTruncatingHead
        field.toolTip = path
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    @objc private func copyCommitSHA(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copySHA, forType: .string)
    }

    @objc private func openParent(_ sender: NSButton) {
        guard sender.tag < parentTargets.count else { return }
        onNavigate?(parentTargets[sender.tag])
    }
}

private final class AvatarView: NSView {
    private let initials: String
    private let ring: NSColor

    init(initials: String, ring: NSColor) {
        self.initials = initials
        self.ring = ring
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Detail.avatar, height: Theme.Detail.avatar))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Theme.Detail.avatar), heightAnchor.constraint(equalToConstant: Theme.Detail.avatar)])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: Theme.Stroke.strand / 2, dy: Theme.Stroke.strand / 2))
        Theme.surface2.setFill(); circle.fill()
        ring.setStroke(); circle.lineWidth = Theme.Stroke.strand; circle.stroke()
        let text = NSAttributedString(string: initials, attributes: [.font: Theme.initials, .foregroundColor: Theme.inkMuted])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
