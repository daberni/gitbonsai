import AppKit

/// The filter's scope menu and the action buttons below the list.
extension PanelListView {
    // MARK: Scopes

    /// Narrows the list to one scope, or shows everything again with nil.
    func selectScope(_ index: Int?) {
        activeScope = index.flatMap { scopes.indices.contains($0) ? $0 : nil }
        rebuildScopeMenu()
        applyFilter()
        if !shownRows.isEmpty, selectedID == nil { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateFooter()
    }

    /// The magnifier's menu: everything, then each scope; the chosen one is checked and named in the placeholder.
    func rebuildScopeMenu() {
        guard !scopes.isEmpty else {
            filterField.searchMenuTemplate = nil
            filterField.placeholderString = filterPlaceholder
            return
        }
        let menu = NSMenu()
        for (index, title) in ([String(localized: "panel.filter.all", defaultValue: "All", bundle: .module, comment: "Filter scope of a panel list that searches every field.")] + scopes.map(\.title)).enumerated() {
            let item = NSMenuItem(title: title, action: #selector(scopeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index - 1
            item.state = (activeScope ?? -1) == index - 1 ? .on : .off
            menu.addItem(item)
        }
        filterField.searchMenuTemplate = menu
        filterField.placeholderString = activeScope.map { "\(scopes[$0].title) · \(filterPlaceholder)" } ?? filterPlaceholder
    }

    @objc private func scopeChosen(_ sender: NSMenuItem) {
        selectScope(sender.tag >= 0 ? sender.tag : nil)
    }

    // MARK: Footer

    func rebuildFooter() {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footerButtons = actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.hasDestructiveAction = action.isDestructive
            footer.addArrangedSubview(button)
            return button
        }
        updateFooter()
    }

    func updateFooter() {
        let selected = selectedID
        for (button, action) in zip(footerButtons, actions) {
            button.isHidden = !action.isShown(selected)
            button.isEnabled = selected.map(action.isEnabled) ?? false
        }
    }

    @objc private func runAction(_ sender: NSButton) {
        guard let id = selectedID, actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform(id)
    }
}
