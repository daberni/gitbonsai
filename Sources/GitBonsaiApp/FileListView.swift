import AppKit
import GitEngine

/// Sections of file rows with a caption and an optional action, and the selected files across all of them.
/// A click selects one file, or deselects it when it is the only one; ⌘-click toggles a file, ⇧-click selects the range from the last clicked one.
final class FileListView: NSStackView {
    struct Section {
        let title: String
        let rows: [FileRowView.Model]
        /// For instance "Stage all".
        let action: (title: String, perform: () -> Void)?
    }

    /// The selection changed by a click or a key; empty when the last file was deselected.
    var onSelect: (([FileSelection]) -> Void)?
    var onAction: (([FileSelection], FileRowView.Action) -> Void)?
    /// The context menu's entries for the files it acts on; none leaves the row without a menu.
    var menuItems: (([FileRowView.Model]) -> [NSMenuItem])?
    /// In row order.
    var selection: [FileSelection] = [] { didSet { rowViews.forEach { $0.isSelected = selection.contains($0.model.selection) } } }
    /// Where ⇧-click and ⇧-arrow ranges start, and where the arrow keys move from.
    private var anchor: FileSelection?
    private var cursor: FileSelection?
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
                row.isSelected = selection.contains(model.selection)
                row.onClick = { [weak self, weak row] flags in
                    guard let self, let row else { return }
                    window?.makeFirstResponder(self)
                    click(row, flags: flags)
                }
                row.onAction = { [weak self] action in
                    guard let self else { return }
                    onAction?(targets(of: model, fitting: action).map(\.selection), action)
                }
                row.contextMenu = { [weak self] in
                    guard let self, let items = menuItems?(targets(of: model)), !items.isEmpty else { return nil }
                    let menu = NSMenu()
                    menu.autoenablesItems = false
                    items.forEach(menu.addItem)
                    return menu
                }
                rowViews.append(row)
                addFull(row)
            }
            if section.rows.count > Theme.Detail.maximumFiles {
                addFull(Self.caption(String(localized: "files.list.andMore", defaultValue: "… and \(section.rows.count - Theme.Detail.maximumFiles) more", bundle: .module, comment: "Below a cut-off file list")))
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
        let extending = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: moveSelection(by: -1, extending: extending)
        case .downArrow?: moveSelection(by: 1, extending: extending)
        default: super.keyDown(with: event)
        }
    }

    /// An arrow moves a single selection on from the last clicked file; with ⇧ it grows or shrinks the range from the anchor instead.
    func moveSelection(by offset: Int, extending: Bool = false) {
        guard !rowViews.isEmpty, freshness == .current else { return }
        let current = index(of: cursor) ?? rowViews.lastIndex { selection.contains($0.model.selection) }
        let target = current.map { min(max($0 + offset, 0), rowViews.count - 1) } ?? (offset > 0 ? 0 : rowViews.count - 1)
        guard target != current else { return }
        let row = rowViews[target]
        if extending, let start = index(of: anchor) {
            cursor = row.model.selection
            select(range(start, target))
        } else {
            anchor = row.model.selection
            cursor = anchor
            select([row.model.selection])
        }
        row.scrollToVisible(row.bounds)
    }

    private func click(_ row: FileRowView, flags: NSEvent.ModifierFlags) {
        let file = row.model.selection
        if flags.contains(.command) {
            anchor = file
            cursor = file
            select(selection.contains(file) ? selection.filter { $0 != file } : rowViews.map(\.model.selection).filter { selection.contains($0) || $0 == file })
        } else if flags.contains(.shift), let start = index(of: anchor), let end = index(of: file) {
            cursor = file
            select(range(start, end))
        } else if selection == [file] {
            anchor = nil
            cursor = nil
            select([])
        } else {
            anchor = file
            cursor = file
            select([file])
        }
        row.scrollToVisible(row.bounds)
    }

    private func select(_ files: [FileSelection]) {
        selection = files
        onSelect?(files)
    }

    private func index(of file: FileSelection?) -> Int? {
        file.flatMap { file in rowViews.firstIndex { $0.model.selection == file } }
    }

    private func range(_ start: Int, _ end: Int) -> [FileSelection] {
        rowViews[min(start, end)...max(start, end)].map(\.model.selection)
    }

    /// A row that is part of a larger selection speaks for all selected rows; any other row only for itself, as in Finder.
    private func targets(of model: FileRowView.Model) -> [FileRowView.Model] {
        guard selection.contains(model.selection) else { return [model] }
        return rowViews.map(\.model).filter { selection.contains($0.selection) }
    }

    /// A hovered button acts on every selected file only when each of them offers it.
    private func targets(of model: FileRowView.Model, fitting action: FileRowView.Action) -> [FileRowView.Model] {
        let all = targets(of: model)
        return all.allSatisfy { $0.actions.contains(action) } ? all : [model]
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
