import AppKit
import GitEngine

/// The bar above a file diff: the change kind and the file (both paths for a rename), its counts, the choice between diff and whole file, hunk navigation, the file-wide action and the close button (also Esc), which brings the graph back.
final class DiffHeaderView: BarView {
    var onClose: (() -> Void)?
    var onModeChange: ((DiffMode) -> Void)?
    var onOptionsChange: ((DiffOptions) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onFileAction: (() -> Void)?
    var onImageModeChange: ((ImageDiffMode) -> Void)?
    /// One file among several stacked ones: the stack closes them all and scrolls through them, so close and hunk navigation are left out.
    var isEmbedded = false {
        didSet {
            close.isHidden = isEmbedded
            close.keyEquivalent = isEmbedded ? "" : "\u{1b}"
        }
    }

    private let indicator = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private let stat = NSTextField(labelWithString: "")
    let modes = NSSegmentedControl(labels: DiffMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    /// Takes the place of `modes` for a changed image.
    let imageModes = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var offeredImageModes: [ImageDiffMode] = []
    /// Options of how a diff is shown; word diff and ignoring whitespace are to join "Show invisible characters" here.
    let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let invisiblesItem = NSMenuItem(title: String(localized: "diff.options.invisibles", defaultValue: "Show invisible characters", bundle: .module, comment: "Diff option: mark tabs, trailing spaces, line endings and characters without a glyph"), action: nil, keyEquivalent: "")
    private var options = DiffOptions()
    private let previous = NSButton()
    let next = NSButton()
    private let fileAction = NSButton()
    let close = NSButton()

    init() {
        super.init(edge: .bottom)
        // One line at a constant height: the folder gives way from the front before the file name, like in the file lists; for a rename the old part goes before the new one.
        title.usesSingleLineMode = true
        title.maximumNumberOfLines = 1
        title.cell?.wraps = false
        title.lineBreakMode = .byTruncatingHead
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        indicator.font = Theme.monoStrong
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (button, symbol, action, tip) in [(previous, "chevron.up", #selector(goPrevious(_:)), String(localized: "diff.toolbar.previousHunk", defaultValue: "Previous Hunk", bundle: .module)), (next, "chevron.down", #selector(goNext(_:)), String(localized: "diff.toolbar.nextHunk", defaultValue: "Next Hunk", bundle: .module))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        modes.target = self
        modes.action = #selector(changeMode(_:))
        modes.toolTip = String(localized: "diff.toolbar.modeToolTip", defaultValue: "Show only the changes or the whole file", bundle: .module)
        imageModes.target = self
        imageModes.action = #selector(changeImageMode(_:))
        imageModes.toolTip = String(localized: "diff.image.modeToolTip", defaultValue: "Compare the images side by side, with a swipe line or faded over each other", bundle: .module)
        imageModes.isHidden = true
        configureOptions()
        let closeSymbol = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "diff.toolbar.close", defaultValue: "Close", bundle: .module))?.withSymbolConfiguration(closeSymbol)
        close.bezelStyle = .rounded
        close.toolTip = String(localized: "diff.toolbar.closeToolTip", defaultValue: "Close (Esc)", bundle: .module)
        close.target = self
        close.action = #selector(closeDiff(_:))
        close.keyEquivalent = "\u{1b}"
        fileAction.bezelStyle = .rounded
        fileAction.target = self
        fileAction.action = #selector(runFileAction(_:))

        let leading = NSStackView(views: [indicator, title, badge, stat])
        leading.spacing = Theme.Space.m
        leading.setCustomSpacing(Theme.Space.s, after: indicator)
        let trailing = NSStackView(views: [modes, imageModes, optionsButton, previous, next, fileAction, close])
        trailing.spacing = Theme.Space.s
        trailing.setCustomSpacing(Theme.Space.m, after: optionsButton)
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

    private func configureOptions() {
        optionsButton.bezelStyle = .rounded
        optionsButton.imagePosition = .imageOnly
        optionsButton.toolTip = String(localized: "diff.toolbar.options", defaultValue: "Diff Options", bundle: .module, comment: "Tooltip of the menu with options of how a diff is shown")
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: optionsButton.toolTip)
        optionsButton.menu?.addItem(face)
        invisiblesItem.target = self
        invisiblesItem.action = #selector(toggleInvisibles(_:))
        optionsButton.menu?.addItem(invisiblesItem)
    }

    func show(_ selection: FileSelection, diff: FileDiff?, mode: DiffMode, options: DiffOptions) {
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
        case .revisions(let base, let target): badge.text = "\(base.prefix(RefString.shortSHA)) → \(target.prefix(RefString.shortSHA))"
        case .unstaged: badge.text = String(localized: "files.state.unstaged", defaultValue: "unstaged", bundle: .module, comment: "Badge on a diff of unstaged changes")
        case .staged: badge.text = String(localized: "files.state.staged", defaultValue: "staged", bundle: .module, comment: "Badge on a diff of staged changes")
        case .untracked: badge.text = String(localized: "files.state.untracked", defaultValue: "untracked", bundle: .module, comment: "Note on a file row: a file git does not track yet")
        }
        stat.attributedStringValue = diff.map { FileRowView.statText($0.stat) } ?? NSAttributedString()
        // Binary files and files without changes have nothing to show in full.
        modes.isHidden = diff.map { $0.isBinary || $0.hunks.isEmpty } ?? true
        modes.selectedSegment = DiffMode.allCases.firstIndex(of: mode) ?? 0
        optionsButton.isHidden = modes.isHidden
        self.options = options
        invisiblesItem.state = options.showsInvisibles ? .on : .off
        let hasHunks = (diff?.hunks.count ?? 0) > 1 && !isEmbedded
        previous.isHidden = !hasHunks
        next.isHidden = !hasHunks
        fileAction.isHidden = !(selection.isStageable || selection.isUnstageable) || diff == nil
        fileAction.title = selection.isUnstageable ? String(localized: "diff.toolbar.unstageFile", defaultValue: "Unstage file", bundle: .module) : String(localized: "diff.toolbar.stageFile", defaultValue: "Stage file", bundle: .module)
    }

    /// For a changed image the image modes replace "Diff | Whole file", except in the text mode; outside it there are no hunks to step through. Nil puts the diff modes back.
    func showImageModes(_ mode: ImageDiffMode?, offered: [ImageDiffMode]) {
        offeredImageModes = offered
        imageModes.isHidden = mode == nil || offered.count < 2
        guard let mode else { return }
        imageModes.segmentCount = offered.count
        for (index, offeredMode) in offered.enumerated() {
            imageModes.setLabel(offeredMode.title, forSegment: index)
            imageModes.setWidth(0, forSegment: index)
        }
        imageModes.selectedSegment = offered.firstIndex(of: mode) ?? 0
        // The text of an SVG keeps "Diff | Whole file" and the options beside the image toggle.
        guard mode != .text else { return }
        modes.isHidden = true
        optionsButton.isHidden = true
        previous.isHidden = true
        next.isHidden = true
    }

    /// The change letter, the path as shown and its tooltip; harness checks print them.
    var summary: String {
        "\(indicator.isHidden ? "-" : indicator.stringValue) \(title.stringValue) | \(title.toolTip ?? "")"
    }

    @objc private func closeDiff(_ sender: Any?) { onClose?() }
    @objc private func changeMode(_ sender: Any?) {
        guard DiffMode.allCases.indices.contains(modes.selectedSegment) else { return }
        onModeChange?(DiffMode.allCases[modes.selectedSegment])
    }
    @objc private func changeImageMode(_ sender: Any?) {
        guard offeredImageModes.indices.contains(imageModes.selectedSegment) else { return }
        onImageModeChange?(offeredImageModes[imageModes.selectedSegment])
    }
    @objc private func toggleInvisibles(_ sender: Any?) {
        options.showsInvisibles.toggle()
        invisiblesItem.state = options.showsInvisibles ? .on : .off
        onOptionsChange?(options)
    }
    @objc private func goPrevious(_ sender: Any?) { onPrevious?() }
    @objc private func goNext(_ sender: Any?) { onNext?() }
    @objc private func runFileAction(_ sender: Any?) { onFileAction?() }
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
        discard.title = String(localized: "diff.hunk.discard", defaultValue: "Discard Hunk", bundle: .module)
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
