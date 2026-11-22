import AppKit
import GitEngine

/// Harness switches for tabs and the tab row.
@MainActor
extension ScreenshotHarness {
    /// The start of the process, so printed times show how long the app took to get there.
    static let launch: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    /// `GITBONSAI_NEW_TAB=1` opens the empty tab after the launch arguments or the saved session.
    static var wantsNewTab: Bool { environment["GITBONSAI_NEW_TAB"] != nil }

    /// `GITBONSAI_CLICK_TAB=n` clicks tab n and `GITBONSAI_DRAG_TAB=from:to` drags a tab, both with real events through the window.
    /// Returns false while a clicked tab is still loading; the caller asks again once it has loaded.
    static func driveTabRow(_ tabBar: TabBarView, in window: NSWindow, tabs: () -> TabList) -> Bool {
        // A real click through the window proves that the tab row receives events under the title bar.
        if let target = environment["GITBONSAI_CLICK_TAB"].flatMap(Int.init), target != tabs().activeIndex, let frame = tabBar.frameOfTab(target) {
            click(in: window, at: tabBar.convert(CGPoint(x: frame.midX - 10, y: frame.midY), to: nil))
            if tabs().activeIndex != target { FileHandle.standardError.write(Data("click on tab \(target) did not reach the tab row\n".utf8)) }
            guard tabs().active?.isLoaded == true else { return false }
        }
        // `from:to` drags the tab at `from` onto the place of the tab at `to`. Selecting it calls back in here, so the flag keeps the drag from starting twice.
        if !didDragTab, let spec = environment["GITBONSAI_DRAG_TAB"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let source = tabBar.frameOfTab(parts[0]), let target = tabBar.frameOfTab(parts[1]) {
                didDragTab = true
                let start = tabBar.convert(CGPoint(x: source.midX, y: source.midY), to: nil)
                let end = tabBar.convert(CGPoint(x: target.midX + (parts[1] > parts[0] ? 8 : -8), y: target.midY), to: nil)
                drag(in: window, from: start, to: end, steps: 12)
                let after = tabs()
                FileHandle.standardError.write(Data("tab order after drag: \(after.tabs.map(\.title).joined(separator: ", ")), active \(after.active?.title ?? "")\n".utf8))
            }
        }
        return true
    }

    // MARK: Empty tab

    /// `GITBONSAI_REPOSITORY_FOLDERS=<folder>:<folder>` stores the repository folders in the harness defaults before anything reads them; an empty value stores an empty list.
    static func applyRepositoryFolders() {
        guard isActive, let value = environment["GITBONSAI_REPOSITORY_FOLDERS"] else { return }
        AppSettings.repositoryFolders = value.split(separator: ":").map(String.init)
    }

    /// The empty tab counts as loaded once the first scan finished, so the capture shows found repositories and not only the cache.
    static func waitForDiscovery(_ tab: WindowTab, then capture: @escaping @MainActor () -> Void) {
        let discovery = RepositoryDiscoveryStore.shared
        guard isActive, !discovery.hasScanned else { return }
        tab.isLoaded = false
        discovery.whenScanned {
            tab.isLoaded = true
            capture()
        }
    }

    static func traceDiscovery(_ folders: [RepositoryDiscoveryStore.Folder], duration: Duration) {
        guard isActive else { return }
        let counts = folders.map { "\(($0.path as NSString).abbreviatingWithTildeInPath): \($0.repositories.count) repositories, \($0.repositories.map(\.worktrees.count).reduce(0, +)) linked worktrees" }
        FileHandle.standardError.write(Data("discovery scan took \(duration): \(counts.joined(separator: "; "))\n".utf8))
    }

    /// `GITBONSAI_WELCOME_SEARCH=<text>` types into the empty tab's search field with real key events and `GITBONSAI_WELCOME_KEYS=down,up,return,cmd-return` presses those keys there.
    /// The visible list is printed after the typing and after each key, with the selected row marked.
    static func driveWelcome(_ welcome: WelcomeView, in window: NSWindow) {
        let text = environment["GITBONSAI_WELCOME_SEARCH"] ?? ""
        let keys = environment["GITBONSAI_WELCOME_KEYS"]?.split(separator: ",").map(String.init) ?? []
        guard !text.isEmpty || !keys.isEmpty || environment["GITBONSAI_PRINT_WELCOME"] != nil else { return }
        window.makeKey()
        window.makeFirstResponder(welcome.searchField)
        for character in text {
            let string = String(character)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: string, charactersIgnoringModifiers: string, isARepeat: false, keyCode: 0) else { continue }
            window.sendEvent(event)
        }
        func report(_ step: String) {
            let list = welcome.listView
            var lines = ["welcome \(step): field \"\(welcome.searchField.stringValue)\""]
            var index = 0
            for section in list.list.sections {
                lines.append("  \(section.title)")
                for entry in section.entries {
                    let marks = [entry.branch.map { "[\($0)]" }, entry.isOpen ? "open" : nil].compactMap { $0 }.joined(separator: " ")
                    lines.append("  \(index == list.selection ? ">" : " ") \(entry.isWorktree ? "  " : "")\(entry.name) — \(entry.detail) \(marks)")
                    index += 1
                }
            }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        report("typed")
        for key in keys {
            // The application offers a key with ⌘ to the window as a key equivalent before it becomes a key press, so the harness does the same.
            if key.hasPrefix("cmd-"), key.hasSuffix("return"), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36), window.performKeyEquivalent(with: event) {
                report(key)
                continue
            }
            press(key: key, in: window)
            report(key)
        }
    }
}

/// Harness switches for the window frame and the panel dividers. Harness runs keep both in their own defaults, so they never move the user's window or change their panels.
@MainActor
extension ScreenshotHarness {
    /// Harness runs start from the default frame and panel widths, so captures do not depend on earlier runs; `GITBONSAI_KEEP_LAYOUT=1` restores what the previous harness run saved instead.
    /// `GITBONSAI_WINDOW_FRAME=x,y,w,h[,zoomed][,fullscreen][,screen=<id>]` stores that placement as if an earlier launch had left it.
    static func prepareLayout(_ store: SessionStore) {
        guard isActive else { return }
        if environment["GITBONSAI_KEEP_LAYOUT"] != "1" { store.forgetLayout() }
        guard let spec = environment["GITBONSAI_WINDOW_FRAME"] else { return }
        let parts = spec.split(separator: ",").map(String.init)
        let numbers = parts.prefix(4).compactMap(Double.init)
        guard numbers.count == 4 else { return }
        let screen = parts.first { $0.hasPrefix("screen=") }.flatMap { UInt32($0.dropFirst("screen=".count)) }
        store.windowPlacement = WindowPlacement(frame: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), screen: screen, isZoomed: parts.contains("zoomed"), isFullScreen: parts.contains("fullscreen"))
    }

    /// With a repository tab active, in this order: `GITBONSAI_PRINT_LAYOUT=1` prints the window's frame, screen, zoom and full screen and the panel widths;
    /// `GITBONSAI_RESIZE_WINDOW=<width>` makes the window that wide; `GITBONSAI_DRAG_DIVIDERS=<sidebar>,<detail>` drags the two dividers that many points to the right with real mouse events;
    /// `GITBONSAI_DOUBLE_CLICK_DIVIDER=0|1` double-clicks a divider. The layout is printed after each step.
    static func driveLayout(_ split: PanelSplitView, in window: NSWindow) {
        let prints = environment["GITBONSAI_PRINT_LAYOUT"] == "1"
        func report(_ step: String) {
            let frame = window.frame
            let screens = NSScreen.screens.map { "\($0.displayID.map(String.init) ?? "?") \(describe($0.visibleFrame))" }.joined(separator: "; ")
            FileHandle.standardError.write(Data("layout \(step): window \(describe(frame)) screen \(window.screen?.displayID.map(String.init) ?? "none") zoomed \(window.isZoomed) fullscreen \(window.styleMask.contains(.fullScreen)) | sidebar \(split.sidebarWidth) history \(split.historyWidth) detail \(split.detailWidth) | wished \(split.widths.sidebar) \(split.widths.detail) | screens \(screens)\n".utf8))
        }
        if prints { report("restored") }
        if let width = environment["GITBONSAI_RESIZE_WINDOW"].flatMap(Double.init) {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
            window.layoutIfNeeded()
            report("window \(Int(width)) wide")
        }
        if let spec = environment["GITBONSAI_DRAG_DIVIDERS"] {
            let deltas = spec.split(separator: ",").compactMap { Double($0) }
            for (index, delta) in deltas.prefix(2).enumerated() where delta != 0 {
                let divider = split.dividerFrame(at: index)
                let start = split.convert(CGPoint(x: divider.midX, y: divider.midY), to: nil)
                let steps = 30
                let began = Date()
                drag(in: window, from: start, to: CGPoint(x: start.x + delta, y: start.y), steps: steps)
                let milliseconds = Date().timeIntervalSince(began) * 1000
                report("dragged divider \(index) by \(Int(delta)) in \(steps) steps, \(String(format: "%.1f", milliseconds / Double(steps))) ms a step")
            }
        }
        if let index = environment["GITBONSAI_DOUBLE_CLICK_DIVIDER"].flatMap(Int.init) {
            let divider = split.dividerFrame(at: index)
            let point = split.convert(CGPoint(x: divider.midX, y: divider.midY), to: nil)
            // Each release is queued before its press, so the divider's tracking loop finds it.
            for clickCount in 1...2 {
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
                }
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown) { press(down, in: window) }
            }
            report("double-clicked divider \(index)")
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }
}

/// Harness switches for bringing a tab up to date when the user comes back to it.
@MainActor
extension ScreenshotHarness {
    /// Every harness run prints each reconciliation on return: the triggers it gathered, its outcome and how long it took.
    static func traceReturnRefresh(_ name: String, triggers: [String], outcome: String, duration: Duration) {
        guard isActive else { return }
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        let since = Int(Date().timeIntervalSince(launch) * 1000)
        FileHandle.standardError.write(Data("[\(since) ms] return refresh \(name) [\(triggers.joined(separator: ","))]: \(outcome) in \(String(format: "%.1f", milliseconds)) ms\n".utf8))
    }

    /// Every harness run prints what the file watcher of each tab does: what it watches, each burst it reports and when it stops.
    static func traceWatcher(_ name: String, _ line: String) {
        guard isActive else { return }
        let milliseconds = Int(Date().timeIntervalSince(launch) * 1000)
        FileHandle.standardError.write(Data("[\(milliseconds) ms] watcher \(name): \(line)\n".utf8))
    }

    private static var returnTabs: [WeakReturnTab] = []
    private struct WeakReturnTab { weak var tab: RepositoryViewController? }

    /// `GITBONSAI_RETURN_STEPS=print,outside,tab,activate,…` runs one step every two seconds once the first tab has loaded: `print` prints every tab's history head, refs and counts,
    /// `outside` runs the script `GITBONSAI_OUTSIDE_SCRIPT` names in the first hidden tab's worktree, `tab` selects the next tab and `activate` posts the app's activation and `fetch` runs the toolbar's Fetch in the visible tab; `activate+tab` runs both in one step.
    static func runReturnRefreshSteps(on tab: RepositoryViewController) {
        guard let spec = environment["GITBONSAI_RETURN_STEPS"] else { return }
        returnTabs.append(WeakReturnTab(tab: tab))
        guard returnTabs.count == 1 else { return }
        let steps = spec.split(separator: ",").map(String.init)
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 * Double(index + 1)) {
                FileHandle.standardError.write(Data("[\(Int(Date().timeIntervalSince(launch) * 1000)) ms] return step \(step)\n".utf8))
                let tabs = returnTabs.compactMap(\.tab)
                for part in step.split(separator: "+") {
                    switch part {
                    case "print": tabs.forEach(printReturnState)
                    case "outside": runOutsideScript(in: tabs.first { $0.view.window == nil })
                    case "tab": NSApp.windows.lazy.compactMap { $0.windowController as? MainWindowController }.first?.selectNextTab(nil)
                    case "activate": NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                    case "fetch": tabs.first { $0.view.window != nil }?.fetchController.fetch(.allRemotes)
                    default: break
                    }
                }
            }
        }
    }

    private static func printReturnState(of tab: RepositoryViewController) {
        let model = tab.viewModel
        let head = model.commits.prefix(4).enumerated().map { index, commit in model.kinds[index] == .wip ? "WIP" : "\(commit.shortID) \(commit.subject)" }
        let branches = model.refs.filter { $0.kind == .localBranch }.map { ($0.isHead ? "*" : "") + $0.name }
        let remotes = model.refs.filter { if case .remoteBranch = $0.kind { true } else { false } }.map { "\($0.name) \(model.rowIndex(of: $0.target).map { "row \($0)" } ?? "not in history")" }
        let tags = model.refs.filter { $0.kind == .tag }.map(\.name)
        let entries = model.status?.entries ?? []
        let row = tab.history.selectedRow
        let selected = model.commits.indices.contains(row) ? (model.kinds[row] == .wip ? "WIP" : model.commits[row].shortID) : "none"
        let scroll = tab.history.tableView.enclosingScrollView?.contentView.bounds.minY ?? 0
        let counts = "staged \(entries.filter(\.isStaged).count), unstaged \(entries.filter { $0.worktreeState != .unmodified && !$0.isUntracked }.count), untracked \(entries.filter(\.isUntracked).count), stashes \(model.stashes.count)"
        let lines = [
            "tab \(tab.name)\(tab.view.window == nil ? "" : " (visible)"): \(model.commits.count) rows, selected \(selected) at row \(row), scrolled \(Int(scroll))",
            "  head: \(head.joined(separator: " | "))",
            "  branches: \(branches.joined(separator: ", ")) · remote: \(remotes.joined(separator: ", ")) · tags: \(tags.joined(separator: ", "))",
            "  counts: \(counts) · toolbar \(tab.toolbar.upstreamCounts)",
        ]
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func runOutsideScript(in tab: RepositoryViewController?) {
        guard let tab, let script = environment["GITBONSAI_OUTSIDE_SCRIPT"] else {
            FileHandle.standardError.write(Data("outside: no hidden tab or no GITBONSAI_OUTSIDE_SCRIPT\n".utf8))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script]
        process.currentDirectoryURL = URL(fileURLWithPath: tab.repositoryPath)
        do {
            try process.run()
            process.waitUntilExit()
            FileHandle.standardError.write(Data("[\(Int(Date().timeIntervalSince(launch) * 1000)) ms] outside: ran \(script) in \(tab.name), exit \(process.terminationStatus)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("outside: \(error)\n".utf8))
        }
    }
}
