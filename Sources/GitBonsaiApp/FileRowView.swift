import AppKit
import GitEngine

/// One file in one line: status letter, the folder dimmed, the file name, and on the right the line counts.
/// When space runs out the folder gives way from the front, the file name stays.
final class FileRowView: NSView {
    /// What the buttons a hovered row shows do with the whole file.
    enum Action {
        case stage, unstage, discard

        var glyph: Glyph {
            switch self {
            case .stage: .plus
            case .unstage: .minus
            case .discard: .trash
            }
        }
    }

    struct Model {
        let selection: FileSelection
        let letter: String
        let color: NSColor
        let stat: DiffStat?
        /// Shown instead of the counts, for instance "untracked".
        let note: String?
        /// Shown from right to left while the row is hovered.
        var actions: [Action] = []
        /// What happened to the file, where the context menu needs to know; nil for an untracked file.
        var state: FileState? = nil
    }

    private typealias M = Theme.FileList
    let model: Model
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onAction: ((Action) -> Void)?
    /// Built at the moment of the right click, so it reflects the file as it is then.
    var contextMenu: (() -> NSMenu?)?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var hoveredAction: Action? { didSet { needsDisplay = true } }

    /// The action buttons take the place of the counts at the right end while the row is hovered, the first one outermost.
    func actionRect(_ index: Int) -> CGRect {
        let size = M.actionButton
        let maxX = bounds.maxX - Theme.Space.xs / 2 - CGFloat(index) * (size + M.actionGap)
        return CGRect(x: maxX - size, y: bounds.midY - size / 2, width: size, height: size)
    }

    /// The right-hand slot always reserves room for the buttons, so the path keeps its place and cut whether or not the row is hovered.
    private var actionsWidth: CGFloat {
        guard !model.actions.isEmpty else { return 0 }
        return bounds.maxX - Theme.Space.xs - actionRect(model.actions.count - 1).minX
    }

    private func action(at point: CGPoint) -> Action? {
        model.actions.indices.first { actionRect($0).contains(point) }.map { model.actions[$0] }
    }

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: M.rowHeight).isActive = true
        toolTip = model.selection.originalPath.map { "\($0) → \(model.selection.path)" } ?? model.selection.path
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Like a Finder list, a click into an inactive window already chooses the file.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoveredAction = nil
        LinkCursor.set(overLink: false)
    }

    override func mouseMoved(with event: NSEvent) {
        isHovered = true
        hoveredAction = action(at: convert(event.locationInWindow, from: nil))
        LinkCursor.set(overLink: hoveredAction != nil)
    }

    /// The row itself keeps the arrow like any list row; only its bare action icons are link-like.
    override func cursorUpdate(with event: NSEvent) {
        LinkCursor.set(overLink: action(at: convert(event.locationInWindow, from: nil)) != nil)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let action = action(at: point) { onAction?(action) } else { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHovered {
            (isSelected ? Theme.surfaceSelected : Theme.surface2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: M.rowRadius, yRadius: M.rowRadius).fill()
        }
        let midY = bounds.midY
        let inset = Theme.Space.xs
        let letter = NSAttributedString(string: model.letter, attributes: [.font: Theme.monoStrong, .foregroundColor: model.color])
        letter.draw(at: CGPoint(x: inset, y: midY - letter.size().height / 2))

        let trailing = trailingText()
        let trailingWidth = max(trailing?.size().width ?? 0, actionsWidth)
        if isHovered && !model.actions.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            for (index, action) in model.actions.enumerated() {
                let rect = actionRect(index)
                if hoveredAction == action {
                    Theme.ink.withAlphaComponent(Theme.Wash.pressed).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
                }
                action.glyph.draw(in: rect.insetBy(dx: Theme.Space.xs, dy: Theme.Space.xs), color: Theme.ink, context: context)
            }
        } else if let trailing {
            let size = trailing.size()
            trailing.draw(at: CGPoint(x: bounds.maxX - inset - size.width, y: midY - size.height / 2))
        }

        let pathX = inset + M.letterWidth
        let available = bounds.maxX - inset - trailingWidth - (trailingWidth == 0 ? 0 : M.statGap) - pathX
        guard available > 0 else { return }
        // One string, cut from the front: the folder goes first, the file name last.
        let path = NSMutableAttributedString(string: model.selection.directory, attributes: Self.attributes(Theme.inkMuted))
        path.append(NSAttributedString(string: model.selection.name, attributes: Self.attributes(Theme.ink)))
        let height = path.size().height
        path.draw(with: CGRect(x: pathX, y: midY - height / 2, width: available, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func attributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        return [.font: Theme.mono, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func trailingText() -> NSAttributedString? {
        if let note = model.note { return NSAttributedString(string: note, attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted]) }
        guard let stat = model.stat else { return nil }
        return Self.statText(stat)
    }

    /// `+18 −9`, either part left out when it is zero.
    static func statText(_ stat: DiffStat) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if stat.added > 0 { text.append(NSAttributedString(string: "+\(stat.added)", attributes: [.font: Theme.captionDigits, .foregroundColor: Theme.moss])) }
        if stat.removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: Theme.captionDigits])) }
            text.append(NSAttributedString(string: "−\(stat.removed)", attributes: [.font: Theme.captionDigits, .foregroundColor: Theme.persimmon]))
        }
        return text
    }
}

extension FileState {
    /// The colour of the change letter, the same in the file lists and the diff header.
    @MainActor var tint: NSColor {
        switch self {
        case .added: Theme.moss
        case .deleted, .unmerged: Theme.persimmon
        case .renamed, .copied: Theme.sky
        default: Theme.ochre
        }
    }
}

/// Sections of file rows with a caption and an optional action, and one selected file across all of them.
final class FileListView: NSStackView {
    struct Section {
        let title: String
        let rows: [FileRowView.Model]
        /// For instance "Stage all".
        let action: (title: String, perform: () -> Void)?
    }

    var onSelect: ((FileSelection) -> Void)?
    var onAction: ((FileSelection, FileRowView.Action) -> Void)?
    /// The context menu's entries for a row; none leaves the row without a menu.
    var menuItems: ((FileRowView.Model) -> [NSMenuItem])?
    var selected: FileSelection? { didSet { rowViews.forEach { $0.isSelected = $0.model.selection == selected } } }
    /// While the rows belong to an earlier selection they take no clicks or keys; once loading takes long they are hidden and keep their room.
    enum Freshness { case current, stale, loading }
    var freshness = Freshness.current {
        didSet { arrangedSubviews.forEach { $0.isHidden = freshness == .loading } }
    }
    private var rowViews: [FileRowView] = []
    /// The rows shown, in order.
    var models: [FileRowView.Model] { rowViews.map(\.model) }
    private var actions: [() -> Void] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        detachesHiddenViews = false
    }

    required init?(coder: NSCoder) { nil }

    func show(_ sections: [Section]) {
        freshness = .current
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        actions = []
        for (index, section) in sections.enumerated() {
            if index > 0, let last = arrangedSubviews.last { setCustomSpacing(Theme.FileList.sectionGap, after: last) }
            addFull(header(for: section))
            for model in section.rows.prefix(Theme.Detail.maximumFiles) {
                let row = FileRowView(model: model)
                row.isSelected = model.selection == selected
                row.onClick = { [weak self, weak row] in
                    guard let self, let row else { return }
                    window?.makeFirstResponder(self)
                    choose(row)
                }
                row.onAction = { [weak self] action in self?.onAction?(model.selection, action) }
                row.contextMenu = { [weak self] in
                    guard let items = self?.menuItems?(model), !items.isEmpty else { return nil }
                    let menu = NSMenu()
                    items.forEach(menu.addItem)
                    return menu
                }
                rowViews.append(row)
                addFull(row)
            }
            if section.rows.count > Theme.Detail.maximumFiles {
                addFull(Self.caption(String(localized: "… and \(section.rows.count - Theme.Detail.maximumFiles) more", bundle: .module, comment: "Below a cut-off file list")))
            }
        }
    }

    // MARK: Keyboard

    /// ↑ and ↓ walk through the rows of all sections as one list; a click on a row gives the list the focus.
    override var acceptsFirstResponder: Bool { !rowViews.isEmpty && freshness == .current }

    override func hitTest(_ point: NSPoint) -> NSView? {
        freshness == .current ? super.hitTest(point) : nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: moveSelection(by: -1)
        case .downArrow?: moveSelection(by: 1)
        default: super.keyDown(with: event)
        }
    }

    func moveSelection(by offset: Int) {
        guard !rowViews.isEmpty, freshness == .current else { return }
        let current = rowViews.firstIndex { $0.model.selection == selected }
        let target = current.map { min(max($0 + offset, 0), rowViews.count - 1) } ?? (offset > 0 ? 0 : rowViews.count - 1)
        guard target != current else { return }
        choose(rowViews[target])
    }

    /// The same path for a click and a key: select, keep the row in sight, open its diff.
    private func choose(_ row: FileRowView) {
        selected = row.model.selection
        row.scrollToVisible(row.bounds)
        onSelect?(row.model.selection)
    }

    private func addFull(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func header(for section: Section) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let title = Self.caption("")
        title.attributedStringValue = NSAttributedString(string: section.title.uppercased(with: AppLanguage.locale), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        box.addSubview(title)
        var constraints = [
            box.heightAnchor.constraint(equalToConstant: Theme.FileList.sectionHeight),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Theme.Space.xs),
            title.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ]
        if let action = section.action {
            let button = LinkButton(target: self, action: #selector(runAction(_:)))
            button.attributedTitle = NSAttributedString(string: action.title, attributes: [.font: Theme.caption, .foregroundColor: Theme.moss])
            button.tag = actions.count
            actions.append(action.perform)
            button.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(button)
            constraints += [button.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Theme.Space.xs), button.centerYAnchor.constraint(equalTo: box.centerYAnchor)]
        }
        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(constraints)
        return box
    }

    @objc private func runAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    private static func caption(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = Theme.caption
        field.textColor = Theme.inkMuted
        return field
    }
}
