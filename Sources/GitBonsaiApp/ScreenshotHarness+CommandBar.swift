import AppKit
import GitEngine

/// Harness switches for the command bar and for opening folders in editors and terminals.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_COMMAND_BAR=<step>;…` drives the command bar with real key events once the active tab has loaded, half a second per step, then captures the window:
    /// `open` (⇧⌘P through the main menu), `type:<text>`, `key:down|up|return|escape|backspace`, `click:<row>`, `print`, `status`, `wait:<seconds>`, `shot:<png>`,
    /// `menu` (the menu bar tree), `shortcut:cmd-shift-u` (a key equivalent through the main menu), `pick:<menu>/<item>` (a menu item as a click chooses it),
    /// `settings` (opens the settings window and makes it key), `windows` (the visible windows, the key window and the tabs).
    /// `GITBONSAI_PRINT_OPENERS=1` first prints how every known terminal and editor would open the tab's folder. Returns false when there is nothing to drive.
    static func driveCommandBar(in window: NSWindow, host: MainWindowController) -> Bool {
        if environment["GITBONSAI_PRINT_OPENERS"] == "1" { printOpeners(for: host.activeRepository?.repositoryPath) }
        // The tab reads its remotes and pull settings right after loading; the menu is printed once they are in.
        if environment["GITBONSAI_PRINT_MENU"] == "1", environment["GITBONSAI_COMMAND_BAR"] == nil {
            after(1) {
                printMainMenu()
                captureAndQuit(window: window)
            }
            return true
        }
        guard let script = environment["GITBONSAI_COMMAND_BAR"] else { return false }
        let steps = script.split(separator: ";").map(String.init)
        // Each run starts without recently used commands, so lists and captures do not depend on earlier runs.
        CommandRecents().clear()
        func step(_ index: Int) {
            guard index < steps.count else { return captureAndQuit(window: window) }
            let delay = perform(steps[index], in: window, host: host)
            after(delay) { step(index + 1) }
        }
        step(0)
        return true
    }

    /// Runs one step and returns how long to wait before the next.
    private static func perform(_ step: String, in window: NSWindow, host: MainWindowController) -> TimeInterval {
        let bar = CommandBarController.shared
        let (name, argument) = step.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        switch name {
        case "open":
            let event = keyEvent("p", code: 35, flags: [.command, .shift], in: window)
            let handled = event.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
            report("⌘⇧P \(handled ? "handled by the main menu" : "not handled"), bar \(bar.isOpen ? "open" : "closed"), first responder \(responderName(window.firstResponder))")
        case "type":
            for character in argument {
                if let event = keyEvent(String(character), code: 0, flags: [], in: window) { NSApp.postEvent(event, atStart: false) }
            }
        case "key":
            let keys: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
                "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, [.numericPad, .function]),
                "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126, [.numericPad, .function]),
                "return": ("\r", 36, []),
                "escape": ("\u{1b}", 53, []),
                "backspace": ("\u{7f}", 51, []),
            ]
            guard let key = keys[argument], let event = keyEvent(key.0, code: key.1, flags: key.2, in: window) else {
                report("command bar: unknown key \(argument)")
                return 0
            }
            NSApp.postEvent(event, atStart: false)
        case "click":
            guard let row = Int(argument), let table = views(of: CommandBarPanel.self, in: window).first?.table, row < table.numberOfRows else {
                report("command bar: no row \(argument) to click")
                return 0
            }
            let rect = table.rect(ofRow: row)
            click(in: window, at: table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
        case "menu":
            printMainMenu()
        case "shortcut":
            // `shortcut:cmd-shift-u` presses that key equivalent through the main menu, as a key press reaches it.
            let parts = argument.split(separator: "-").map(String.init)
            let names: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control]
            let flags = parts.dropLast().reduce(NSEvent.ModifierFlags()) { $0.union(names[$1] ?? []) }
            let key = parts.last == "return" ? "\r" : parts.last ?? ""
            let handled = keyEvent(key, code: 0, flags: flags, in: window).map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
            report("shortcut \(argument) \(handled ? "handled by the main menu" : "not handled")")
        case "pick":
            // `pick:Branch/Checkout Branch…` chooses a menu bar item the way a click does, after AppKit's update and validation.
            let path = argument.split(separator: "/", maxSplits: 1).map(String.init)
            guard path.count == 2, let menu = NSApp.mainMenu?.items.first(where: { $0.title == path[0] })?.submenu else {
                report("menu: no menu \(argument)")
                return 0
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title == path[1] }), menu.items[index].isEnabled else {
                report("menu: \(argument) missing or disabled")
                return 0
            }
            menu.performActionForItem(at: index)
            report("menu: picked \(argument)")
        case "settings":
            SettingsWindowController.shared.show()
            SettingsWindowController.shared.window?.makeKey()
            report("settings shown, key window \(NSApp.keyWindow.map { $0 === window ? "main" : $0.title } ?? "none")")
        case "windows":
            let open = NSApp.windows.filter(\.isVisible).map { $0 === window ? "main" : $0.title.isEmpty ? "\(type(of: $0))" : $0.title }
            report("windows: \(open.joined(separator: ", ")); key \(NSApp.keyWindow.map { $0 === window ? "main" : $0.title } ?? "none"); tabs \(host.commandTabs.titles.joined(separator: ", "))")
        case "print":
            report(bar.harnessDescription + "\nfirst responder \(responderName(window.firstResponder))")
        case "status":
            guard let tab = host.activeRepository else { return 0 }
            let status = tab.viewModel.status
            report("status: branch \(status?.branch.branch ?? "detached") at \(status?.branch.headSHA?.prefix(RefString.shortSHA) ?? "-"), upstream \(status?.branch.upstream ?? "none") ↑\(status?.branch.ahead ?? 0) ↓\(status?.branch.behind ?? 0), line \"\(tab.viewModel.statusText)\"")
        case "wait":
            return Double(argument) ?? 1
        case "shot":
            render(window, to: argument)
        default:
            report("command bar: unknown step \(step)")
        }
        return 0.5
    }

    /// Every menu of the menu bar after AppKit's update and validation: title, shortcut, and whether it is enabled; submenus indented.
    static func printMainMenu() {
        guard let bar = NSApp.mainMenu else { return }
        var lines = ["main menu:"]
        func describe(_ menu: NSMenu, depth: Int) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            // Alternates show only while a modifier is held, such as AppKit's Dictation and Emoji variants.
            for item in menu.items where !item.isAlternate && !item.isHidden {
                let indent = String(repeating: "  ", count: depth)
                if item.isSeparatorItem {
                    lines.append(indent + "———")
                    continue
                }
                let flags = item.keyEquivalentModifierMask
                let shortcut = item.keyEquivalent.isEmpty ? "" : " " + CommandShortcut(item.keyEquivalent, flags).display
                let state = item.submenu != nil ? " ▸" : item.isEnabled ? "" : " (disabled\(item.toolTip.map { ": \($0)" } ?? ""))"
                lines.append(indent + item.title + shortcut + state)
                if let submenu = item.submenu, submenu !== NSApp.servicesMenu { describe(submenu, depth: depth + 1) }
            }
        }
        describe(bar, depth: 0)
        report(lines.joined(separator: "\n"))
    }

    /// Printed instead of launching an app, so harness runs never open editors or terminals.
    static func reportOpening(_ app: String, _ plan: String) {
        report("open in \(app): \(plan)")
    }

    private static func printOpeners(for path: String?) {
        let folder = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        for (kind, apps) in [("terminal", ExternalApps.Kind.terminal.catalog), ("editor", ExternalApps.Kind.editor.catalog)] {
            for app in apps {
                let installed = app.url
                let location = installed ?? URL(fileURLWithPath: "/Applications/\(app.name).app")
                report("\(kind) \(app.name) (\(app.bundleID)): \(installed == nil ? "not installed" : "installed") → \(ExternalApps.plan(for: folder, in: app, at: location))")
            }
        }
        for kind in ExternalApps.Kind.allCases {
            let found = ExternalApps.choices(kind).map { "\($0.app.name)\($0.isShown ? "" : " (unchecked)")" }
            report("\(kind) choices: \(found.joined(separator: ", ")); default \(ExternalApps.preferred(kind)?.app.name ?? "none")")
        }
    }

    private static func keyEvent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    private static func responderName(_ responder: NSResponder?) -> String {
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField {
            if field.superview?.superview is TextInput, field.firstAncestor(CommandBarPanel.self) != nil { return "command bar field" }
            return "\(type(of: field)) editor"
        }
        return responder.map { "\(type(of: $0))" } ?? "none"
    }

    /// A foreground run takes the picture from the window server, the only renderer that draws Liquid Glass (it needs Screen Recording for the app); a background run renders the views.
    private static func render(_ window: NSWindow, to path: String) {
        if !runsInBackground {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
            try? capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus == 0 { return }
            report("screencapture failed (Screen Recording not allowed?); rendering the views, which leaves the glass's surroundings blank")
        }
        guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}

private extension NSView {
    func firstAncestor<T: NSView>(_ type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}
