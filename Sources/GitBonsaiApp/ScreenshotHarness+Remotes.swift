import AppKit
import GitEngine

/// Harness switches for the fetch menu, running a commit menu entry without showing the menu, the onto sheet and the operation banner.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_ONTO=<base>` fills the new base of the onto sheet.
    static var ontoBase: String? { isActive ? environment["GITBONSAI_ONTO"] : nil }

    static func runRemotesAndRebase(on tab: RepositoryViewController) {
        // The remotes and the banner are read asynchronously after the load; both are there a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            printBanner(of: tab, when: "loaded")
            runFetchMenu(on: tab)
            runMenuEntry(on: tab)
            clickBanner(on: tab)
        }
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
