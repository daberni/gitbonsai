import AppKit

/// An editable list of folders with + and − below it, the way the system settings show such lists. + asks for folders in an open panel.
@MainActor
final class FolderListControl: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let read: () -> [String]
    private let write: ([String]) -> Void
    private let table = NSTableView()
    private let buttons = NSSegmentedControl()
    private var folders: [String]

    init(read: @escaping () -> [String], write: @escaping ([String]) -> Void) {
        self.read = read
        self.write = write
        folders = read()
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let column = NSTableColumn(identifier: .init("folder"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Theme.Settings.folderRowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        buttons.segmentCount = 2
        buttons.trackingMode = .momentary
        buttons.segmentStyle = .smallSquare
        buttons.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add Folder", bundle: .module)), forSegment: 0)
        buttons.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove Folder", bundle: .module)), forSegment: 1)
        buttons.target = self
        buttons.action = #selector(press(_:))
        for view in [scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.Settings.captionWidth),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Theme.Settings.folderListHeight),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -Theme.Stroke.hairline),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateButtons()
    }

    /// The list's first line sits on the label's baseline.
    override var firstBaselineOffsetFromTop: CGFloat { Theme.Settings.folderRowHeight * 0.7 }

    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: (folders[row] as NSString).abbreviatingWithTildeInPath)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = folders[row]
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private func updateButtons() {
        buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    @objc private func press(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { add() } else { removeSelected() }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", bundle: .module, comment: "The open panel's confirm button for adding an app or folder.")
        panel.message = String(localized: "Choose folders to search for repositories.", bundle: .module)
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let added = panel.urls.map(\.path).filter { !folders.contains($0) }
            save(folders + added)
        }
    }

    private func removeSelected() {
        let selected = table.selectedRowIndexes
        save(folders.enumerated().filter { !selected.contains($0.offset) }.map(\.element))
    }

    private func save(_ list: [String]) {
        write(list)
        folders = read()
        table.reloadData()
        table.deselectAll(nil)
        updateButtons()
    }
}
