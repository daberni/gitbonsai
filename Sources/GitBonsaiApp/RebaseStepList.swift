import AppKit
import GitEngine

/// The steps of the interactive rebase sheet, oldest first: drag a row or press ⌥↑/⌥↓ to move it, choose its action in the pop-up or with p, r, e, s, f, d.
@MainActor
final class RebaseStepList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = RebaseStepTable()
    let scrollView = NSScrollView()
    private let model: InteractiveRebaseModel
    var onSelect: ((Int?) -> Void)?

    init(model: InteractiveRebaseModel) {
        self.model = model
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("step"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Theme.InteractiveRebase.rowHeight
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.surface2
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Commits des Rebase, älteste zuerst")
        table.onMove = { [weak self] from, to in self?.move(from: from, to: to) }
        table.onShift = { [weak self] offset in self?.shiftSelection(by: offset) }
        table.onAction = { [weak self] action in
            guard let self, table.selectedRow >= 0 else { return }
            model.setAction(action, at: table.selectedRow)
        }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface2
    }

    var selectedIndex: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }

    func select(_ index: Int) {
        guard model.steps.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    /// Shows the model again without rebuilding the rows, so a subject being typed keeps its editor.
    func refresh() {
        for index in model.steps.indices {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? RebaseStepRowView)?.configure(with: model, at: index)
        }
    }

    private func move(from: Int, to: Int) {
        let landed = model.move(from: from, to: to)
        select(landed)
    }

    private func shiftSelection(by offset: Int) {
        guard let index = selectedIndex else { return }
        let destination = offset < 0 ? index + offset : index + offset + 1
        guard destination >= 0, destination <= model.steps.count else { return }
        move(from: index, to: destination)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.steps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("step-row")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? RebaseStepRowView ?? RebaseStepRowView(identifier: identifier)
        view.onAction = { [weak self, weak view] action in
            guard let self, let view else { return }
            let index = table.row(for: view)
            if index >= 0 { model.setAction(action, at: index) }
        }
        view.onSubject = { [weak self, weak view] subject in
            guard let self, let view else { return }
            let index = table.row(for: view)
            if index >= 0 { model.setSubject(subject, at: index) }
        }
        view.configure(with: model, at: row)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedIndex)
    }
}

/// The table of the step list. A press on a row that is not on one of its controls selects it, and dragging from there moves it; the row lands where the line shows.
/// The drag follows the mouse in a tracking loop, so it works for queued events too, the way the harness sends them.
final class RebaseStepTable: NSTableView {
    var onMove: ((Int, Int) -> Void)?
    var onShift: ((Int) -> Void)?
    var onAction: ((RebaseAction) -> Void)?
    private let insertionLine = FillView(color: Theme.moss)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let row = row(at: start)
        guard row >= 0, let window else { return super.mouseDown(with: event) }
        window.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        var destination: Int?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            guard destination != nil || hypot(point.x - start.x, point.y - start.y) > Theme.dragThreshold else { continue }
            autoscroll(with: next)
            destination = insertionIndex(at: point)
            showInsertionLine(at: destination ?? row)
        }
        insertionLine.removeFromSuperview()
        if let destination, destination != row, destination != row + 1 { onMove?(row, destination) }
    }

    /// The gap between rows nearest to `point`: 0 above the first row, `numberOfRows` below the last.
    private func insertionIndex(at point: NSPoint) -> Int {
        let height = rowHeight + intercellSpacing.height
        return min(max(Int((point.y / height).rounded()), 0), numberOfRows)
    }

    private func showInsertionLine(at index: Int) {
        let height = rowHeight + intercellSpacing.height
        let thickness = Theme.Stroke.strand
        insertionLine.frame = NSRect(x: Theme.Space.s, y: CGFloat(index) * height - thickness / 2, width: bounds.width - 2 * Theme.Space.s, height: thickness)
        if insertionLine.superview == nil { addSubview(insertionLine) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.option), let key = event.specialKey, key == .upArrow || key == .downArrow {
            onShift?(key == .upArrow ? -1 : 1)
            return
        }
        let letters: [String: RebaseAction] = ["p": .pick, "r": .reword, "e": .edit, "s": .squash, "f": .fixup, "d": .drop]
        if modifiers.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty, let action = event.charactersIgnoringModifiers.flatMap({ letters[$0.lowercased()] }) {
            onAction?(action)
            return
        }
        super.keyDown(with: event)
    }
}

/// One step: a grip, the action pop-up, the short SHA, the subject (editable for a reword) and the branches at the commit.
final class RebaseStepRowView: NSTableCellView, NSTextFieldDelegate {
    private typealias M = Theme.InteractiveRebase

    var onAction: ((RebaseAction) -> Void)?
    var onSubject: ((String) -> Void)?

    private let grip = PassThroughImageView()
    private let fold = PassThroughImageView()
    private(set) var actionPopup = NSPopUpButton()
    private let sha = PassThroughLabel()
    private(set) var subject = SubjectField()
    private let branches = PassThroughLabel()
    private var foldWidth: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Ziehen zum Verschieben")
        grip.contentTintColor = Theme.inkFaint
        grip.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .regular)
        fold.image = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "geht im Commit darüber auf")
        fold.contentTintColor = Theme.moss
        fold.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        for action in RebaseAction.commitActions {
            actionPopup.addItem(withTitle: action.rawValue)
            actionPopup.lastItem?.toolTip = Self.explanation(action)
            actionPopup.lastItem?.representedObject = action.rawValue
        }
        actionPopup.controlSize = .small
        actionPopup.font = Theme.monoSmall
        actionPopup.target = self
        actionPopup.action = #selector(actionChosen(_:))
        sha.font = Theme.mono
        sha.textColor = Theme.inkMuted
        subject.font = Theme.body
        subject.lineBreakMode = .byTruncatingTail
        subject.delegate = self
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.setContentHuggingPriority(.defaultLow, for: .horizontal)
        branches.font = Theme.pill
        branches.textColor = Theme.moss
        branches.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for view in [grip, fold, actionPopup, sha, subject, branches] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        foldWidth = fold.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: Theme.Icon.regular),
            fold.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: Theme.Space.xs),
            fold.centerYAnchor.constraint(equalTo: centerYAnchor),
            foldWidth,
            actionPopup.leadingAnchor.constraint(equalTo: fold.trailingAnchor, constant: Theme.Space.xs),
            actionPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionPopup.widthAnchor.constraint(equalToConstant: M.actionWidth),
            sha.leadingAnchor.constraint(equalTo: actionPopup.trailingAnchor, constant: Theme.Space.s),
            sha.centerYAnchor.constraint(equalTo: centerYAnchor),
            sha.widthAnchor.constraint(equalToConstant: M.shaWidth),
            subject.leadingAnchor.constraint(equalTo: sha.trailingAnchor, constant: Theme.Space.xs),
            subject.centerYAnchor.constraint(equalTo: centerYAnchor),
            branches.leadingAnchor.constraint(equalTo: subject.trailingAnchor, constant: Theme.Space.s),
            branches.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s),
            branches.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(with model: InteractiveRebaseModel, at index: Int) {
        let step = model.steps[index]
        let folded = model.isFolded(index)
        foldWidth.constant = folded ? M.foldIndent : 0
        fold.isHidden = !folded
        actionPopup.selectItem(at: RebaseAction.commitActions.firstIndex(of: step.action) ?? 0)
        actionPopup.toolTip = Self.explanation(step.action)
        sha.stringValue = step.commit?.shortID ?? ""
        let rewording = step.action == .reword
        subject.isEditable = rewording
        subject.isSelectable = rewording
        subject.isBordered = rewording
        subject.isBezeled = rewording
        subject.bezelStyle = .roundedBezel
        subject.drawsBackground = rewording
        subject.focusRingType = rewording ? .default : .none
        subject.toolTip = rewording ? "Neue Nachricht; die ganze Nachricht steht unten" : step.commit?.message
        // A subject being typed keeps its text and cursor.
        if subject.currentEditor() == nil {
            let text = model.subject(at: index)
            let dropped = step.action == .drop
            subject.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: Theme.body,
                .foregroundColor: dropped || folded && step.action == .fixup ? Theme.inkFaint : Theme.ink,
                .strikethroughStyle: dropped ? NSUnderlineStyle.single.rawValue : 0,
            ])
        }
        let names = model.branches(at: index)
        branches.stringValue = names.joined(separator: ", ")
        branches.isHidden = names.isEmpty
        setAccessibilityLabel("\(step.action.rawValue) \(step.commit?.shortID ?? "") \(model.subject(at: index))")
    }

    static func explanation(_ action: RebaseAction) -> String {
        switch action {
        case .pick: "Commit übernehmen"
        case .reword: "Commit übernehmen, Nachricht ändern"
        case .edit: "Commit übernehmen und anhalten, um ihn zu ändern"
        case .squash: "Mit dem Commit darüber zusammenführen, Nachrichten zusammenfassen"
        case .fixup: "Im Commit darüber aufgehen, seine Nachricht verwerfen"
        case .drop: "Commit verwerfen"
        case .exec: "Befehl ausführen"
        }
    }

    @objc private func actionChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let action = RebaseAction(rawValue: raw) else { return }
        onAction?(action)
    }

    func controlTextDidChange(_ notification: Notification) {
        onSubject?(subject.stringValue)
    }
}

/// Labels and glyphs inside a row leave presses to the table, which selects and drags the row.
final class PassThroughLabel: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        lineBreakMode = .byTruncatingTail
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Editable only for a reword; otherwise presses go to the table like those on a label.
final class SubjectField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { isEditable ? super.hitTest(point) : nil }
}

final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
