import AppKit
import GitEngine

/// One step: the grip with the fold mark, the action pop-up, the short SHA, the subject (editable for a reword) and the branches at the commit, each in its column.
/// The subject stays on one line and truncates; its tooltip has the whole message.
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
    /// Leading edge and width of each cell, following the columns.
    private var placements: [RebaseColumns.Column: (leading: NSLayoutConstraint, width: NSLayoutConstraint)] = [:]

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: String(localized: "rebase.step.drag", defaultValue: "Drag to move", bundle: .module))
        grip.contentTintColor = Theme.inkFaint
        grip.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .regular)
        fold.image = NSImage(systemSymbolName: "arrow.turn.left.down", accessibilityDescription: String(localized: "rebase.step.foldsIntoBelow", defaultValue: "folds into the commit below", bundle: .module))
        fold.contentTintColor = Theme.moss
        fold.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        for action in RebaseAction.commitActions {
            actionPopup.addItem(withTitle: Self.label(action))
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
        subject.delegate = self
        subject.cell?.usesSingleLineMode = true
        subject.cell?.wraps = false
        subject.cell?.isScrollable = true
        subject.lineBreakMode = .byTruncatingTail
        subject.maximumNumberOfLines = 1
        branches.font = Theme.pill
        branches.textColor = Theme.moss
        for view in [grip, fold, actionPopup, sha, subject, branches] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: Theme.Icon.regular),
            fold.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: Theme.Space.xs),
            fold.centerYAnchor.constraint(equalTo: centerYAnchor),
            fold.widthAnchor.constraint(equalToConstant: M.foldIndent),
        ]
        let cells: [(RebaseColumns.Column, NSView)] = [(.action, actionPopup), (.sha, sha), (.subject, subject), (.branches, branches)]
        for (column, view) in cells {
            let leading = view.leadingAnchor.constraint(equalTo: leadingAnchor)
            let width = view.widthAnchor.constraint(equalToConstant: column.standardWidth)
            placements[column] = (leading, width)
            constraints += [leading, width, view.centerYAnchor.constraint(equalTo: centerYAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    /// Puts each cell into its column, inset like the header's captions.
    func apply(_ layout: [RebaseColumns.Column: ClosedRange<CGFloat>]) {
        for (column, range) in layout {
            guard let placement = placements[column] else { continue }
            // The pop-up draws its own bezel inset, so it starts at the column edge.
            let inset = column == .action ? Theme.Space.xs : Theme.Cell.leading
            placement.leading.constant = range.lowerBound + inset
            placement.width.constant = max(range.upperBound - range.lowerBound - inset - Theme.Space.xs, 0)
        }
    }

    func configure(with model: InteractiveRebaseModel, at index: Int) {
        let step = model.steps[index]
        let folded = model.isFolded(index)
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
        subject.toolTip = rewording ? String(localized: "rebase.step.rewordToolTip", defaultValue: "New message; the full message is below", bundle: .module) : step.commit?.message
        // A subject being typed keeps its text and cursor.
        if subject.currentEditor() == nil {
            let text = model.subject(at: index)
            let dropped = step.action == .drop
            // Without its own paragraph style an attributed value wraps instead of truncating.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            subject.attributedStringValue = NSAttributedString(string: text, attributes: [
                .paragraphStyle: paragraph,
                .font: Theme.body,
                .foregroundColor: dropped || folded && step.action == .fixup ? Theme.inkFaint : Theme.ink,
                .strikethroughStyle: dropped ? NSUnderlineStyle.single.rawValue : 0,
            ])
        }
        let names = model.branches(at: index)
        let applied = model.isAlreadyOnTarget(index)
        let target = model.targetName.plain
        branches.stringValue = applied ? String(localized: "rebase.step.alreadyOn", defaultValue: "already on \(target)", bundle: .module, comment: "Rebase row: the commit's changes are already on the target branch.") : names.joined(separator: ", ")
        branches.textColor = applied ? Theme.ochre : Theme.moss
        branches.toolTip = applied ? String(localized: "rebase.step.alreadyOnToolTip", defaultValue: "This commit’s changes are already on \(target) (same patch-id), so it starts as drop.", bundle: .module) : names.joined(separator: "\n")
        branches.isHidden = names.isEmpty && !applied
        setAccessibilityLabel("\(Self.label(step.action)) \(step.commit?.shortID ?? "") \(model.subject(at: index))")
    }

    /// The action as the pop-up names it. The todo verb written to git is always `rawValue`.
    static func label(_ action: RebaseAction) -> String {
        switch action {
        case .pick: String(localized: "rebase.action.pick", defaultValue: "pick", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        case .reword: String(localized: "rebase.action.reword", defaultValue: "reword", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        case .edit: String(localized: "rebase.action.edit", defaultValue: "edit", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        case .squash: String(localized: "rebase.action.squash", defaultValue: "squash", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        case .fixup: String(localized: "rebase.action.fixup", defaultValue: "fixup", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        case .drop: String(localized: "rebase.action.drop", defaultValue: "drop", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        case .exec: String(localized: "rebase.action.exec", defaultValue: "exec", bundle: .module, comment: "Rebase action in the step pop-up; git's todo verb.")
        }
    }

    static func explanation(_ action: RebaseAction) -> String {
        switch action {
        case .pick: String(localized: "rebase.action.pickHelp", defaultValue: "Use the commit", bundle: .module)
        case .reword: String(localized: "rebase.action.rewordHelp", defaultValue: "Use the commit, change its message", bundle: .module)
        case .edit: String(localized: "rebase.action.editHelp", defaultValue: "Use the commit and stop to amend it", bundle: .module)
        case .squash: String(localized: "rebase.action.squashHelp", defaultValue: "Combine with the commit below, join the messages", bundle: .module)
        case .fixup: String(localized: "rebase.action.fixupHelp", defaultValue: "Fold into the commit below, discard its message", bundle: .module)
        case .drop: String(localized: "rebase.action.dropHelp", defaultValue: "Remove the commit", bundle: .module)
        case .exec: String(localized: "rebase.action.execHelp", defaultValue: "Run a command", bundle: .module)
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
