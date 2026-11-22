import AppKit
import GitEngine

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
