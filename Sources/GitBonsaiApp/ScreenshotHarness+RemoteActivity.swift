import AppKit

/// Harness switch for the toolbar while a fetch, pull or push runs: starting one with a real click, printing the remote buttons, opening the running button's menu and cancelling.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_REMOTE_STEPS=<step>;…` runs one step every half second once the tab has loaded: `click:Fetch|Pull|Push` clicks the main part of that button with a real click and prints the menu it opens, if any; `cancel:<button>` opens the running button's menu with a real click and chooses its entry; `print` prints the remote buttons, the fetch state and the status line; `shot:<png>` renders the window; `wait:<seconds>`.
    static func driveRemoteActivity(on tab: RepositoryViewController) {
        guard let script = environment["GITBONSAI_REMOTE_STEPS"] else { return }
        var delay = 0.6
        for step in script.split(separator: ";").map(String.init) {
            let (name, argument) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
            if name == "wait" {
                delay += Double(argument) ?? 0
                continue
            }
            after(delay) { runRemoteStep(name, argument, on: tab) }
            delay += 0.5
        }
    }

    private static func runRemoteStep(_ name: String, _ argument: String, on tab: RepositoryViewController) {
        let write = { (line: String) in FileHandle.standardError.write(Data("remote step \(name): \(line)\n".utf8)) }
        switch name {
        case "click", "cancel":
            guard let button = toolbarButton(argument, on: tab) else { return }
            let menu = clickOpeningMenu(button)
            write("\(argument) \(button.isEnabled ? "enabled" : "disabled"), menu \(menu.map { $0.items.map(\.plainTitle).joined(separator: "; ") } ?? "none")")
            if name == "cancel", let menu, let entry = menu.items.first { choose(entry.plainTitle, in: menu) }
        case "print":
            write("\n\(tab.toolbar.remoteButtonsText)\nfetch state: \(tab.toolbar.fetchStateText)\nstatus: \(tab.viewModel.statusText)")
        case "shot":
            guard let window = tab.view.window else { return }
            renderWindow(window, to: argument)
        default:
            write("unknown step")
        }
    }

    /// A real click on the button's main part; a menu it opens is taken and closed by a timer in the menu's tracking mode, so the click returns.
    private static func clickOpeningMenu(_ button: MenuButton) -> NSMenu? {
        nonisolated(unsafe) var opened: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            opened = menu
            let close = Timer(timeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { menu?.cancelTracking() } }
            RunLoop.current.add(close, forMode: .eventTracking)
            RunLoop.current.add(close, forMode: .common)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        press(button, at: NSPoint(x: button.bounds.minX + button.bounds.height, y: button.bounds.midY))
        return opened
    }
}
