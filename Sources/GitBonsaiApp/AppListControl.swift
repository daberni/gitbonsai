import AppKit
import UniformTypeIdentifiers

/// The editors or terminals of Settings → Allgemein: the apps found on the system and the added ones, each with a checkbox for whether the command bar offers it, "Andere App hinzufügen …" below,
/// and a pop-up for the default that "Im Editor öffnen" or "Im Terminal öffnen" use.
@MainActor
final class AppListControl: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let addButton = NSButton(title: String(localized: "Add Other App…", bundle: .module), target: nil, action: nil)
    let defaultPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kind: ExternalApps.Kind
    private var choices: [ExternalApps.Choice] = []

    init(kind: ExternalApps.Kind) {
        self.kind = kind
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
        choices = ExternalApps.choices(kind)
        table.reloadData()
        rebuildDefaultPicker()
    }

    private func rebuildDefaultPicker() {
        defaultPicker.removeAllItems()
        let first = NSMenuItem(title: kind == .editor ? String(localized: "First Checked Editor", bundle: .module) : String(localized: "First Checked Terminal", bundle: .module), action: nil, keyEquivalent: "")
        defaultPicker.menu?.addItem(first)
        let shown = choices.filter(\.isShown)
        if !shown.isEmpty { defaultPicker.menu?.addItem(.separator()) }
        for choice in shown {
            let item = NSMenuItem(title: choice.app.name, action: nil, keyEquivalent: "")
            item.representedObject = choice.app.bundleID
            item.image = Self.icon(of: choice.url)
            defaultPicker.menu?.addItem(item)
        }
        let selected = defaultPicker.itemArray.first { ($0.representedObject as? String) == AppSettings.defaultApp(kind) }
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
        var views: [NSView] = [box, icon, name]
        if choice.app.bundleID == ExternalApps.preferred(kind)?.app.bundleID {
            let mark = NSTextField(labelWithString: String(localized: "Default", bundle: .module, comment: "Marks the default app in the list of editors or terminals."))
            mark.font = Theme.caption
            mark.textColor = Theme.inkMuted
            views.append(mark)
        }
        let line = NSStackView(views: views)
        line.spacing = Theme.Space.xs
        line.toolTip = choice.url.path
        return line
    }

    @objc private func toggle(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag) else { return }
        let id = choices[sender.tag].app.bundleID
        var hidden = AppSettings.hiddenApps(kind).filter { $0 != id }
        if sender.state == .off { hidden.append(id) }
        AppSettings.setHiddenApps(hidden, kind)
        if sender.state == .off, AppSettings.defaultApp(kind) == id { AppSettings.setDefaultApp(nil, kind) }
        reload()
    }

    @objc private func chooseDefault(_ sender: NSPopUpButton) {
        AppSettings.setDefaultApp(sender.selectedItem?.representedObject as? String, kind)
        table.reloadData()
    }

    @objc private func addApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add", bundle: .module, comment: "The open panel's confirm button for adding an app or folder.")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, ExternalApps.app(at: url) != nil else { return }
            add(url)
        }
    }

    /// Adds an app to the list and shows it again if it was unchecked before.
    func add(_ url: URL) {
        guard let app = ExternalApps.app(at: url) else { return }
        if !choices.contains(where: { $0.app.bundleID == app.bundleID }) { AppSettings.setAddedApps(AppSettings.addedApps(kind) + [url], kind) }
        AppSettings.setHiddenApps(AppSettings.hiddenApps(kind).filter { $0 != app.bundleID }, kind)
        reload()
    }
}
