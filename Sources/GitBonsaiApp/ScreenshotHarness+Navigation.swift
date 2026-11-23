import AppKit
import GitEngine

/// Harness switches for navigating the history with a diff open, and for comparing several selected commits.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_NAVIGATE=<step>;…` runs one step every `GITBONSAI_NAVIGATE_INTERVAL` seconds (default 1.5) with real clicks and keys through the window, and after each prints
    /// whether a diff is open, the selected commits, what the detail panel shows and the first responder. Steps:
    /// `file:<n>` clicks file n in the detail panel, `row:<n>`, `cmd:<n>` and `shift:<n>` click history row n plainly, with ⌘ or with ⇧, `key:up|down|return|escape` presses that key,
    /// `parent:<n>` clicks parent link n, `sidebar:<subject>` clicks a sidebar row and `sidebar2:<subject>` double-clicks it (subjects as for `GITBONSAI_SIDEBAR_MENU_LIST`), `tags:<n>` opens the tag list and presses entry n,
    /// `search:<text>` types into the commit search, `git:<argument>,<argument>…` runs a git command and refreshes the history in place like a write action, `stage:<path>` stages a file through the app,
    /// `base` clicks the comparison's "since common base", `close` the diff's close button, `focus:history` focuses the history, `tooltips:<row>` prints the tooltip a row registers over its labels, subject, author and date, `width:<points>` resizes the window and `shot:<png>` renders the window.
    static func navigate(on tab: RepositoryViewController) {
        guard let script = environment["GITBONSAI_NAVIGATE"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        let interval = environment["GITBONSAI_NAVIGATE_INTERVAL"].flatMap(Double.init) ?? 1.5
        // Each step reports before the next one starts, so a slow step cannot mix with the next.
        func run(_ index: Int) {
            guard index < steps.count else { return }
            runNavigationStep(steps[index], on: tab)
            after(interval * 0.8) {
                reportNavigation(after: steps[index], on: tab)
                after(interval * 0.2) { run(index + 1) }
            }
        }
        after(0.5) { run(0) }
    }

    private static func runNavigationStep(_ step: String, on tab: RepositoryViewController) {
        guard let window = tab.view.window else { return }
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let table = tab.history.tableView
        func clickRow(_ flags: NSEvent.ModifierFlags) {
            guard let row = Int(argument), row < table.numberOfRows else { return navigationLog("no row \(argument)") }
            guard table.window != nil else { return navigationLog("\(step): the history is not on screen") }
            table.scrollRowToVisible(row)
            let rect = table.rect(ofRow: row)
            let columns = tab.history.columnsController.columns.layout(in: table.bounds.width)
            let point = table.convert(NSPoint(x: columns.commit.lowerBound + Theme.Space.xl, y: rect.midY), to: nil)
            send(click: point, flags: flags, count: 1, in: window)
        }
        switch parts[0] {
        case "file":
            let rows = views(of: FileRowView.self, in: window)
            guard let index = Int(argument), rows.indices.contains(index) else { return navigationLog("only \(rows.count) file rows") }
            let row = rows[index]
            send(click: row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), flags: [], count: 1, in: window)
        case "row": clickRow([])
        case "cmd": clickRow(.command)
        case "shift": clickRow(.shift)
        case "key":
            let keys: [String: (characters: String, code: UInt16, flags: NSEvent.ModifierFlags)] = [
                "up": (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126, [.numericPad, .function]),
                "down": (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125, [.numericPad, .function]),
                "return": ("\r", 36, []),
                "escape": ("\u{1b}", 53, []),
            ]
            guard let key = keys[argument], let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { return }
            // Keys typed into the search field reach its field editor through the application's event queue; the rest goes straight to the window.
            if tab.history.searchField.map({ isEditing($0, in: window) }) == true { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
        case "parent":
            guard let detail = views(of: DetailView.self, in: window).first, let index = Int(argument), detail.parentLinks.indices.contains(index) else { return navigationLog("no parent link \(argument)") }
            let link = detail.parentLinks[index]
            send(click: link.convert(CGPoint(x: link.bounds.midX, y: link.bounds.midY), to: nil), flags: [], count: 1, in: window)
        case "sidebar", "sidebar2":
            guard let index = tab.sidebar.itemIndex(named: argument) else { return navigationLog("no sidebar row \(argument)") }
            let rect = tab.sidebar.rowRect(at: index)
            let point = tab.sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            send(click: point, flags: [], count: 1, in: window)
            if parts[0] == "sidebar2" { send(click: point, flags: [], count: 2, in: window) }
        case "tags":
            // The popover opens beside the sidebar's top; the press on its row is real.
            tab.tagsController.show(relativeTo: NSRect(x: 0, y: 0, width: tab.sidebar.bounds.width, height: Theme.Sidebar.rowHeight), of: tab.sidebar)
            after(0.6) {
                let list = tab.tagsController.popover.list
                guard let popoverWindow = tab.tagsController.popover.window, let row = Int(argument), row < list.tableView.numberOfRows else { return navigationLog("tag list not open or no row \(argument)") }
                let rect = list.tableView.rect(ofRow: row)
                let point = list.tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                guard let target = popoverWindow.contentView?.superview?.hitTest(point), let down = mouseEvent(.leftMouseDown, at: point, in: popoverWindow) else { return }
                if let up = mouseEvent(.leftMouseUp, at: point, in: popoverWindow) { NSApp.postEvent(up, atStart: false) }
                target.mouseDown(with: down)
            }
        case "search":
            guard let field = tab.history.searchField else { return }
            window.makeKey()
            window.makeFirstResponder(field)
            for character in argument {
                let text = String(character)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) { NSApp.postEvent(event, atStart: false) }
            }
        case "git":
            let arguments = argument.split(separator: ",").map(String.init)
            let viewModel = tab.viewModel
            Task {
                do { _ = try await viewModel.repository.runner.runWrite(arguments) } catch { navigationLog("git \(arguments.joined(separator: " ")) failed: \(error)") }
                await viewModel.refresh(note: "git \(arguments.joined(separator: " "))")
            }
        case "stage":
            tab.staging.stage([argument])
        case "base":
            guard let toggle = tab.comparison?.baseSwitch, !toggle.isHiddenOrHasHiddenAncestor else { return navigationLog("no base switch") }
            send(click: toggle.convert(CGPoint(x: toggle.bounds.maxX - Theme.Control.checkbox / 2, y: toggle.bounds.midY), to: nil), flags: [], count: 1, in: window)
        case "close":
            let close = tab.diff.header.close
            send(click: close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil), flags: [], count: 1, in: window)
        case "tooltips":
            guard let row = Int(argument), let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return navigationLog("row \(argument) not on screen") }
            let layout = tab.history.columnsController.columns.layout(in: table.bounds.width)
            let probes: [(String, CGFloat?)] = [
                ("label", layout.label.map { ($0.lowerBound + $0.upperBound) / 2 }),
                ("subject", layout.commit.lowerBound + Theme.Cell.subjectLeading + Theme.Space.s),
                ("author", layout.author.map { ($0.lowerBound + $0.upperBound) / 2 }),
                ("date", layout.date.map { ($0.lowerBound + $0.upperBound) / 2 }),
            ]
            let texts = probes.map { name, x in "\(name) \(x.map { tab.history.toolTips.text(in: view, at: $0).map { "\"\($0)\"" } ?? "none" } ?? "hidden")" }
            navigationLog("tooltips row \(row) at width \(Int(table.bounds.width)): \(texts.joined(separator: ", ")); row-wide tooltip \(view.toolTip ?? "none")")
        case "width":
            guard let points = Double(argument) else { return }
            window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: points, height: window.frame.height)), display: true)
        case "focus":
            window.makeFirstResponder(table)
        case "shot":
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
        default:
            navigationLog("unknown navigation step \(step)")
        }
    }

    private static func reportNavigation(after step: String, on tab: RepositoryViewController) {
        guard !step.hasPrefix("shot:"), let window = tab.view.window else { return }
        let diffOpen = tab.diff.view.window != nil
        let diff = diffOpen ? tab.diff.selection.map { "open \($0.path) (\(describe($0.source)))" } ?? "open, loading" : "closed"
        let selected = tab.history.selectedRows.map { row in
            tab.viewModel.kinds[row] == .wip ? "WIP" : tab.viewModel.commits[row].shortID
        }.joined(separator: " ")
        let detail = tab.comparison.map { "comparison \($0.summary)" } ?? "single"
        let responder: String
        if let field = tab.history.searchField, isEditing(field, in: window) { responder = "search field" } else { responder = window.firstResponder.map { "\(type(of: $0))" } ?? "none" }
        navigationLog("nav after \(step): diff \(diff) | selected \(selected) | \(detail) | focus \(responder)")
    }

    private static func describe(_ source: DiffSource) -> String {
        switch source {
        case .commit(let commit): "commit \(commit.shortID)"
        case .revisions(let base, let target): "\(base.prefix(RefString.shortSHA))..\(target.prefix(RefString.shortSHA))"
        case .unstaged: "unstaged"
        case .staged: "staged"
        case .untracked: "untracked"
        }
    }

    private static func isEditing(_ field: CommitSearchField, in window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.delegate === field
    }

    private static func send(click point: CGPoint, flags: NSEvent.ModifierFlags, count: Int, in window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
        }
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown) { press(down, in: window) }
    }

    private static func navigationLog(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
