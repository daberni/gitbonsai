import AppKit
import GitEngine

/// Harness switches for one-time checkout and worktree switch, history set-up and the commit context menu with its sheets.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_HIDDEN_COLUMNS=label,sha` hides those history columns in a harness run.
    static var hiddenColumns: Set<HistoryColumns.Column>? {
        guard isActive, let names = environment["GITBONSAI_HIDDEN_COLUMNS"] else { return nil }
        return Set(names.split(separator: ",").compactMap { HistoryColumns.Column(rawValue: String($0)) })
    }

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
        driveSearch(history)
        driveRefPills(history)
        drivePillMenus(history)
        driveAvatarSweep(history)
    }

    // MARK: Ref pill expansion

    /// `GITBONSAI_REF_PILLS=<step>,…` drives the expansion of a row's ref pills with real mouse events, one step a second: `hover:<row>` moves onto the row's labels,
    /// `brush:<row>` moves onto them and away again within the hover delay, `counter:<row>` clicks the row's "+n", `away` moves onto the commit text of the last row,
    /// `menu` prints the menu of the expanded labels, `click` and `double` click them. The expanded row, its card and its pills go to stderr after each step.
    static func driveRefPills(_ history: HistoryViewController) {
        guard let steps = environment["GITBONSAI_REF_PILLS"]?.split(separator: ",").map(String.init) else { return }
        let table = history.tableView
        var lastRow = 0
        func report(_ step: String) {
            let overlay = history.refOverlay.overlay
            guard let content = overlay.content else {
                FileHandle.standardError.write(Data("ref pills after \(step): collapsed, selected row \(history.selectedRow)\n".utf8))
                return
            }
            let card = content.card
            let names = content.placements.map { content.pills[$0.index].name + ($0.isTruncated ? "…" : "") }.joined(separator: " ")
            let lines = Set(content.placements.map(\.rect.minY)).count
            FileHandle.standardError.write(Data("ref pills after \(step): row \(content.row) expanded, card x \(Int(card.minX)) y \(Int(card.minY - table.rect(ofRow: content.row).minY)) from row top, \(Int(card.width))x\(Int(card.height)), \(content.isWrapped ? "wrapped" : "one line") in \(lines) lines, \(content.placements.count) of \(content.pills.count) pills: \(names); selected row \(history.selectedRow)\n".utf8))
        }
        func move(to point: NSPoint, in window: NSWindow) {
            let location = table.convert(point, to: nil)
            // Tracking areas follow the real cursor only, so the move goes to the view under the point the way tracking would deliver it.
            if let moved = mouseEvent(.mouseMoved, at: location, in: window) { window.contentView?.superview?.hitTest(location)?.mouseMoved(with: moved) }
        }
        func labelPoint(_ row: Int) -> NSPoint {
            let label = history.columnsController.columns.layout(in: table.bounds.width).label ?? 0...0
            return NSPoint(x: label.upperBound - Theme.Pill.trailing - Theme.Space.l, y: table.rect(ofRow: row).midY)
        }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(index)) {
                guard let window = table.window else { return }
                let parts = step.split(separator: ":")
                let row = parts.count > 1 ? Int(parts[1]) ?? lastRow : lastRow
                lastRow = row
                switch parts.first.map(String.init) {
                case "hover":
                    move(to: labelPoint(row), in: window)
                case "brush":
                    move(to: labelPoint(row), in: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.RefOverlay.hoverDelay / 3) { move(to: NSPoint(x: history.columnsController.columns.layout(in: table.bounds.width).commit.lowerBound + Theme.Space.xl, y: table.rect(ofRow: table.numberOfRows - 1).midY), in: window) }
                case "counter":
                    guard let rowView = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? GraphRowView, let model = rowView.model, let label = model.columns.layout(in: table.bounds.width).label, let counter = RefPills.compactLayout(model.pills, labelEnd: label.upperBound, midY: table.rect(ofRow: row).midY).counter else {
                        FileHandle.standardError.write(Data("row \(row) has no counter\n".utf8))
                        return
                    }
                    click(in: window, at: table.convert(NSPoint(x: counter.rect.midX, y: counter.rect.midY), to: nil))
                case "away":
                    move(to: NSPoint(x: history.columnsController.columns.layout(in: table.bounds.width).commit.lowerBound + Theme.Space.xl, y: table.rect(ofRow: table.numberOfRows - 1).midY), in: window)
                case "menu":
                    let overlay = history.refOverlay.overlay
                    guard let card = overlay.content?.card, let event = mouseEvent(.rightMouseDown, at: table.convert(NSPoint(x: card.midX, y: card.midY), to: nil), in: window), let menu = overlay.menu(for: event) else {
                        FileHandle.standardError.write(Data("no menu on the expanded labels\n".utf8))
                        return
                    }
                    FileHandle.standardError.write(Data("ref pills menu: \(describe(menu))\n".utf8))
                case "click", "double":
                    guard let card = history.refOverlay.overlay.content?.card else { return }
                    let location = table.convert(NSPoint(x: card.minX + Theme.Space.l, y: card.minY + card.height / 2), to: nil)
                    let count = step == "double" ? 2 : 1
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) { window.sendEvent(event) }
                    }
                default:
                    FileHandle.standardError.write(Data("unknown ref pills step \(step)\n".utf8))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report(step) }
            }
        }
    }

    // MARK: Commit search

    /// `GITBONSAI_SEARCH=<text>` types into the commit search with real key events through the window, one character at a time; `GITBONSAI_SEARCH_KEYS=return,shift-return,escape,backspace,+<text>` then presses those keys in the field, `+<text>` typing more characters one by one.
    /// After each key the field, the counter, the selected row and commit, the first responder and the dimmed visible rows go to stderr.
    static func driveSearch(_ history: HistoryViewController) {
        guard let text = environment["GITBONSAI_SEARCH"], let field = history.searchField, let window = field.window else { return }
        // Key events reach the field editor through the application only in the key window, and ⇧⏎ is read from the application's current event.
        window.makeKey()
        window.makeFirstResponder(field)
        let startedAt = ContinuousClock.now
        func report(_ step: String) {
            let table = history.tableView
            let visible = table.rows(in: table.visibleRect)
            let rows = visible.location..<(visible.location + visible.length)
            let dimmed = rows.filter { !history.search.isMatch(row: $0) }.count
            let row = history.selectedRow
            let sha = history.selectedID.map { String($0.prefix(RefString.shortSHA)) } ?? "-"
            let onScreen = rows.contains(row) ? "on screen" : "off screen"
            let line = "search \(step): field \"\(field.stringValue)\", counter \(field.counterText ?? "none"), selected row \(row) \(sha) \(onScreen), first responder \(describeResponder(window.firstResponder, field: field)), \(dimmed) of \(rows.count) visible rows dimmed, \(ContinuousClock.now - startedAt) after start\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        var strokes = text.map { (name: "type \($0)", characters: String($0), code: UInt16(0), flags: NSEvent.ModifierFlags()) }
        for key in environment["GITBONSAI_SEARCH_KEYS"]?.split(separator: ",").map(String.init) ?? [] {
            switch key {
            case "return": strokes.append((key, "\r", 36, []))
            case "shift-return": strokes.append((key, "\r", 36, [.shift]))
            case "escape": strokes.append((key, "\u{1b}", 53, []))
            case "backspace": strokes.append((key, "\u{7f}", 51, []))
            case let typed where typed.hasPrefix("+"): strokes += typed.dropFirst().map { ("type \($0)", String($0), 0, []) }
            default: FileHandle.standardError.write(Data("search: unknown key \(key)\n".utf8))
            }
        }
        // Each key waits for the debounce and the scan of the previous one, and the next key follows its report, so every report shows the settled state.
        func press(_ index: Int) {
            guard index < strokes.count else { return }
            let stroke = strokes[index]
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: stroke.flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: stroke.characters, charactersIgnoringModifiers: stroke.characters, isARepeat: false, keyCode: stroke.code) else { return }
            NSApp.postEvent(event, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                report(stroke.name)
                press(index + 1)
            }
        }
        press(0)
    }

    /// The field editor stands for the search field while it edits.
    private static func describeResponder(_ responder: NSResponder?, field: CommitSearchField) -> String {
        if let editor = responder as? NSTextView, editor.delegate === field { return "search field" }
        return responder.map { "\(type(of: $0))" } ?? "none"
    }

    // MARK: History contents

    /// `GITBONSAI_RUN_GIT=<argument>;<argument>…` runs one git command the way a write action does and then refreshes the history in place, as every write action does.
    /// `GITBONSAI_PRINT_HISTORY=<seconds>,…` prints the commit count, the selected row with its scroll position, the status line and the first rows after loading and after each delay; a full reload is printed when it happens.
    static func driveHistoryContents(on tab: RepositoryViewController) {
        guard let delays = environment["GITBONSAI_PRINT_HISTORY"]?.split(separator: ",").compactMap({ Double($0) }) else { return }
        let viewModel = tab.viewModel
        let onReset = viewModel.onReset
        viewModel.onReset = { focus in
            FileHandle.standardError.write(Data("history: full reload\n".utf8))
            onReset?(focus)
        }
        printHistory(of: tab, when: "loaded")
        if let spec = environment["GITBONSAI_RUN_GIT"] {
            let arguments = spec.split(separator: ";").map(String.init)
            Task {
                do {
                    _ = try await viewModel.repository.runner.runWrite(arguments)
                } catch {
                    FileHandle.standardError.write(Data("git \(arguments.joined(separator: " ")) failed: \(error)\n".utf8))
                }
                await viewModel.refresh(note: "git \(arguments.joined(separator: " "))")
            }
        }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { printHistory(of: tab, when: "after \(delay) s") }
        }
    }

    // MARK: Status line

    /// `GITBONSAI_STATUS_STEPS=fetch,stage:<path>,outside:<shell command>,…` runs one step every two seconds in this tab: `fetch` fetches all remotes, `stage` stages a path through the staging panel's action, `outside` runs the command with `sh` in the tab's worktree, as a terminal would.
    /// Every change of the status line is printed with the time since its step began, and the line again right before the next step.
    static func driveStatusLine(on tab: RepositoryViewController) {
        guard let steps = environment["GITBONSAI_STATUS_STEPS"]?.split(separator: ",").map(String.init) else { return }
        let viewModel = tab.viewModel
        var stepStart = Date()
        let onStatusChanged = viewModel.onStatusChanged
        viewModel.onStatusChanged = { text in
            FileHandle.standardError.write(Data("status line +\(Int(Date().timeIntervalSince(stepStart) * 1000)) ms: \(text)\n".utf8))
            onStatusChanged?(text)
        }
        FileHandle.standardError.write(Data("status line loaded: \(viewModel.statusText)\n".utf8))
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + 2 * Double(index)) {
                stepStart = Date()
                let (name, argument) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
                FileHandle.standardError.write(Data("status step \(step)\n".utf8))
                switch name {
                case "fetch": tab.fetchController.fetch(.allRemotes)
                case "stage": tab.staging.stage([argument])
                case "outside":
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", argument]
                    process.currentDirectoryURL = URL(fileURLWithPath: viewModel.repository.path)
                    do { try process.run() } catch { FileHandle.standardError.write(Data("outside: \(error)\n".utf8)) }
                default: FileHandle.standardError.write(Data("unknown status step \(step)\n".utf8))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + 2 * Double(index) + 1.9) {
                FileHandle.standardError.write(Data("status line after \(step): \(viewModel.statusText)\n".utf8))
            }
        }
    }

    static func printHistory(of tab: RepositoryViewController, when: String) {
        let viewModel = tab.viewModel
        let commits = viewModel.commits.enumerated().filter { viewModel.kinds[$0.offset] != .wip }.map(\.element)
        let row = tab.history.selectedRow
        let selected = viewModel.commits.indices.contains(row) ? String(viewModel.commits[row].id.prefix(RefString.shortSHA)) : "-"
        let head = viewModel.headSHA.map { String($0.prefix(RefString.shortSHA)) } ?? "-"
        let rows = commits.prefix(8).map { "\($0.id.prefix(RefString.shortSHA)) \($0.subject)" }.joined(separator: " | ")
        let table = tab.history.tableView
        let scrollY = Int(table.visibleRect.minY)
        let rowOnScreen = row >= 0 ? "\(Int(table.rect(ofRow: row).minY - table.visibleRect.minY))" : "-"
        FileHandle.standardError.write(Data("history \(when): \(commits.count) commits, HEAD \(head), selected row \(row) (\(selected)), scroll y \(scrollY), selected row \(rowOnScreen) pt below the top, status: \(viewModel.statusText)\n  rows: \(rows)\n".utf8))
    }

    // MARK: Commit context menu

    /// `GITBONSAI_COMMIT_MENU=<row>` right-clicks a history row with a real event through the window. AppKit shows that menu on screen above other apps for a moment. While the menu is open its entries go to stderr
    /// and `GITBONSAI_MENU_SHOT=<png>` captures the menu's window. `GITBONSAI_MENU_PICK=<title>`, or `<title>/<title>` in a submenu, then chooses an entry.
    /// `GITBONSAI_MENU_LIST=<row>` only prints the entries of a row's menu, without opening it on screen, once its entries have had time to search.
    static func openCommitMenu(on tab: RepositoryViewController) {
        if let row = environment["GITBONSAI_MENU_LIST"].flatMap(Int.init), let items = tab.history.menuItems?(row) {
            let menu = NSMenu()
            items.forEach(menu.addItem)
            // Entries that search the repository, such as the detected rebase base, update their titles once they know more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FileHandle.standardError.write(Data("menu: \(describe(menu))\n".utf8)) }
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
        // Hidden entries are left out, as on screen.
        menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return "|" }
            return item.submenu.map { "\(item.plainTitle) [\(describe($0))]" } ?? item.plainTitle
        }.joined(separator: "; ")
    }

    static func choose(_ path: String, in menu: NSMenu) {
        var current = menu
        // Titles with branch names contain slashes themselves; a whole path that names an entry is that entry.
        let titles = menu.items.contains { $0.plainTitle.hasPrefix(path) } ? [path] : path.split(separator: "/").map(String.init)
        for (depth, title) in titles.enumerated() {
            guard let index = current.items.firstIndex(where: { $0.plainTitle.hasPrefix(title) }) else {
                FileHandle.standardError.write(Data("menu has no entry \(title)\n".utf8))
                return
            }
            if depth == titles.count - 1 {
                FileHandle.standardError.write(Data("chose \(current.items[index].plainTitle)\n".utf8))
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
        FileHandle.standardError.write(Data("asked \(RefText.plain(alert.messageText)): \(RefText.plain(alert.informativeText))\n".utf8))
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
        alert.applyRefText()
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
