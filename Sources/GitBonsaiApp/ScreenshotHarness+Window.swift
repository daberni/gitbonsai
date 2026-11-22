import AppKit
import GitEngine

/// Harness switches for tabs, the tab row and the start-up trace.
@MainActor
extension ScreenshotHarness {
    // MARK: Startup trace

    /// The start of the process, so the first line already shows how long the app took to get there.
    static let launch: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    /// `GITBONSAI_TRACE_STARTUP=1` prints every state of the tab row and every rebuild of a sidebar, with the time since launch, to count redraws while the app opens.
    static func traceStartup(_ line: @autoclosure () -> String) {
        guard environment["GITBONSAI_TRACE_STARTUP"] == "1" else { return }
        let milliseconds = Int(Date().timeIntervalSince(launch) * 1000)
        FileHandle.standardError.write(Data("[\(milliseconds) ms] \(line())\n".utf8))
    }

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
