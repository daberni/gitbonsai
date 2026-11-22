import AppKit
import GitEngine

/// Harness switches for the Tags and Stashes popovers and the toolbar's Stash and Pop.
@MainActor
extension ScreenshotHarness {
    /// Runs the switches in order, each after the one before has settled: open the panel, filter, select, capture, then one action.
    static func driveStashesAndTags(on tab: RepositoryViewController) {
        if let button = environment["GITBONSAI_TOOLBAR"] { clickToolbar(button, on: tab) }
        guard let name = environment["GITBONSAI_OPEN_PANEL"], let panel = SidebarPanel(rawValue: name) else { return }
        let popover = panel == .tags ? tab.tagsController.popover : tab.stashesController.popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            clickSidebarRow(panel, on: tab)
            whenShown(popover, attempts: 20) { window in
                guard let window else {
                    FileHandle.standardError.write(Data("panel \(name) did not open\n".utf8))
                    return
                }
                let list = popover.list
                if let filter = environment["GITBONSAI_PANEL_FILTER"] {
                    list.filterField.stringValue = filter
                    list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: list.filterField))
                }
                FileHandle.standardError.write(Data("panel \(name): \(list.shownRows.map { "\($0.title) [\($0.detail)] \($0.sha)" }.joined(separator: "; ")); filter shown \(!list.filterField.isHidden)\n".utf8))
                if let row = environment["GITBONSAI_PANEL_SELECT"].flatMap(Int.init), row < list.tableView.numberOfRows {
                    let rect = list.tableView.rect(ofRow: row)
                    pressView(in: window, at: list.tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
                    let selectedRow = tab.history.selectedRow
                    let historyCommit = selectedRow >= 0 ? String(tab.viewModel.commits[selectedRow].id.prefix(7)) : "none"
                    FileHandle.standardError.write(Data("panel selected \(list.selectedID ?? "nothing"), history at \(historyCommit)\n".utf8))
                }
                if let shot = environment["GITBONSAI_PANEL_SHOT"] { capturePanel(popover, to: shot) }
                if let title = environment["GITBONSAI_PANEL_BUTTON"], let button = list.footerButtons.first(where: { $0.title == title }) {
                    FileHandle.standardError.write(Data("panel button \(title) enabled \(button.isEnabled)\n".utf8))
                    pressView(in: window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
                }
                if let title = environment["GITBONSAI_PANEL_MENU"], let id = list.selectedID, let items = list.menuItems?(id) {
                    let menu = NSMenu()
                    items.forEach(menu.addItem)
                    FileHandle.standardError.write(Data("panel menu: \(describe(menu))\n".utf8))
                    choose(title, in: menu)
                }
            }
        }
    }

    /// The tags are read before the popover opens, so it appears a moment after the click.
    private static func whenShown(_ popover: PanelPopover, attempts: Int, _ body: @escaping (NSWindow?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = popover.window { body(window) } else if attempts > 0 { whenShown(popover, attempts: attempts - 1, body) } else { body(nil) }
        }
    }

    /// The sidebar keeps its row frames to itself; they follow from its outline with the same row heights, as long as nothing was collapsed by hand.
    private static func clickSidebarRow(_ panel: SidebarPanel, on tab: RepositoryViewController) {
        let sidebar = tab.sidebar
        typealias M = Theme.Sidebar
        var outline = SidebarOutline()
        var y = Theme.Space.s
        var anchor: CGRect?
        for item in outline.items(from: tab.viewModel) {
            let height: CGFloat
            switch item {
            case .header: y += Theme.Space.xs; height = M.headerHeight
            case .worktree: height = M.worktreeHeight
            case .row: height = M.rowHeight
            }
            if case .row(_, _, _, _, _, _, _, _, _, _, let target?, _, _) = item, target == panel.target { anchor = CGRect(x: M.rowInset, y: y, width: sidebar.bounds.width - 2 * M.rowInset, height: height) }
            y += height
        }
        guard let anchor, let window = sidebar.window else {
            FileHandle.standardError.write(Data("no \(panel.rawValue) row in the sidebar\n".utf8))
            return
        }
        sidebar.scrollToVisible(anchor)
        FileHandle.standardError.write(Data("click \(panel.rawValue) row at \(anchor)\n".utf8))
        pressView(in: window, at: sidebar.convert(NSPoint(x: anchor.midX, y: anchor.midY), to: nil))
    }

    /// A real press and release at a point, delivered to the view under it. In a background run no window becomes key, and a window that is not key swallows
    /// the first click on views that take no first mouse (the sidebar, tables, buttons in a popover).
    private static func pressView(in window: NSWindow, at point: NSPoint) {
        guard let target = window.contentView?.superview?.hitTest(point), let down = mouseEvent(.leftMouseDown, at: point, in: window) else { return }
        if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
        target.mouseDown(with: down)
    }

    /// `GITBONSAI_TOOLBAR=Stash|Pop` clicks that toolbar button with a real click; the stash sheet is answered by `GITBONSAI_FORM`.
    private static func clickToolbar(_ title: String, on tab: RepositoryViewController) {
        guard let window = tab.toolbar.window, let button = views(of: NSButton.self, in: window).first(where: { $0.title == title && $0.isDescendant(of: tab.toolbar) }) else {
            FileHandle.standardError.write(Data("no toolbar button \(title)\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("toolbar \(title) enabled \(button.isEnabled)\n".utf8))
        pressView(in: window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
    }

    /// The list without the popover's glass frame, which renders as noise outside a live window.
    private static func capturePanel(_ popover: PanelPopover, to path: String) {
        let view = popover.list
        view.window?.appearance = NSApp.appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
