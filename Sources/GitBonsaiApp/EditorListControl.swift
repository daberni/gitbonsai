import AppKit
import UniformTypeIdentifiers

/// The editors of Settings → Allgemein: detected and added editors with a checkbox for whether the command bar offers them, "Andere App hinzufügen …" below,
/// and a pop-up for the default editor that "Im Editor öffnen" and the file menus use.
@MainActor
final class EditorListControl: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let addButton = NSButton(title: "Andere App hinzufügen …", target: nil, action: nil)
    let defaultPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var choices: [(app: ExternalApp, url: URL, isShown: Bool)] = []

    init() {
        super.init(frame: .zero)
        build()
        reload()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        table.addTableColumn(NSTableColumn(identifier: .init("editor")))
        table.headerView = nil
        table.rowHeight = Theme.Settings.folderRowHeight
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addButton.target = self
        addButton.action = #selector(addApp(_:))
        addButton.controlSize = .small
        defaultPicker.target = self
        defaultPicker.action = #selector(chooseDefault(_:))
        for view in [scroll, addButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.Settings.captionWidth),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Theme.Editors.listHeight),
            addButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Theme.Settings.captionGap),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        defaultPicker.widthAnchor.constraint(equalToConstant: Theme.Settings.popupWidth).isActive = true
    }

    /// The list's first line sits on the label's baseline.
    override var firstBaselineOffsetFromTop: CGFloat { Theme.Settings.folderRowHeight * 0.7 }

    private func reload() {
        choices = ExternalApps.editorChoices()
        table.reloadData()
        rebuildDefaultPicker()
    }

    private func rebuildDefaultPicker() {
        defaultPicker.removeAllItems()
        let first = NSMenuItem(title: "Erster angezeigter Editor", action: nil, keyEquivalent: "")
        defaultPicker.menu?.addItem(first)
        let shown = choices.filter(\.isShown)
        if !shown.isEmpty { defaultPicker.menu?.addItem(.separator()) }
        for choice in shown {
            let item = NSMenuItem(title: choice.app.name, action: nil, keyEquivalent: "")
            item.representedObject = choice.app.bundleID
            item.image = Self.icon(of: choice.url)
            defaultPicker.menu?.addItem(item)
        }
        let selected = defaultPicker.itemArray.first { ($0.representedObject as? String) == AppSettings.defaultEditor }
        defaultPicker.select(selected ?? first)
    }

    private static func icon(of app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: Theme.Settings.appIcon, height: Theme.Settings.appIcon)
        return icon
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = choices[row]
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
        box.state = choice.isShown ? .on : .off
        box.tag = row
        box.setAccessibilityLabel(choice.app.name)
        let icon = NSImageView(image: Self.icon(of: choice.url))
        let name = NSTextField(labelWithString: choice.app.name)
        name.lineBreakMode = .byTruncatingTail
        let line = NSStackView(views: [box, icon, name])
        line.spacing = Theme.Space.xs
        line.toolTip = choice.url.path
        return line
    }

    @objc private func toggle(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag) else { return }
        let id = choices[sender.tag].app.bundleID
        var hidden = AppSettings.hiddenEditors.filter { $0 != id }
        if sender.state == .off { hidden.append(id) }
        AppSettings.hiddenEditors = hidden
        if sender.state == .off, AppSettings.defaultEditor == id { AppSettings.defaultEditor = nil }
        reload()
    }

    @objc private func chooseDefault(_ sender: NSPopUpButton) {
        AppSettings.defaultEditor = sender.selectedItem?.representedObject as? String
    }

    @objc private func addApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Hinzufügen"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, ExternalApps.app(at: url) != nil else { return }
            add(url)
        }
    }

    /// Adds an app as editor and shows it again if it was unchecked before.
    func add(_ url: URL) {
        guard let app = ExternalApps.app(at: url) else { return }
        if !choices.contains(where: { $0.app.bundleID == app.bundleID }) { AppSettings.addedEditors.append(url) }
        AppSettings.hiddenEditors.removeAll { $0 == app.bundleID }
        reload()
    }
}
