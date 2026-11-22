import AppKit
import GitEngine

/// Harness switches for the toolbar's badges, automatic fetching, the fetch, pull and push menus and their buttons, running a commit menu entry without showing the menu, the onto sheet and the operation banner.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_ONTO=<base>` fills the new base of the onto sheet.
    static var ontoBase: String? { isActive ? environment["GITBONSAI_ONTO"] : nil }

    static func runRemotesAndRebase(on tab: RepositoryViewController) {
        // The remotes and the banner are read asynchronously after the load; both are there a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if environment["GITBONSAI_BANNER_CLICK"] != nil { printBanner(of: tab, when: "loaded") }
            printToolbarLayout(of: tab)
            runFetchMenu(on: tab)
            runPullOrPush(on: tab)
            runToolbarDefault(on: tab)
            runMenuEntry(on: tab)
            clickBanner(on: tab)
            runAutoFetchSteps(on: tab)
        }
    }

    /// `GITBONSAI_AUTO_FETCH=<seconds>` turns automatic fetching on for a harness run, which otherwise never fetches by itself: on activation, and periodically at that interval unless it is 0.
    static var asksForAutoFetch: Bool { isActive && environment["GITBONSAI_AUTO_FETCH"] != nil }

    static var autoFetchSeconds: TimeInterval? {
        guard asksForAutoFetch else { return nil }
        return environment["GITBONSAI_AUTO_FETCH"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    static func traceAutoFetch(_ trigger: AutoFetchPolicy.Trigger, skip: AutoFetchPolicy.Skip?) {
        guard isActive else { return }
        FileHandle.standardError.write(Data("auto-fetch \(trigger.rawValue): \(skip.map { "skip \($0.rawValue)" } ?? "fetch with \(GitRunner.defaultGitPath())")\n".utf8))
    }

    private static var autoFetchTabs: [WeakTab] = []
    private struct WeakTab { weak var tab: RepositoryViewController? }

    /// `GITBONSAI_AUTO_FETCH_STEPS=activate,tab,…` posts the app's activation or selects the next tab, one step every two seconds, and prints each tab's toolbar counts after each step.
    private static func runAutoFetchSteps(on tab: RepositoryViewController) {
        guard let spec = environment["GITBONSAI_AUTO_FETCH_STEPS"] else { return }
        autoFetchTabs.append(WeakTab(tab: tab))
        guard autoFetchTabs.count == 1 else { return }
        let steps = ["loaded"] + spec.split(separator: ",").map(String.init)
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 * Double(index)) {
                FileHandle.standardError.write(Data("auto-fetch step \(step)\n".utf8))
                switch step {
                case "activate": NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                case "tab": NSApp.windows.lazy.compactMap { $0.windowController as? MainWindowController }.first?.selectNextTab()
                default: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    for case let shown? in autoFetchTabs.map(\.tab) {
                        FileHandle.standardError.write(Data("toolbar counts \(shown.name)\(shown.view.window == nil ? "" : " (visible)"): \(shown.toolbar.upstreamCounts)\n".utf8))
                    }
                }
            }
        }
    }

    /// `GITBONSAI_TOOLBAR_LAYOUT=1` prints the Pull and Push badges, each action button's frame and the Pull and Push tooltips.
    private static func printToolbarLayout(of tab: RepositoryViewController) {
        guard environment["GITBONSAI_TOOLBAR_LAYOUT"] == "1" else { return }
        FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\n\(tab.toolbar.actionLayout)\n".utf8))
    }

    /// `GITBONSAI_FETCH_MENU=1` prints the Fetch button's menu with each entry's command, without opening it; `GITBONSAI_FETCH_PICK=<title>` chooses an entry and prints the status line once the fetch has finished.
    private static func runFetchMenu(on tab: RepositoryViewController) {
        let menu = tab.fetchController.menu()
        if environment["GITBONSAI_FETCH_MENU"] == "1" {
            let entries = menu.items.map { $0.isSeparatorItem ? "|" : "\($0.plainTitle) (\($0.toolTip ?? ""))\($0.isEnabled ? "" : " disabled")" }
            FileHandle.standardError.write(Data("fetch menu: \(entries.joined(separator: "; "))\n".utf8))
        }
        guard let pick = environment["GITBONSAI_FETCH_PICK"] else { return }
        choose(pick, in: menu)
        printStatus(of: tab, after: 1.5)
    }

    /// `GITBONSAI_FETCH=<title>`, `GITBONSAI_PULL=<title>`, `GITBONSAI_PUSH=<title>` or `GITBONSAI_STASH=<title>` clicks the chevron of that toolbar button with a real click, prints the menu it opens (`GITBONSAI_MENU_SHOT=<png>` renders it) and closes it again, then chooses the entry and prints
    /// the status line, the banner, the toolbar's counts and the button frames once git has finished. Questions are answered by `GITBONSAI_FORM` and `GITBONSAI_CONFIRM`; an empty title only prints the menu.
    private static func runPullOrPush(on tab: RepositoryViewController) {
        // The switch is named in English; the button is found by the title it shows.
        let buttons = [
            ("Fetch", String(localized: "toolbar.fetch.title", defaultValue: "Fetch", bundle: .module)),
            ("Pull", String(localized: "toolbar.pull.title", defaultValue: "Pull", bundle: .module)),
            ("Push", String(localized: "toolbar.push.title", defaultValue: "Push", bundle: .module)),
            ("Stash", String(localized: "toolbar.stash.title", defaultValue: "Stash", bundle: .module)),
        ]
        for (title, shown) in buttons {
            guard let pick = environment["GITBONSAI_\(title.uppercased())"] else { continue }
            FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\n".utf8))
            guard let menu = openToolbarMenu(shown, on: tab) else { continue }
            let entries = menu.items.map { $0.isSeparatorItem ? "|" : "\($0.plainTitle) (\($0.toolTip ?? ""))\($0.isEnabled ? "" : " disabled")" }
            FileHandle.standardError.write(Data("\(title.lowercased()) menu: \(entries.joined(separator: "; "))\n".utf8))
            guard !pick.isEmpty else { continue }
            choose(pick, in: menu)
            printBanner(of: tab, when: "after \(title.lowercased())", delay: 2.5)
            printStatus(of: tab, after: 2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\n\(tab.toolbar.actionLayout)\n".utf8))
            }
        }
    }

    /// `GITBONSAI_TOOLBAR_DEFAULT=Fetch|Pull|Push|Stash` clicks the main part of that split button with a real click and prints the status line, the banner and the toolbar's counts once git has finished.
    private static func runToolbarDefault(on tab: RepositoryViewController) {
        guard let title = environment["GITBONSAI_TOOLBAR_DEFAULT"], let button = toolbarButton(title, on: tab) else { return }
        FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\ntoolbar \(title) default, enabled \(button.isEnabled)\n".utf8))
        press(button, at: NSPoint(x: button.bounds.minX + button.bounds.height, y: button.bounds.midY))
        printBanner(of: tab, when: "after \(title.lowercased()) default", delay: 2.5)
        printStatus(of: tab, after: 2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\n".utf8))
        }
    }

    private static func toolbarButton(_ title: String, on tab: RepositoryViewController) -> MenuButton? {
        guard let window = tab.toolbar.window, let button = views(of: MenuButton.self, in: window).first(where: { $0.title == title && $0.isDescendant(of: tab.toolbar) }) else {
            FileHandle.standardError.write(Data("no toolbar button \(title)\n".utf8))
            return nil
        }
        return button
    }

    /// The button runs its own tracking loop for the press and the menu another one inside it; a timer in that mode takes the open menu and closes it, so the press returns.
    private static func openToolbarMenu(_ title: String, on tab: RepositoryViewController) -> NSMenu? {
        guard let button = toolbarButton(title, on: tab) else { return nil }
        FileHandle.standardError.write(Data("toolbar \(title) enabled \(button.isEnabled)\n".utf8))
        nonisolated(unsafe) var opened: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            opened = menu
            let close = Timer(timeInterval: 0.3, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let shot = environment["GITBONSAI_MENU_SHOT"] { captureMenuWindow(to: shot) }
                }
                menu?.cancelTracking()
            }
            RunLoop.current.add(close, forMode: .eventTracking)
            RunLoop.current.add(close, forMode: .common)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        press(button, at: NSPoint(x: button.bounds.maxX - Theme.Toolbar.menuPart / 2, y: button.bounds.midY))
        if opened == nil { FileHandle.standardError.write(Data("\(title): no menu opened\n".utf8)) }
        return opened
    }

    /// A window that is not key swallows the first click on a button, so the press goes to the view under the point directly; its tracking loop finds the queued release.
    private static func press(_ button: NSView, at local: NSPoint) {
        guard let window = button.window else { return }
        let point = button.convert(local, to: nil)
        guard let target = window.contentView?.superview?.hitTest(point), let down = mouseEvent(.leftMouseDown, at: point, in: window) else { return }
        if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
        target.mouseDown(with: down)
    }

    /// `GITBONSAI_MENU_RUN=<row>:<title>` runs an entry of a history row's menu, or `<title>/<title>` in a submenu, without opening the menu on screen.
    private static func runMenuEntry(on tab: RepositoryViewController) {
        guard let spec = environment["GITBONSAI_MENU_RUN"], let colon = spec.firstIndex(of: ":"), let row = Int(spec[..<colon]), let items = tab.history.menuItems?(row) else { return }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        choose(String(spec[spec.index(after: colon)...]), in: menu)
        printBanner(of: tab, when: "after menu entry", delay: 1.5)
        printStatus(of: tab, after: 1.5)
    }

    /// `GITBONSAI_BANNER_CLICK=continue|skip|abort` clicks that button of the operation banner with a real click through the window and prints the banner before and after.
    private static func clickBanner(on tab: RepositoryViewController) {
        guard let action = environment["GITBONSAI_BANNER_CLICK"] else { return }
        let banner = tab.operationBanner.view
        let button = switch action {
        case "continue": banner.continueButton
        case "skip": banner.skipButton
        default: banner.abortButton
        }
        guard !banner.isHidden, let window = banner.window else {
            FileHandle.standardError.write(Data("banner: not shown, nothing to click\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("banner click \(button.title), enabled \(button.isEnabled)\n".utf8))
        click(in: window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        printBanner(of: tab, when: "after click", delay: 1.5)
        printStatus(of: tab, after: 1.5)
    }

    private static func printBanner(of tab: RepositoryViewController, when moment: String, delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let banner = tab.operationBanner.view
            let state = banner.isHidden ? "hidden" : "\(banner.text) [Fortsetzen \(banner.continueButton.isEnabled ? "an" : "aus")]"
            FileHandle.standardError.write(Data("banner \(moment): \(state)\n".utf8))
        }
    }

    private static func printStatus(of tab: RepositoryViewController, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            FileHandle.standardError.write(Data("status: \(tab.viewModel.statusText)\n".utf8))
        }
    }
}
