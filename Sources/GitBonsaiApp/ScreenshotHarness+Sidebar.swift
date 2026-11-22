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

/// The constant scroller gutter of the sidebar.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SIDEBAR_GUTTER=collapsed|expanded` prints the right edges of the rows, the slot column and the counts with every section collapsed and expanded, under a legacy and an overlay scroller.
    /// It then restores the system's scroller style and leaves the sections in the given state for the capture.
    static func printSidebarGutter(_ sidebar: SidebarView) {
        guard let final = environment["GITBONSAI_SIDEBAR_GUTTER"], let scrollView = sidebar.enclosingScrollView else { return }
        let systemStyle = scrollView.scrollerStyle
        for style in [NSScroller.Style.legacy, .overlay] {
            scrollView.scrollerStyle = style
            for collapsed in [true, false] {
                sidebar.setSections(collapsed: collapsed)
                scrollView.tile()
                scrollView.layoutSubtreeIfNeeded()
                let scrolls = sidebar.contentHeight > scrollView.contentSize.height
                let scroller = scrollView.verticalScroller.map { sidebar.convert($0.bounds, from: $0).minX }
                let rowRight = (0..<sidebar.rowCount).map { sidebar.rowRect(at: $0).maxX }.max() ?? 0
                print("sidebar gutter \(style == .overlay ? "overlay" : "legacy") \(collapsed ? "collapsed" : "expanded"): scrolls \(scrolls), scroller x \(scroller.map { "\($0)" } ?? "none"), view width \(sidebar.bounds.width), row right \(rowRight), slot right \(sidebar.slotRight), count right \(sidebar.valueRight)")
            }
        }
        scrollView.scrollerStyle = systemStyle
        sidebar.setSections(collapsed: final == "collapsed")
    }
}

/// Harness switches for the sidebar's context menus and for opening the new-branch sheet. Sheets the menus raise are answered by `GITBONSAI_FORM` and `GITBONSAI_CONFIRM`.
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
            if environment["GITBONSAI_SIDEBAR_MENU"] == nil, let pick = environment["GITBONSAI_SIDEBAR_MENU_PICK"] { choose(pick, in: menu) }
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
                // The entry runs from the menu that the right-clicked row builds, once the one on screen has closed.
                if let pick = environment["GITBONSAI_SIDEBAR_MENU_PICK"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard let menu = sidebar.menu(forItemAt: index) else { return }
                        choose(pick, in: menu)
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
                guard let button = views(of: NSButton.self, in: window).first(where: { $0.action == #selector(RepositoryToolbar.runBranch(_:)) }) else { return }
                click(in: window, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            default:
                FileHandle.standardError.write(Data("GITBONSAI_NEW_BRANCH takes plus or toolbar\n".utf8))
            }
        }
    }
}

/// Harness switches for the "Neuer Branch" sheet once `GITBONSAI_NEW_BRANCH` opened it.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_NEW_BRANCH_SCRIPT=<step>;…` drives the sheet with real clicks and keys, one step every 0.35 s:
    /// `click:name|picker|worktree|checkout|path|create|cancel`, `click:row:<n>` (n-th entry of the open picker), `type:<text>` into the focused field,
    /// `key:return|escape|up|down|delete`, `print` (the form's state and the picker's entries) and `shot:<png>` (the sheet with the open picker beside it).
    static func driveNewBranchSheet(_ sheet: NewBranchSheet) {
        guard let script = environment["GITBONSAI_NEW_BRANCH_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + 0.35 * Double(index)) {
                runNewBranchStep(step, on: sheet)
            }
        }
    }

    private static func runNewBranchStep(_ step: String, on sheet: NewBranchSheet) {
        let form = sheet.form
        let picker = form.picker
        // Keys and clicks go to the open picker while it is shown, otherwise to the sheet.
        let target = picker.panelWindow ?? sheet.window
        let (verb, argument) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        switch verb {
        case "click":
            if argument.hasPrefix("row:"), let n = Int(argument.dropFirst(4)), let window = picker.panelWindow {
                let rows = (0..<picker.table.numberOfRows).filter { picker.table.delegate?.tableView?(picker.table, shouldSelectRow: $0) ?? false }
                guard rows.indices.contains(n) else { return newBranchLog("no picker row \(n)") }
                let rect = picker.table.rect(ofRow: rows[n])
                click(in: window, at: picker.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
                return
            }
            let views: [String: NSView] = [
                "name": form.nameInput,
                "picker": picker.button,
                "worktree": form.worktreeBox,
                "checkout": form.checkoutBox,
                "path": form.pathInput,
                "create": form.createButton,
                "cancel": form.cancelButton,
            ]
            guard let view = views[argument], !view.isHiddenOrHasHiddenAncestor, let window = view.window else { return newBranchLog("no visible \(argument)") }
            click(in: window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        case "type":
            for character in argument {
                sendNewBranchKey(String(character), code: 0, to: target)
            }
        case "key":
            let keys: [String: (String, UInt16)] = [
                "return": ("\r", 36),
                "escape": ("\u{1b}", 53),
                "up": (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126),
                "down": (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125),
                "delete": ("\u{7f}", 51),
            ]
            guard let (characters, code) = keys[argument] else { return newBranchLog("unknown key \(argument)") }
            sendNewBranchKey(characters, code: code, to: target)
        case "print":
            let start = picker.selection.map { "\($0.title) (\($0.revision))" } ?? "none"
            let mode = form.worktreeBox.isOn ? "worktree \(form.pathInput.stringValue)" : form.checkoutBox.isOn ? "checkout" : "stay"
            let message = form.nameMessage.isHidden ? "none" : form.nameMessage.stringValue
            newBranchLog("new branch: sheet open \(sheet.window.isVisible || sheet.window.sheetParent != nil), name \"\(form.nameInput.stringValue)\", error \(message), start \(start), \(mode), create enabled \(form.createButton.isEnabled), picker open \(picker.isOpen)")
            if picker.isOpen {
                let entries = picker.visibleItems.map { "\($0.selected ? ">" : "")\($0.section): \($0.title)" }
                newBranchLog("picker query \"\(picker.search.stringValue)\": " + entries.joined(separator: " | "))
            }
        case "shot":
            renderNewBranch(sheet, to: argument)
        default:
            newBranchLog("unknown step \(step)")
        }
    }

    private static func sendNewBranchKey(_ characters: String, code: UInt16, to window: NSWindow) {
        let flags: NSEvent.ModifierFlags = code == 125 || code == 126 ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    /// Renders the sheet and, while it is open, the picker's dropdown where it lies on screen, onto one image.
    private static func renderNewBranch(_ sheet: NewBranchSheet, to path: String) {
        let windows = [sheet.window, sheet.form.picker.panelWindow].compactMap { $0 }
        let union = windows.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        let scale = sheet.window.backingScaleFactor
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = union.size
        for window in windows {
            // The popover's glass frame does not survive a cached render, so its content goes onto a plain rounded ground instead.
            let isSheet = window === sheet.window
            guard let view = isSheet ? window.contentView?.superview ?? window.contentView : window.contentView, let part = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            window.appearance = NSApp.appearance
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: part)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            let rect = NSRect(origin: NSPoint(x: frame.minX - union.minX, y: frame.minY - union.minY), size: frame.size)
            // Glass blends with what lies behind it, so a window background goes underneath.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                if isSheet {
                    rect.fill()
                } else {
                    let ground = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.md, yRadius: Theme.Radius.md)
                    ground.fill()
                    Theme.hairline.setStroke()
                    ground.stroke()
                }
            }
            part.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        newBranchLog("new branch sheet written to \(path)")
    }

    private static func newBranchLog(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}

/// Harness switches for pulling a branch from its context menu.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_CHOICE=<button title prefix>` answers a question with several ways forward, such as a diverged branch's; without it the harness cancels.
    static func answerChoice(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.layout()
        render(alert)
        FileHandle.standardError.write(Data("asked \(alert.messageText): \(alert.informativeText) [\(alert.buttons.map(\.title).joined(separator: " | "))]\n".utf8))
        guard let wanted = environment["GITBONSAI_CHOICE"], let index = alert.buttons.firstIndex(where: { $0.title.hasPrefix(wanted) }) else { return .cancel }
        FileHandle.standardError.write(Data("chose \(alert.buttons[index].title)\n".utf8))
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    /// `GITBONSAI_PRINT_STATUS=<seconds>,…` prints the status line and the toolbar's ahead/behind counts after each delay.
    static func printStatusLine(of tab: RepositoryViewController) {
        for delay in (environment["GITBONSAI_PRINT_STATUS"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let row = tab.history.selectedRow
                let selected = tab.viewModel.commits.indices.contains(row) ? "\(row) „\(tab.viewModel.commits[row].subject)“" : "\(row)"
                let marks = tab.viewModel.refs.filter { $0.kind == .localBranch }.map { "\($0.name) ↑\($0.ahead.map(String.init) ?? "-") ↓\($0.behind.map(String.init) ?? "-")" }.joined(separator: ", ")
                FileHandle.standardError.write(Data("status after \(delay) s: \(tab.viewModel.statusText) · toolbar \(tab.toolbar.upstreamCounts) · selected row \(selected) · branches \(marks)\n".utf8))
            }
        }
    }
}
