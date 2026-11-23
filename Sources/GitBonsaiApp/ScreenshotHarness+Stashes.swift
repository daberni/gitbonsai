import AppKit
import GitEngine

/// Harness switches for the Tags and Stashes popovers and the toolbar's Stash and Pop.
@MainActor
extension ScreenshotHarness {
    /// Runs the switches in order, each after the one before has settled: open the panel, filter, select, capture, then one action.
    static func driveStashesAndTags(on tab: RepositoryViewController) {
        toastTab = tab
        if let button = environment["GITBONSAI_TOOLBAR"] { clickToolbar(button, on: tab) }
        guard let name = environment["GITBONSAI_OPEN_PANEL"], let panel = SidebarPanel(rawValue: name) else { return }
        let popover = panel == .tags ? tab.tagsController.popover : tab.stashesController.popover
        after(0.2) {
            clickSidebarRow(panel, on: tab)
            whenShown(popover, attempts: 20) { window in
                guard let window else {
                    FileHandle.standardError.write(Data("panel \(name) did not open\n".utf8))
                    return
                }
                whenSettled(tab.tagsController, attempts: 150) { drivePanel(popover, in: window, on: tab, name: name) }
            }
        }
    }

    private static func drivePanel(_ popover: PanelPopover, in window: NSWindow, on tab: RepositoryViewController, name: String) {
        let list = popover.list
        if let scope = environment["GITBONSAI_PANEL_SCOPE"] {
            list.selectScope(list.scopes.firstIndex { $0.title == scope })
            FileHandle.standardError.write(Data("panel scope \(scope): \(list.activeScope.map(String.init) ?? "none"), placeholder \(list.filterField.placeholder)\n".utf8))
        }
        if let filter = environment["GITBONSAI_PANEL_FILTER"] {
            list.filterField.stringValue = filter
            list.filterField.onChange?(filter)
        }
        if let lines = environment["GITBONSAI_PANEL_SCROLL"].flatMap(Int32.init), let source = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -lines, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: source) {
            list.tableView.enclosingScrollView?.scrollWheel(with: event)
        }
        printRows(of: list, name: name)
        if let row = environment["GITBONSAI_PANEL_SELECT"].flatMap(Int.init), row < list.tableView.numberOfRows {
            let rect = list.tableView.rect(ofRow: row)
            pressView(in: window, at: list.tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
            let selectedRow = tab.history.selectedRow
            let historyCommit = selectedRow >= 0 ? String(tab.viewModel.commits[selectedRow].id.prefix(RefString.shortSHA)) : "none"
            FileHandle.standardError.write(Data("panel selected \(list.selectedID ?? "nothing"), history at \(historyCommit)\n".utf8))
        }
        if let shot = environment["GITBONSAI_PANEL_SHOT"] { capturePanel(popover, to: shot) }
        if environment["GITBONSAI_PRINT_HISTORY"] != nil { printHistory(of: tab, when: "before the panel action") }
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
        // The action refreshes the tab, and a fetch or push makes the tag list ask the remotes again.
        if environment["GITBONSAI_PANEL_BUTTON"] != nil || environment["GITBONSAI_PANEL_MENU"] != nil, name == SidebarPanel.tags.rawValue {
            watchRefresh(of: tab.tagsController, samples: [], attempts: 600) {
                printRows(of: list, name: "\(name) after the action")
                FileHandle.standardError.write(Data("panel still shown \(popover.isShown)\n".utf8))
                if let shot = environment["GITBONSAI_PANEL_SHOT_AFTER"] { capturePanel(popover, to: shot) }
            }
        }
    }

    /// Samples the marks every few frames from the action until the remotes answered again. `GITBONSAI_PANEL_SHOT_DURING=<png>` renders the list once the refresh runs,
    /// and the samples show whether any tag lost its mark meanwhile.
    private static func watchRefresh(of tags: TagsController, samples: [Int], attempts: Int, sawRefresh: Bool = false, then body: @escaping () -> Void) {
        let list = tags.popover.list
        let marked = list.rows.filter { !$0.badges.isEmpty }.count
        let refreshing = !tags.isSettled
        if refreshing, !sawRefresh {
            FileHandle.standardError.write(Data("panel refreshing, busy \(list.isBusy), note \(list.note ?? "none")\n".utf8))
            printRows(of: list, name: "tags during the refresh")
            if let shot = environment["GITBONSAI_PANEL_SHOT_DURING"] { capturePanel(tags.popover, to: shot) }
        }
        let seen = sawRefresh || refreshing
        // A local delete asks no remote; six quiet seconds end the watch then.
        if (seen && !refreshing) || (!seen && samples.count >= 120) || attempts == 0 {
            FileHandle.standardError.write(Data("tag marks over \(samples.count) samples: fewest marked rows \(samples.min() ?? 0), most \(samples.max() ?? 0), refresh seen \(seen)\n".utf8))
            return body()
        }
        after(0.05) { watchRefresh(of: tags, samples: samples + [marked], attempts: attempts - 1, sawRefresh: seen, then: body) }
    }

    private static func printRows(of list: PanelListView, name: String) {
        FileHandle.standardError.write(Data("panel \(name): \(list.shownRows.map { "\($0.title) [\($0.detail)] \($0.sha)" }.joined(separator: "; ")); filter shown \(!list.filterField.isHidden) „\(list.filterField.stringValue)“, scrolled to \(Int(list.tableView.visibleRect.minY))\n".utf8))
        FileHandle.standardError.write(Data("panel note: \(list.note ?? "none")\n".utf8))
        for row in list.shownRows where !row.badges.isEmpty || row.isHighlighted || row.isDimmed {
            let badges = row.badges.map { "\($0.glyph)\($0.label.map { " " + $0 } ?? "")/\($0.tone)" }.joined(separator: ",")
            FileHandle.standardError.write(Data("tag \(row.title): \(badges)\(row.isHighlighted ? " highlighted" : "")\(row.isDimmed ? " dimmed" : "") | \((row.tooltip ?? "").replacingOccurrences(of: "\n", with: " / "))\n".utf8))
        }
    }

    /// The tag marks come from the remotes after the list opened; captures wait for their answers.
    private static func whenSettled(_ tags: TagsController, attempts: Int, _ body: @escaping () -> Void) {
        if tags.isSettled || attempts == 0 { return body() }
        after(0.1) { whenSettled(tags, attempts: attempts - 1, body) }
    }

    /// The tags are read before the popover opens, so it appears a moment after the click.
    private static func whenShown(_ popover: PanelPopover, attempts: Int, _ body: @escaping (NSWindow?) -> Void) {
        after(0.1) {
            if let window = popover.window { body(window) } else if attempts > 0 { whenShown(popover, attempts: attempts - 1, body) } else { body(nil) }
        }
    }

    /// The sidebar keeps its row frames to itself; they follow from its outline with the same row heights, as long as nothing was collapsed by hand.
    private static func clickSidebarRow(_ panel: SidebarPanel, on tab: RepositoryViewController) {
        let sidebar = tab.sidebar
        typealias M = Theme.Sidebar
        var outline = sidebar.outline
        var y = Theme.Space.s
        var anchor: CGRect?
        for item in outline.items(from: tab.viewModel, remotes: sidebar.remotes) {
            let height: CGFloat
            switch item {
            case .header: y += Theme.Space.xs; height = M.headerHeight
            case .worktree: height = M.worktreeHeight
            case .row: height = M.rowHeight
            }
            if case .row(let row) = item, row.target == panel.target { anchor = CGRect(x: M.rowInset, y: y, width: sidebar.bounds.width - 2 * M.rowInset, height: height) }
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
    static func capturePanel(_ popover: PanelPopover, to path: String) {
        let view = popover.list
        view.window?.appearance = NSApp.appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Toast

    /// Prints every toast with its action. `GITBONSAI_TOAST_SHOT=<png>` renders the window once the first toast with an action has faded in, and `GITBONSAI_TOAST_CLICK=<action>` then clicks that action with a real click
    /// and prints the status line, the working tree's state and the next toast.
    static func toastShown(_ toast: ToastView, text: RefString) {
        let action = toast.action?.title
        FileHandle.standardError.write(Data("toast: \(text.plain)\(action.map { " [\($0)]" } ?? "")\n".utf8))
        guard let action, !didHandleToast, let window = toast.window else { return }
        didHandleToast = true
        after(0.6) {
            if let path = environment["GITBONSAI_TOAST_SHOT"] { renderWindow(window, to: path) }
            guard environment["GITBONSAI_TOAST_CLICK"] == action else { return }
            let button = toast.actionButton
            FileHandle.standardError.write(Data("toast click \(action)\n".utf8))
            pressView(in: window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            guard let tab = toastTab else { return }
            after(1.5) {
                FileHandle.standardError.write(Data("status: \(tab.viewModel.statusText)\nworking tree: \(tab.viewModel.status?.entries.map(\.path).joined(separator: ", ") ?? "-"), stashes \(tab.viewModel.stashes.count)\n".utf8))
            }
        }
    }

    private nonisolated(unsafe) static var didHandleToast = false
    private nonisolated(unsafe) static weak var toastTab: RepositoryViewController?
}
