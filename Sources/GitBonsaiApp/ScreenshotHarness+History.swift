import AppKit
import GitEngine

/// Harness switches for one-time checkout and worktree switch, history set-up and the commit context menu with its sheets.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_CHECKOUT=<branch>` checks a local branch out and `GITBONSAI_SWITCH_WORKTREE=<folder or path>` switches the tab, once per run. Returns true when one ran.
    static func runOneTimeAction(on tab: RepositoryViewController) -> Bool {
        guard !didRunOneTimeAction else { return false }
        if let branch = environment["GITBONSAI_CHECKOUT"] {
            didRunOneTimeAction = true
            tab.checkoutController.checkout(.localBranch(branch))
            return true
        }
        if let folder = environment["GITBONSAI_SWITCH_WORKTREE"], let info = tab.viewModel.worktrees.first(where: { $0.worktree.path == folder || ($0.worktree.path as NSString).lastPathComponent == folder }) {
            didRunOneTimeAction = true
            tab.onSwitchWorktree?(info.worktree.path)
            return true
        }
        return false
    }

    /// Selection, column width, a real drag over the rows and the sideways scroll of the graph.
    static func prepare(_ history: HistoryViewController) {
        let table = history.tableView
        let columns = history.columnsController
        if let row = environment["GITBONSAI_SELECT_ROW"].flatMap(Int.init), row < table.numberOfRows { history.select(row: row, scroll: true) }
        if let width = environment["GITBONSAI_GRAPH_WIDTH"].flatMap(Double.init), let graph = columns.columns.layout(in: table.bounds.width).graph {
            columns.resize(.graph, to: graph.lowerBound + CGFloat(width))
        }
        if let target = environment["GITBONSAI_DRAG_GRAPH_TO"].flatMap(Double.init), let window = table.window {
            let graph = columns.columns.layout(in: table.bounds.width).graph ?? 0...0
            let y = table.visibleRect.midY
            let start = table.convert(NSPoint(x: graph.upperBound, y: y), to: nil)
            let end = table.convert(NSPoint(x: graph.lowerBound + CGFloat(target), y: y), to: nil)
            drag(in: window, from: start, to: end, steps: 1)
            FileHandle.standardError.write(Data("graph column after drag: \(columns.columns.graph)\n".utf8))
        }
        if let offset = environment["GITBONSAI_GRAPH_SCROLL"].flatMap(Double.init), let graph = columns.columns.layout(in: table.bounds.width).graph {
            _ = columns.scrollGraph(by: -CGFloat(offset), at: NSPoint(x: graph.lowerBound + 1, y: 1))
        }
    }


    // MARK: Commit context menu

    /// `GITBONSAI_COMMIT_MENU=<row>` right-clicks a history row with a real event through the window. AppKit shows that menu on screen above other apps for a moment. While the menu is open its entries go to stderr
    /// and `GITBONSAI_MENU_SHOT=<png>` captures the menu's window. `GITBONSAI_MENU_PICK=<title>`, or `<title>/<title>` in a submenu, then chooses an entry.
    /// `GITBONSAI_MENU_LIST=<row>` only prints the entries of a row's menu, without opening it on screen.
    static func openCommitMenu(on tab: RepositoryViewController) {
        if let row = environment["GITBONSAI_MENU_LIST"].flatMap(Int.init), let items = tab.history.menuItems?(row) {
            let menu = NSMenu()
            items.forEach(menu.addItem)
            FileHandle.standardError.write(Data("menu: \(describe(menu))\n".utf8))
        }
        guard let row = environment["GITBONSAI_COMMIT_MENU"].flatMap(Int.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let table = tab.history.tableView
            guard let window = table.window, row < table.numberOfRows, let menu = table.menu else { return }
            table.scrollRowToVisible(row)
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.minX + rect.width / 3, y: rect.midY), to: nil)
            // The menu runs its own tracking loop inside the click; a timer in that mode reads and captures it, then closes it.
            // The timer fires on the main run loop; the menu only crosses into its closure.
            nonisolated(unsafe) let tracked = menu
            let inspect = Timer(timeInterval: 0.4, repeats: false) { _ in
                MainActor.assumeIsolated {
                    FileHandle.standardError.write(Data("menu: \(describe(tracked))\n".utf8))
                    if let shot = environment["GITBONSAI_MENU_SHOT"] { captureMenuWindow(to: shot) }
                    tracked.cancelTracking()
                }
            }
            RunLoop.current.add(inspect, forMode: .eventTracking)
            RunLoop.current.add(inspect, forMode: .common)
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            if let pick = environment["GITBONSAI_MENU_PICK"] { choose(pick, in: menu) }
        }
    }

    static func describe(_ menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "|" }
            return item.submenu.map { "\(item.title) [\(describe($0))]" } ?? item.title
        }.joined(separator: "; ")
    }

    static func choose(_ path: String, in menu: NSMenu) {
        var current = menu
        let titles = path.split(separator: "/").map(String.init)
        for (depth, title) in titles.enumerated() {
            guard let index = current.items.firstIndex(where: { $0.title.hasPrefix(title) }) else {
                FileHandle.standardError.write(Data("menu has no entry \(title)\n".utf8))
                return
            }
            if depth == titles.count - 1 {
                FileHandle.standardError.write(Data("chose \(current.items[index].title)\n".utf8))
                current.performActionForItem(at: index)
            } else if let submenu = current.items[index].submenu {
                current = submenu
            }
        }
    }

    /// The open menu is a window of the app above the normal level (its glass backdrop is another one, left out); it is rendered like the main window.
    static func captureMenuWindow(to path: String) {
        let menuWindows = NSApp.windows.filter { $0.isVisible && $0.level.rawValue > NSWindow.Level.normal.rawValue }
        FileHandle.standardError.write(Data("menu windows: \(menuWindows.map { "\(type(of: $0)) \($0.frame)" })\n".utf8))
        guard let window = menuWindows.first(where: { "\(type(of: $0))".contains("Menu") }), let view = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The menu draws only its content; without the glass behind it the picture gets the window background.
        guard let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: picture) else { return }
        let bounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        bounds.fill()
        rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Sheets of commit actions are answered here instead of waiting for a click. `GITBONSAI_FORM=key=value;key=value` fills a form
    /// (keys name, branch, path, message, checked=0|1), `GITBONSAI_FORM_CANCEL=1` cancels it, and `GITBONSAI_SHEET_SHOT=<png>` renders the sheet as filled.
    static func answer(_ form: ActionForm) -> ActionForm.Values? {
        var answers: [String: String] = [:]
        for pair in (environment["GITBONSAI_FORM"] ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { answers[parts[0]] = parts[1] }
        }
        form.fill(answers)
        render(form.alert)
        FileHandle.standardError.write(Data("form \(form.alert.messageText): \(form.values.text) checked \(form.values.isChecked)\n".utf8))
        return environment["GITBONSAI_FORM_CANCEL"] == "1" || !form.isComplete ? nil : form.values
    }

    /// `GITBONSAI_CONFIRM=1` accepts a confirmation; without it the harness declines. The question is rendered like a form.
    static func answer(_ alert: NSAlert) -> Bool {
        alert.layout()
        render(alert)
        FileHandle.standardError.write(Data("asked \(alert.messageText): \(alert.informativeText)\n".utf8))
        return environment["GITBONSAI_CONFIRM"] == "1"
    }

    /// `GITBONSAI_RESET_ANSWER=reset|checkout|cancel` answers the question of checking out a diverged branch; without it the harness cancels.
    static func answerReset(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.layout()
        render(alert)
        FileHandle.standardError.write(Data("asked \(alert.messageText): \(alert.informativeText) [\(alert.buttons.map(\.title).joined(separator: " | "))]\n".utf8))
        let wanted = ["reset": 0, "checkout": 1][environment["GITBONSAI_RESET_ANSWER"] ?? ""]
        guard let wanted, wanted < alert.buttons.count - 1 else { return .cancel }
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + wanted)
    }

    /// `GITBONSAI_SAVE_PATH=<file>` answers a save panel.
    static var saveLocation: URL? { environment["GITBONSAI_SAVE_PATH"].map { URL(fileURLWithPath: $0) } }

    static func render(_ alert: NSAlert) {
        guard let path = environment["GITBONSAI_SHEET_SHOT"], let view = alert.window.contentView?.superview ?? alert.window.contentView else { return }
        alert.window.appearance = NSApp.appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        // The sheet's glass and vibrant text blend with what lies behind them; on an empty bitmap dark text vanishes, so a window background goes underneath.
        alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.displayIgnoringOpacity(view.bounds, in: context)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
