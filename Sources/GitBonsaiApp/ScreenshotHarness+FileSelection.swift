import AppKit
import GitEngine

/// Harness switches for selecting several files in the detail panel and the stacked diffs they open.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_FILE_SELECT=<step>;…` drives the file lists with real mouse events through the window, one step every 0.8 seconds, and prints after each step the selected files and what the history pane shows:
    /// `<n>` clicks file row n, `cmd:<n>` and `shift:<n>` click it with ⌘ or ⇧, `menu:<n>` prints the context menu row n opens with each entry's enabled state and reason, `pick:<title>` then chooses an entry,
    /// `bar:<title>` clicks that button in the bar above stacked diffs, `close` clicks its close button, `shot:<png>` renders the window.
    static func driveFileSelection(on tab: RepositoryViewController) {
        guard let script = environment["GITBONSAI_FILE_SELECT"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        var menu: NSMenu?
        for (index, step) in steps.enumerated() {
            after(1.0 + 0.8 * Double(index)) {
                guard let window = tab.view.window else { return }
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let (name, argument) = parts.count == 2 ? (parts[0], parts[1]) : ("click", parts[0])
                let rows = views(of: FileRowView.self, in: window)
                @MainActor func row(_ text: String) -> FileRowView? {
                    guard let number = Int(text), rows.indices.contains(number) else {
                        selectionLog("no file row \(text) of \(rows.count)")
                        return nil
                    }
                    return rows[number]
                }
                @MainActor func center(_ view: NSView) -> CGPoint { view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
                switch name {
                case "click", "cmd", "shift":
                    guard let row = row(argument) else { return }
                    let flags: NSEvent.ModifierFlags = name == "cmd" ? .command : name == "shift" ? .shift : []
                    clickWithFlags(in: window, at: center(row), flags: flags)
                case "menu":
                    guard let row = row(argument), let event = NSEvent.mouseEvent(with: .rightMouseDown, location: center(row), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    menu = row.menu(for: event)
                    let entries = menu?.items.map { item in
                        if item.isSeparatorItem { return "|" }
                        let title = item.isAlternate ? "⌥ \(item.plainTitle)" : item.plainTitle
                        return item.isEnabled ? title : "\(title) [disabled: \(item.toolTip ?? "no reason")]"
                    } ?? ["no menu"]
                    selectionLog("menu of row \(argument): \(entries.joined(separator: "; "))")
                case "pick":
                    guard let menu else { return selectionLog("no menu to pick from") }
                    choose(argument, in: menu)
                case "bar":
                    guard let button = tab.stackedDiff.bar.actionButtons.first(where: { $0.title == argument }) else { return selectionLog("no bar button \(argument)") }
                    clickWithFlags(in: window, at: center(button), flags: [])
                case "close":
                    clickWithFlags(in: window, at: center(tab.stackedDiff.bar.close), flags: [])
                case "shot":
                    renderWindow(window, to: argument)
                default:
                    selectionLog("unknown file selection step \(step)")
                }
                guard name != "shot" else { return }
                after(0.5) { reportFileSelection(after: step, on: tab) }
            }
        }
    }

    private static func reportFileSelection(after step: String, on tab: RepositoryViewController) {
        let selected = tab.detail.selectedFiles.map { "\($0.path) (\($0.source))" }.joined(separator: ", ")
        let pane: String
        switch tab.historyPane.current {
        case tab.diff.view: pane = "diff of \(tab.diff.selection?.path ?? "nothing")"
        case tab.stackedDiff.view: pane = "stacked \(tab.stackedDiff.summary)"
        case tab.history.view: pane = "graph"
        default: pane = "other"
        }
        let status = tab.viewModel.status.map { status in "unstaged \(status.unstaged.map(\.path)), staged \(status.staged.map(\.path))" } ?? "no status"
        selectionLog("after \(step): selected [\(selected)]; pane \(pane); \(status)")
    }

    private static func clickWithFlags(in window: NSWindow, at point: CGPoint, flags: NSEvent.ModifierFlags) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown) { press(down, in: window) }
    }

    private static func selectionLog(_ line: String) {
        FileHandle.standardError.write(Data("file selection: \(line)\n".utf8))
    }
}
