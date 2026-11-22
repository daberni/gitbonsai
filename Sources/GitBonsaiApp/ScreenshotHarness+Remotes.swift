import AppKit
import GitEngine

/// Harness switches for the toolbar's badges, the fetch, pull and push menus, running a commit menu entry without showing the menu, the onto sheet and the operation banner.
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
            runMenuEntry(on: tab)
            clickBanner(on: tab)
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
            let entries = menu.items.map { $0.isSeparatorItem ? "|" : "\($0.title) (\($0.toolTip ?? ""))\($0.isEnabled ? "" : " disabled")" }
            FileHandle.standardError.write(Data("fetch menu: \(entries.joined(separator: "; "))\n".utf8))
        }
        guard let pick = environment["GITBONSAI_FETCH_PICK"] else { return }
        choose(pick, in: menu)
        printStatus(of: tab, after: 1.5)
    }

    /// `GITBONSAI_PULL=<title>` or `GITBONSAI_PUSH=<title>` clicks that toolbar button with a real click, prints the menu it opens and closes it again, then chooses the entry and prints
    /// the status line, the banner and the toolbar's counts once git has finished. Questions are answered by `GITBONSAI_FORM` and `GITBONSAI_CONFIRM`; an empty title only prints the menu.
    private static func runPullOrPush(on tab: RepositoryViewController) {
        for title in ["Pull", "Push"] {
            guard let pick = environment["GITBONSAI_\(title.uppercased())"] else { continue }
            FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\n".utf8))
            guard let menu = openToolbarMenu(title, on: tab) else { continue }
            FileHandle.standardError.write(Data("\(title.lowercased()) menu: \(menu.items.map { $0.isSeparatorItem ? "|" : "\($0.title) (\($0.toolTip ?? ""))\($0.isEnabled ? "" : " disabled")" }.joined(separator: "; "))\n".utf8))
            guard !pick.isEmpty else { continue }
            choose(pick, in: menu)
            printBanner(of: tab, when: "after \(title.lowercased())", delay: 2.5)
            printStatus(of: tab, after: 2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                FileHandle.standardError.write(Data("toolbar counts: \(tab.toolbar.upstreamCounts)\n".utf8))
            }
        }
    }

    /// The button runs its own tracking loop for the press and the menu another one inside it; a timer in that mode takes the open menu and closes it, so the press returns.
    private static func openToolbarMenu(_ title: String, on tab: RepositoryViewController) -> NSMenu? {
        guard let window = tab.toolbar.window, let button = views(of: NSButton.self, in: window).first(where: { $0.title == title && $0.isDescendant(of: tab.toolbar) }) else {
            FileHandle.standardError.write(Data("no toolbar button \(title)\n".utf8))
            return nil
        }
        FileHandle.standardError.write(Data("toolbar \(title) enabled \(button.isEnabled)\n".utf8))
        nonisolated(unsafe) var opened: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            opened = menu
            let close = Timer(timeInterval: 0.3, repeats: false) { _ in menu?.cancelTracking() }
            RunLoop.current.add(close, forMode: .eventTracking)
            RunLoop.current.add(close, forMode: .common)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        // A window that is not key swallows the first click on a button, so the press goes to the button under the point directly.
        guard let target = window.contentView?.superview?.hitTest(point), let down = mouseEvent(.leftMouseDown, at: point, in: window) else { return nil }
        if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
        target.mouseDown(with: down)
        if opened == nil { FileHandle.standardError.write(Data("\(title): no menu opened\n".utf8)) }
        return opened
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
