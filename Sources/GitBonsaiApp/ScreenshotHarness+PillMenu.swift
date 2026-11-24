import AppKit

/// Harness switch for the context menus of history ref pills.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_PILL_MENU=<step>,…` right-clicks with real events, one step a second, and prints the menu the view under the pointer gives for them (without opening it on screen):
    /// `pill:<row>:<n>` the middle of the n-th pill of a row (0 is the rightmost), `corner:<row>:<n>` the top left corner of its frame just outside the capsule, `counter:<row>` the "+n" counter,
    /// `row:<row>` the commit text, `overlay:<n>` the n-th pill of the expanded labels. `GITBONSAI_PILL_MENU_PICK=<title>` chooses an entry from the last menu printed.
    /// With `GITBONSAI_MENU_SHOT=<png>` the last step's menu opens on screen for a moment and is rendered.
    static func drivePillMenus(_ history: HistoryViewController) {
        guard let steps = environment["GITBONSAI_PILL_MENU"]?.split(separator: ",").map(String.init) else { return }
        let table = history.tableView
        func compact(_ row: Int) -> (RefPills.CompactLayout, [PillModel])? {
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? GraphRowView, let model = view.model, let label = model.columns.layout(in: table.bounds.width).label else { return nil }
            return (RefPills.compactLayout(model.pills, labelEnd: label.upperBound, midY: table.rect(ofRow: row).midY), model.pills)
        }
        func target(_ parts: [String]) -> (point: NSPoint, what: String)? {
            let row = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let index = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            switch parts.first {
            case "pill", "corner":
                guard let (layout, pills) = compact(row), let placement = layout.placements.first(where: { $0.index == index }) else { return nil }
                let rect = placement.rect
                let name = pills[index].name + (placement.isTruncated ? "… (truncated)" : "")
                return parts[0] == "pill" ? (NSPoint(x: rect.midX, y: rect.midY), "pill \(name)") : (NSPoint(x: rect.minX + 1, y: rect.minY + 1), "corner of pill \(name)")
            case "counter":
                guard let counter = compact(row)?.0.counter else { return nil }
                return (NSPoint(x: counter.rect.midX, y: counter.rect.midY), "counter \(counter.text.string)")
            case "row":
                return (NSPoint(x: history.columnsController.columns.layout(in: table.bounds.width).commit.lowerBound + Theme.Space.xl, y: table.rect(ofRow: row).midY), "commit text")
            case "overlay":
                guard let content = history.refOverlay.overlay.content, let placement = content.placements.first(where: { $0.index == row }) else { return nil }
                return (NSPoint(x: placement.rect.midX, y: placement.rect.midY), "expanded pill \(content.pills[placement.index].name) of row \(content.row)")
            default:
                return nil
            }
        }
        var lastMenu: NSMenu?
        for (offset, step) in steps.enumerated() {
            after(0.3 + Double(offset)) {
                guard let window = table.window else { return }
                guard let (point, what) = target(step.split(separator: ":").map(String.init)) else {
                    FileHandle.standardError.write(Data("pill menu \(step): nothing there\n".utf8))
                    return
                }
                let location = table.convert(point, to: nil)
                guard let event = mouseEvent(.rightMouseDown, at: location, in: window), let hit = window.contentView?.superview?.hitTest(location) else { return }
                // A view without a menu passes the right-click on to the view it sits in, as `rightMouseDown` does.
                var view: NSView? = hit
                var menu: NSMenu?
                while let current = view, menu == nil {
                    menu = current.menu(for: event)
                    if menu == nil { view = current.superview }
                }
                let source = view.map { "\(type(of: $0))" } ?? "\(type(of: hit))"
                // The table's own menu is filled by its delegate when it opens.
                if let menu, let delegate = menu.delegate { delegate.menuNeedsUpdate?(menu) }
                lastMenu = menu ?? lastMenu
                let expanded = history.refOverlay.shownRow.map { "row \($0) expanded" } ?? "collapsed"
                FileHandle.standardError.write(Data("pill menu \(step) on \(what) via \(source): \(menu.map(describe) ?? "no menu"); labels \(expanded)\n".utf8))
                if offset == steps.count - 1, let shot = environment["GITBONSAI_MENU_SHOT"], let menu, let view { showAndCapture(menu, with: event, for: view, to: shot) }
            }
        }
        if let pick = environment["GITBONSAI_PILL_MENU_PICK"] {
            after(0.5 + Double(steps.count)) {
                guard let lastMenu else { return }
                FileHandle.standardError.write(Data("pill menu pick: \(pick)\n".utf8))
                choose(pick, in: lastMenu)
            }
        }
    }

    /// Opens the menu as the right-click would and renders it from inside its tracking loop, then closes it.
    private static func showAndCapture(_ menu: NSMenu, with event: NSEvent, for view: NSView, to path: String) {
        // The timer fires on the main run loop; the menu only crosses into its closure.
        nonisolated(unsafe) let tracked = menu
        // `GITBONSAI_MENU_SHOT_AT=<seconds>` keeps the menu open that long; `GITBONSAI_MENU_KEYS=down,right,…` presses arrow keys in it first, such as to open a submenu.
        let keys = (environment["GITBONSAI_MENU_KEYS"] ?? "").split(separator: ",").map(String.init)
        let press = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated { keys.forEach(postMenuKey) }
        }
        RunLoop.current.add(press, forMode: .eventTracking)
        let capture = Timer(timeInterval: environment["GITBONSAI_MENU_SHOT_AT"].flatMap(Double.init) ?? 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                captureMenuWindow(to: path)
                tracked.cancelTracking()
            }
        }
        RunLoop.current.add(capture, forMode: .eventTracking)
        RunLoop.current.add(capture, forMode: .common)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private static func postMenuKey(_ name: String) {
        let arrows: [String: (Int, UInt16)] = [
            "down": (NSDownArrowFunctionKey, 125),
            "up": (NSUpArrowFunctionKey, 126),
            "right": (NSRightArrowFunctionKey, 124),
        ]
        guard let (character, code) = arrows[name], let scalar = UnicodeScalar(character) else { return }
        let text = String(Character(scalar))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
