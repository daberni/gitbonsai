import AppKit
import GitEngine

/// How a conflict without hunks is resolved: one whole side, or the file deleted.
enum ConflictFileAction: Equatable {
    case take(ConflictSide)
    case delete
}

/// A conflict that cannot be merged line by line: a sentence saying what each side did, a preview of the file a side kept, and the choices, which act at once.
final class ConflictChoiceView: NSView {
    typealias M = Theme.Conflict
    var onAction: ((ConflictFileAction) -> Void)?
    private(set) var buttons: [(ConflictFileAction, SecondaryButton)] = []

    init(conflict: Conflict, sides: ConflictSides) {
        super.init(frame: .zero)
        let sentence = NSTextField(wrappingLabelWithString: "")
        sentence.font = Theme.body
        sentence.textColor = Theme.ink
        sentence.setText(sides.explanation(of: conflict))
        var views: [NSView] = [sentence]
        if case .oneSided(let remaining?) = conflict.content {
            var lines = (remaining as NSString).components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let shown = lines.prefix(M.previewLines).joined(separator: "\n") + (lines.count > M.previewLines ? "\n⋯" : "")
            let side = conflict.stages.ours != nil ? sides.ours : sides.theirs
            let caption = RefString(LocalizedStringResource("conflict.preview", defaultValue: "The file as \(side) has it", bundle: .module))
            views.append(ConflictBlockView(caption: caption, lines: shown.isEmpty ? [] : [shown], tint: conflict.stages.ours != nil ? Theme.moss : Theme.sky))
        }
        for action in Self.actions(for: conflict) {
            let button = SecondaryButton(title: Self.title(of: action, conflict: conflict))
            if action == .delete { button.tint = Theme.persimmon }
            button.target = self
            button.action = #selector(run(_:))
            buttons.append((action, button))
        }
        let row = NSStackView(views: buttons.map(\.1))
        row.orientation = .horizontal
        row.spacing = Theme.Space.s
        views.append(row)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = M.cardGap + Theme.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: M.cardPadding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.cardPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.cardPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -M.cardPadding),
            sentence.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        if let preview = views.first(where: { $0 is ConflictBlockView }) {
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Binary and too large files offer both sides; a file one side deleted can be kept as the other side has it, or deleted.
    static func actions(for conflict: Conflict) -> [ConflictFileAction] {
        switch conflict.kind {
        case .bothModified, .bothAdded: [.take(.ours), .take(.theirs)]
        case .deletedByThem, .addedByUs: [.take(.ours), .delete]
        case .deletedByUs, .addedByThem: [.take(.theirs), .delete]
        case .bothDeleted: [.delete]
        }
    }

    static func title(of action: ConflictFileAction, conflict: Conflict) -> String {
        switch (action, conflict.kind) {
        case (.delete, _): String(localized: "conflict.action.delete", defaultValue: "Delete File", bundle: .module, comment: "Resolve a conflict by deleting the file")
        case (.take(.ours), .bothModified), (.take(.ours), .bothAdded): String(localized: "conflict.action.useOurs", defaultValue: "Use Ours", bundle: .module, comment: "Resolve a binary conflict with our whole file")
        case (.take(.theirs), .bothModified), (.take(.theirs), .bothAdded): String(localized: "conflict.action.useTheirs", defaultValue: "Use Theirs", bundle: .module, comment: "Resolve a binary conflict with their whole file")
        case (.take, _): String(localized: "conflict.action.keep", defaultValue: "Keep File", bundle: .module, comment: "Resolve a conflict by keeping the file the other side deleted")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: M.cardRadius, yRadius: M.cardRadius)
        Theme.surface1.setFill()
        path.fill()
        Theme.hairline.setStroke()
        path.stroke()
    }

    @objc private func run(_ sender: SecondaryButton) {
        guard let action = buttons.first(where: { $0.1 === sender })?.0 else { return }
        onAction?(action)
    }
}
