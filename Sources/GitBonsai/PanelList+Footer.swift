import AppKit

/// The scope switch in the title line and the action buttons below the list.
extension PanelListView {
    // MARK: Scopes

    /// Narrows the list to one scope, or shows everything again with nil.
    func selectScope(_ index: Int?) {
        activeScope = index.flatMap { scopes.indices.contains($0) ? $0 : nil }
        scopeControl.selectedSegment = (activeScope ?? -1) + 1
        applyFilter()
        if !shownRows.isEmpty, selectedID == nil { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateFooter()
    }

    /// The switch in the title line: everything, then each scope.
    func rebuildScopeControl() {
        let titles = [String(localized: "panel.filter.all", defaultValue: "All", bundle: .module, comment: "Filter scope of a panel list that searches every field.")] + scopes.map(\.title)
        scopeControl.isHidden = scopes.isEmpty
        scopeControl.segmentCount = scopes.isEmpty ? 0 : titles.count
        guard !scopes.isEmpty else { return }
        for (index, title) in titles.enumerated() {
            scopeControl.setLabel(title, forSegment: index)
            scopeControl.setWidth(0, forSegment: index)
        }
        scopeControl.selectedSegment = (activeScope ?? -1) + 1
    }

    @objc func scopeChosen(_ sender: NSSegmentedControl) {
        selectScope(sender.selectedSegment > 0 ? sender.selectedSegment - 1 : nil)
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
