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
        subject.toolTip = rewording ? "Neue Nachricht; die ganze Nachricht steht unten" : step.commit?.message
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
        branches.stringValue = applied ? "schon auf \(model.targetName)" : names.joined(separator: ", ")
        branches.textColor = applied ? Theme.ochre : Theme.moss
        branches.toolTip = applied ? "Die Änderungen dieses Commits sind schon auf \(model.targetName) (gleiche patch-id); er beginnt deshalb als drop." : names.joined(separator: "\n")
        branches.isHidden = names.isEmpty && !applied
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
