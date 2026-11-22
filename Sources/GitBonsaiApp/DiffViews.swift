import AppKit
import GitEngine

/// The bar above a file diff: the way back to the graph (also the close button and Esc), the change kind and the file (both paths for a rename), its counts, the choice between diff and whole file, hunk navigation and the file-wide action.
final class DiffHeaderView: BarView {
    var onBack: (() -> Void)?
    var onModeChange: ((DiffMode) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onFileAction: (() -> Void)?

    private let back = NSButton()
    private let indicator = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private let stat = NSTextField(labelWithString: "")
    let modes = NSSegmentedControl(labels: DiffMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let previous = NSButton()
    let next = NSButton()
    private let fileAction = NSButton()
    let close = NSButton()

    init() {
        super.init(edge: .bottom)
        back.title = String(localized: "Graph", bundle: .module, comment: "Button back from a diff to the history graph")
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.imagePosition = .imageLeading
        back.bezelStyle = .rounded
        back.target = self
        back.action = #selector(goBack(_:))
        back.keyEquivalent = "\u{1b}"
        // One line at a constant height: the folder gives way from the front before the file name, like in the file lists; for a rename the old part goes before the new one.
        title.usesSingleLineMode = true
        title.maximumNumberOfLines = 1
        title.cell?.wraps = false
        title.lineBreakMode = .byTruncatingHead
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        indicator.font = Theme.monoStrong
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (button, symbol, action, tip) in [(previous, "chevron.up", #selector(goPrevious(_:)), String(localized: "Previous Hunk", bundle: .module)), (next, "chevron.down", #selector(goNext(_:)), String(localized: "Next Hunk", bundle: .module))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        modes.target = self
        modes.action = #selector(changeMode(_:))
        modes.toolTip = String(localized: "Show only the changes or the whole file", bundle: .module)
        let closeSymbol = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close", bundle: .module))?.withSymbolConfiguration(closeSymbol)
        close.bezelStyle = .rounded
        close.toolTip = String(localized: "Close (Esc)", bundle: .module)
        close.target = self
        close.action = #selector(goBack(_:))
        fileAction.bezelStyle = .rounded
        fileAction.target = self
        fileAction.action = #selector(runFileAction(_:))

        let leading = NSStackView(views: [back, indicator, title, badge, stat])
        leading.spacing = Theme.Space.m
        leading.setCustomSpacing(Theme.Space.s, after: indicator)
        let trailing = NSStackView(views: [modes, previous, next, fileAction, close])
        trailing.spacing = Theme.Space.s
        trailing.setCustomSpacing(Theme.Space.m, after: modes)
        trailing.setCustomSpacing(Theme.Space.m, after: fileAction)
        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Theme.Space.m),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ selection: FileSelection, diff: FileDiff?, mode: DiffMode) {
        let change = DiffChange(selection: selection, diff: diff)
        indicator.stringValue = change.letter
        indicator.textColor = change.color
        indicator.isHidden = change.letter.isEmpty
        indicator.toolTip = change.word
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let muted: [NSAttributedString.Key: Any] = [.font: Theme.body, .foregroundColor: Theme.inkMuted, .paragraphStyle: paragraph]
        let path = change.oldPath.map { RenamedPath.text(old: $0, new: selection.path) } ?? selection.path
        let name = selection.name
        let text = NSMutableAttributedString(string: String(path.dropLast(name.count)), attributes: muted)
        text.append(NSAttributedString(string: name, attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]))
        title.attributedStringValue = text
        title.toolTip = change.description
        switch selection.source {
        case .commit: badge.text = nil
        case .revisions(let base, let target): badge.text = "\(base.prefix(7)) → \(target.prefix(7))"
        case .unstaged: badge.text = String(localized: "unstaged", bundle: .module, comment: "Badge on a diff of unstaged changes")
        case .staged: badge.text = String(localized: "staged", bundle: .module, comment: "Badge on a diff of staged changes")
        case .untracked: badge.text = String(localized: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet")
        }
        stat.attributedStringValue = diff.map { FileRowView.statText($0.stat) } ?? NSAttributedString()
        // Binary files and files without changes have nothing to show in full.
        modes.isHidden = diff.map { $0.isBinary || $0.hunks.isEmpty } ?? true
        modes.selectedSegment = DiffMode.allCases.firstIndex(of: mode) ?? 0
        let hasHunks = (diff?.hunks.count ?? 0) > 1
        previous.isHidden = !hasHunks
        next.isHidden = !hasHunks
        fileAction.isHidden = !(selection.isStageable || selection.isUnstageable) || diff == nil
        fileAction.title = selection.isUnstageable ? String(localized: "Unstage File", bundle: .module) : String(localized: "Stage File", bundle: .module)
    }

    /// The change letter, the path as shown and its tooltip; harness checks print them.
    var summary: String {
        "\(indicator.isHidden ? "-" : indicator.stringValue) \(title.stringValue) | \(title.toolTip ?? "")"
    }

    @objc private func goBack(_ sender: Any?) { onBack?() }
    @objc private func changeMode(_ sender: Any?) {
        guard DiffMode.allCases.indices.contains(modes.selectedSegment) else { return }
        onModeChange?(DiffMode.allCases[modes.selectedSegment])
    }
    @objc private func goPrevious(_ sender: Any?) { onPrevious?() }
    @objc private func goNext(_ sender: Any?) { onNext?() }
    @objc private func runFileAction(_ sender: Any?) { onFileAction?() }
}

/// What happened to the file shown, with the letter and colour of the file lists, and the sentence its tooltip says.
struct DiffChange {
    let letter: String
    let color: NSColor
    let word: String
    /// Set for a rename or copy.
    let oldPath: String?
    let description: String

    @MainActor init(selection: FileSelection, diff: FileDiff?) {
        let state: FileState? = selection.source == .untracked ? nil : diff?.change ?? (selection.originalPath == nil ? nil : .renamed)
        oldPath = diff?.oldPath ?? selection.originalPath
        if selection.source == .untracked {
            letter = "?"
            color = Theme.inkMuted
            word = String(localized: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet")
        } else if let state {
            letter = String(state.rawValue)
            color = state.tint
            word = Self.word(for: state)
        } else {
            letter = ""
            color = Theme.inkMuted
            word = ""
        }
        var lines: [String] = []
        if let oldPath {
            lines.append(Self.move(copied: state == .copied, from: oldPath, to: selection.path, similarity: diff?.similarity))
        } else {
            lines.append(selection.path)
        }
        if let diff, diff.modeChanged, let oldMode = diff.oldMode, let newMode = diff.newMode { lines.append(String(localized: "File mode \("\(oldMode) → \(newMode)")", bundle: .module, comment: "e.g. File mode 100644 → 100755")) }
        description = lines.joined(separator: "\n")
    }

    /// A path with an old path was renamed unless git says it was copied.
    private static func move(copied: Bool, from oldPath: String, to path: String, similarity: Int?) -> String {
        switch (copied, similarity) {
        case (true, let similarity?): String(localized: "copied from \(oldPath) to \(path) (similarity \(similarity) %)", bundle: .module)
        case (true, nil): String(localized: "copied from \(oldPath) to \(path)", bundle: .module)
        case (false, let similarity?): String(localized: "renamed from \(oldPath) to \(path) (similarity \(similarity) %)", bundle: .module)
        case (false, nil): String(localized: "renamed from \(oldPath) to \(path)", bundle: .module)
        }
    }

    private static func word(for state: FileState) -> String {
        switch state {
        case .added: String(localized: "added", bundle: .module, comment: "What happened to a file")
        case .deleted: String(localized: "deleted", bundle: .module, comment: "What happened to a file")
        case .renamed: String(localized: "renamed", bundle: .module, comment: "What happened to a file")
        case .copied: String(localized: "copied", bundle: .module, comment: "What happened to a file")
        case .typeChanged: String(localized: "type changed", bundle: .module, comment: "What happened to a file")
        case .unmerged: String(localized: "conflict", bundle: .module, comment: "Note on a file row: the file has unresolved conflicts")
        case .modified, .unmodified: String(localized: "modified", bundle: .module, comment: "What happened to a file")
        }
    }
}

/// The old and new path of a rename around the leading and trailing folders they share, as `git diff --stat` writes them, so both fit on one line:
/// `src/{transactions → ledger}/server/repository.ts`, or `docs/old.md → new.md` when only the name changed.
enum RenamedPath {
    static func text(old: String, new: String) -> String {
        let oldParts = old.split(separator: "/", omittingEmptySubsequences: false)
        let newParts = new.split(separator: "/", omittingEmptySubsequences: false)
        // Each side keeps at least one component of its own.
        let limit = min(oldParts.count, newParts.count) - 1
        let shared = zip(oldParts, newParts).prefix { $0 == $1 }.count
        let leading = min(shared, limit)
        let trailing = min(zip(oldParts.reversed(), newParts.reversed()).prefix { $0 == $1 }.count, limit - leading)
        let prefix = oldParts.prefix(leading).map { $0 + "/" }.joined()
        let suffix = oldParts.suffix(trailing).map { "/" + $0 }.joined()
        let oldMiddle = oldParts[leading..<(oldParts.count - trailing)].joined(separator: "/")
        let newMiddle = newParts[leading..<(newParts.count - trailing)].joined(separator: "/")
        return suffix.isEmpty ? "\(prefix)\(oldMiddle) → \(newMiddle)" : "\(prefix){\(oldMiddle) → \(newMiddle)}\(suffix)"
    }
}

/// A small capsule with a word in it, for "unstaged" and the like.
final class BadgeView: NSView {
    var text: String? { didSet { isHidden = text == nil; invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var attributed: NSAttributedString { NSAttributedString(string: text ?? "", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted]) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: attributed.size().width + 2 * Theme.Diff.badgePadding, height: Theme.Diff.badgeHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.surface2.setFill()
        path.fill()
        Theme.hairline.setStroke()
        path.stroke()
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// One line of a diff: old and new line number, the sign, the text. Added and removed lines are tinted.
final class DiffLineView: NSView {
    var line: DiffLine? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let line else { return }
        typealias D = Theme.Diff
        let tint: NSColor? = switch line.kind {
        case .added: Theme.moss
        case .removed: Theme.persimmon
        case .context: nil
        }
        let numbers = CGRect(x: 0, y: 0, width: 2 * D.numberColumn, height: bounds.height)
        if let tint {
            tint.withAlphaComponent(D.lineTint).setFill()
            bounds.fill()
            tint.withAlphaComponent(D.numberTint).setFill()
            numbers.fill()
        } else {
            Theme.surface1.setFill()
            numbers.fill()
        }
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: Theme.inkFaint]
        func number(_ value: Int?, columnEnd: CGFloat) {
            guard let value else { return }
            let text = NSAttributedString(string: "\(value)", attributes: numberAttributes)
            text.draw(at: CGPoint(x: columnEnd - D.textInset - text.size().width, y: bounds.midY - text.size().height / 2))
        }
        number(line.oldNumber, columnEnd: D.numberColumn)
        number(line.newNumber, columnEnd: 2 * D.numberColumn)
        let sign = switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
        let signText = NSAttributedString(string: sign, attributes: [.font: Theme.mono, .foregroundColor: tint ?? Theme.inkMuted])
        signText.draw(at: CGPoint(x: numbers.maxX + D.textInset, y: bounds.midY - signText.size().height / 2))
        let body = NSMutableAttributedString(string: Self.display(line.text), attributes: [.font: Theme.mono, .foregroundColor: Theme.ink])
        if line.missingNewline { body.append(NSAttributedString(string: "  " + String(localized: "⏎ missing at end of file", bundle: .module, comment: "Marks a last line without a newline"), attributes: [.font: Theme.caption, .foregroundColor: Theme.inkFaint])) }
        body.draw(at: CGPoint(x: Self.textX, y: bounds.midY - body.size().height / 2))
    }

    static var textX: CGFloat { 2 * Theme.Diff.numberColumn + Theme.Diff.textInset + Theme.Diff.signColumn }

    /// Tabs as spaces, so columns line up as in an editor.
    static func display(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: Theme.Diff.tabWidth))
    }
}

/// The header of one hunk: its range and section, and the actions for this hunk alone.
final class DiffHunkView: NSView {
    var onAction: (() -> Void)?
    var onDiscard: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let action = NSButton()
    let discard = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Theme.mono
        label.textColor = Theme.inkMuted
        label.lineBreakMode = .byTruncatingTail
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.target = self
        action.action = #selector(run(_:))
        discard.bezelStyle = .rounded
        discard.controlSize = .small
        discard.title = String(localized: "Discard Hunk", bundle: .module)
        discard.target = self
        discard.action = #selector(runDiscard(_:))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(discard)
        addSubview(action)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffLineView.textX - Theme.Diff.signColumn),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.Diff.hunkLabelWidth),
        ])
    }

    /// The buttons keep to the right edge of what is visible, also while long lines scroll the diff sideways; discarding sits left of staging.
    override func layout() {
        super.layout()
        action.sizeToFit()
        discard.sizeToFit()
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        action.setFrameOrigin(NSPoint(x: visible.maxX - Theme.Space.m - action.frame.width, y: (bounds.height - action.frame.height) / 2))
        discard.setFrameOrigin(NSPoint(x: action.frame.minX - Theme.Space.s - discard.frame.width, y: (bounds.height - discard.frame.height) / 2))
    }

    required init?(coder: NSCoder) { nil }

    func show(_ hunk: DiffHunk, actionTitle: String?, canDiscard: Bool) {
        label.stringValue = hunk.header
        action.title = actionTitle ?? ""
        action.isHidden = actionTitle == nil
        discard.isHidden = !canDiscard
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Stroke.hairline).fill()
        NSRect(x: 0, y: bounds.height - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
    }

    @objc private func run(_ sender: Any?) { onAction?() }
    @objc private func runDiscard(_ sender: Any?) { onDiscard?() }
}
