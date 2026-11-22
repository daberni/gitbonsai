import AppKit
import GitEngine

/// Harness switches for the sidebar.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SIDEBAR_SCROLL=<points>` scrolls the sidebar down and prints where its scroller and status slot column lie.
    /// The capture does not draw an overlay scroller, so the printed edges show whether it would cover the slot.
    static func scrollSidebar(_ sidebar: SidebarView) {
        guard let offset = environment["GITBONSAI_SIDEBAR_SCROLL"].flatMap(Double.init), let scrollView = sidebar.enclosingScrollView else { return }
        sidebar.scroll(CGPoint(x: 0, y: offset))
        let scroller = scrollView.verticalScroller.map { sidebar.convert($0.bounds, from: $0) }
        let style = scrollView.scrollerStyle == .overlay ? "overlay" : "legacy"
        print("sidebar \(style) scroller x \(scroller.map { "\($0.minX)" } ?? "none"), slot right \(sidebar.slotRight), width \(sidebar.bounds.width)")
    }
}

/// Harness switches for the sidebar's context menus and the new-branch sheet. Sheets they raise are answered by `GITBONSAI_FORM` and `GITBONSAI_CONFIRM`.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SIDEBAR_MENU_LIST=<subject>` prints the entries of a sidebar row's menu without opening it; subjects are `branch:<name>` (also `branch:origin/main`) and `worktree:<folder>`.
    /// `GITBONSAI_SIDEBAR_MENU_PICK=<title prefix>` then runs one of those entries.
    /// `GITBONSAI_SIDEBAR_MENU=<subject>` right-clicks the row with a real event instead; AppKit shows that menu on screen for a moment while its entries are printed.
    /// `GITBONSAI_NEW_BRANCH=plus|toolbar` opens the new-branch sheet with a real click on the Local header's plus, or on the toolbar's Branch button.
    static func openSidebarMenu(on tab: RepositoryViewController) {
        let sidebar = tab.sidebar
        if let name = environment["GITBONSAI_SIDEBAR_MENU_LIST"] {
            guard let index = sidebar.itemIndex(named: name), let menu = sidebar.menu(forItemAt: index) else {
                FileHandle.standardError.write(Data("sidebar has no menu for \(name)\n".utf8))
                return
            }
            FileHandle.standardError.write(Data("sidebar menu \(name): \(describe(menu))\n".utf8))
            if let pick = environment["GITBONSAI_SIDEBAR_MENU_PICK"] { choose(pick, in: menu) }
        }
        if let name = environment["GITBONSAI_SIDEBAR_MENU"], let index = sidebar.itemIndex(named: name), let window = sidebar.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let rect = sidebar.rowRect(at: index)
                let point = sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                let inspect = Timer(timeInterval: 0.4, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let open = NSApp.windows.contains { $0.isVisible && "\(type(of: $0))".contains("Menu") }
                        FileHandle.standardError.write(Data("sidebar real menu open: \(open)\n".utf8))
                        if let shot = environment["GITBONSAI_MENU_SHOT"] { captureMenuWindow(to: shot) }
                        // Escape closes the menu that the right click opened.
                        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.postEvent(escape, atStart: true) }
                    }
                }
                RunLoop.current.add(inspect, forMode: .eventTracking)
                if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        }
        guard let mode = environment["GITBONSAI_NEW_BRANCH"], let window = sidebar.window else { return }
        // Like the other harness clicks, it waits until the window has taken its first events.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch mode {
            case "plus":
                guard let index = sidebar.itemIndex(header: "local") else { return }
                let rect = sidebar.rowRect(at: index)
                click(in: window, at: sidebar.convert(NSPoint(x: sidebar.slotRight - Theme.Sidebar.slot / 2, y: rect.midY), to: nil))
            case "toolbar":
                guard let button = views(of: NSButton.self, in: window).first(where: { $0.action == Selector(("runBranch:")) }) else { return }
                click(in: window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            default:
                FileHandle.standardError.write(Data("GITBONSAI_NEW_BRANCH takes plus or toolbar\n".utf8))
            }
        }
    }
}
