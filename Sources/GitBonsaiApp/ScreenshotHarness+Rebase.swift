import AppKit
import GitEngine

/// Harness switches for the interactive rebase: the sheet driven by real clicks, drags and keys, the amend at an edit stop and the undo in the status line.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_REBASE_SCRIPT=<step>;<step>…` drives the sheet once it is open; open it with `GITBONSAI_COMMIT_MENU=<row>` and `GITBONSAI_MENU_PICK=Rebase interaktiv`.
    /// Steps: `drag:<row>><gap>` drags a row by its grip to the gap before row `gap`, `click:<row>`, `key:<key>` (a letter, `opt-up`, `opt-down`, `up`, `down`),
    /// `popup:<row>=<action>` picks from the row's pop-up, `subject:<row>=<text>` and `message:<text>` replace text by typing (`\n` for a new line),
    /// `toggle:update-refs|autostash`, `print`, `shot:<png>`, `start`, `cancel`. Each step is a real event through the sheet's window.
    static func driveRebaseSheet(_ sheet: InteractiveRebaseSheet) {
        guard isActive, let script = environment["GITBONSAI_REBASE_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { runRebaseSteps(steps[...], on: sheet) }
    }

    private static func runRebaseSteps(_ steps: ArraySlice<String>, on sheet: InteractiveRebaseSheet) {
        guard let step = steps.first else { return }
        log("rebase step \(step)")
        let window = sheet.window
        let table = sheet.list.table
        let (name, argument) = split(step, at: ":")
        switch name {
        case "drag":
            let (from, to) = split(argument, at: ">")
            guard let from = Int(from), let gap = Int(to) else { break }
            let rect = table.rect(ofRow: from)
            let start = table.convert(NSPoint(x: rect.minX + Theme.Space.s + Theme.Icon.regular / 2, y: rect.midY), to: nil)
            let end = table.convert(NSPoint(x: rect.minX + Theme.Space.s + Theme.Icon.regular / 2, y: CGFloat(gap) * table.rowHeight), to: nil)
            drag(in: window, from: start, to: end, steps: 8)
        case "click":
            guard let row = Int(argument) else { break }
            let rect = table.rect(ofRow: row)
            click(in: window, at: table.convert(NSPoint(x: rect.minX + Theme.Space.s + Theme.Icon.regular / 2, y: rect.midY), to: nil))
        case "key":
            press(key: argument, in: window)
        case "popup":
            let (row, action) = split(argument, at: "=")
            guard let row = Int(row), let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RebaseStepRowView else { break }
            pick(action, from: view.actionPopup)
        case "subject":
            let (row, text) = split(argument, at: "=")
            guard let row = Int(row), let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RebaseStepRowView else { break }
            replaceText(in: view.subject, with: text)
        case "message":
            replaceText(in: sheet.messageView, with: argument)
        case "toggle":
            guard let box = argument == "update-refs" ? sheet.updateRefsBox : sheet.autostashBox else { break }
            press(box)
        case "print":
            log("rebase rows: " + sheet.model.steps.indices.map { "\(sheet.model.steps[$0].action.rawValue) \(sheet.model.steps[$0].commit?.shortID ?? "") \(sheet.model.subject(at: $0))" }.joined(separator: " | "))
            log("rebase preview: " + sheet.preview.textLines.joined(separator: " | "))
            log("rebase message: \(sheet.messageView.string.replacingOccurrences(of: "\n", with: "\\n")), start \(sheet.startButton.isEnabled ? "an" : "aus"), selected \(sheet.list.selectedIndex.map(String.init) ?? "-")")
        case "shot":
            renderWindow(window, to: argument)
        case "start":
            press(sheet.startButton)
        case "cancel":
            press(sheet.cancelButton)
        default:
            log("unknown rebase step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { runRebaseSteps(steps.dropFirst(), on: sheet) }
    }

    /// `GITBONSAI_PRINT_SELECTION=<seconds>,…` prints whether the toast shows, the selected history row, whether it is HEAD and whether a diff covers the history after each delay.
    /// `GITBONSAI_REBASE_MENU=<row>,<row>` prints the interactive rebase entries of those rows with the reason a disabled one gives.
    /// `GITBONSAI_EDIT_AMEND=<subject>` at an edit stop clicks "Commit ändern …" in the banner, types the subject into the commit form, clicks Amend and then Fortsetzen, all with real events.
    /// `GITBONSAI_REBASE_UNDO=1` clicks "Rückgängig" in the status line; the question is answered by `GITBONSAI_CONFIRM=1`.
    static func driveRebase(on tab: RepositoryViewController) {
        for row in (environment["GITBONSAI_REBASE_MENU"] ?? "").split(separator: ",").compactMap({ Int($0) }) where tab.viewModel.commits.indices.contains(row) {
            let items = tab.commitActions.interactiveRebase.menuItems(for: tab.viewModel.commits[row])
            log("rebase menu \(row): " + items.map { $0.action == nil ? "\($0.title) (aus: \($0.toolTip ?? ""))" : $0.title }.joined(separator: "; "))
        }
        if let subject = environment["GITBONSAI_EDIT_AMEND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { amendAtEditStop(on: tab, subject: subject) }
        }
        for delay in (environment["GITBONSAI_PRINT_SELECTION"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let row = tab.history.tableView.selectedRow
                let selected = tab.viewModel.commits.indices.contains(row) ? tab.viewModel.commits[row].id : "-"
                log("toast \(tab.toast.view.isHidden ? "hidden" : "shown"), selection: row \(row), HEAD \(selected == tab.viewModel.headSHA ? "selected" : "not selected"), history \(tab.history.view.window == nil ? "hidden behind a diff" : "shown"), status: \(tab.viewModel.statusText)")
            }
        }
        if environment["GITBONSAI_REBASE_UNDO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let button = tab.rebaseUndo.button
                log("undo \(button.isHidden ? "hidden" : "shown: \(button.toolTip ?? "")")")
                guard !button.isHidden else { return }
                press(button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { log("status: \(tab.viewModel.statusText); undo \(button.isHidden ? "hidden" : "shown")") }
            }
        }
    }

    private static func amendAtEditStop(on tab: RepositoryViewController, subject: String) {
        let banner = tab.operationBanner.view
        log("banner: \(banner.isHidden ? "hidden" : banner.text), amend \(banner.amendButton.isHidden ? "hidden" : "shown")")
        guard !banner.amendButton.isHidden else { return }
        press(banner.amendButton)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let form = tab.commitController.form
            guard let window = form.window, let field = views(of: PlainTextField.self, in: window).first(where: { $0.isDescendant(of: form) }), let button = views(of: PrimaryButton.self, in: window).first(where: { $0.isDescendant(of: form) }) else {
                return log("commit form not shown")
            }
            log("commit form: amend \(form.isAmend), subject \(form.subjectText)")
            replaceText(in: field, with: subject)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                log("amend button \(button.title) enabled \(button.isEnabled)")
                press(button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("banner after amend: \(banner.isHidden ? "hidden" : banner.text)")
                    press(banner.continueButton)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        log("banner after continue: \(banner.isHidden ? "hidden" : banner.text)")
                        log("status: \(tab.viewModel.statusText); undo \(tab.rebaseUndo.button.isHidden ? "hidden" : "shown")")
                    }
                }
            }
        }
    }

    /// `GITBONSAI_REPORT_SHOT=<png>` renders an error alert with its details open.
    static func renderReport(_ alert: NSAlert) {
        guard let path = environment["GITBONSAI_REPORT_SHOT"] else { return }
        (alert.accessoryView as? FailureDetailsView)?.isExpanded = true
        alert.layout()
        renderWindow(alert.window, to: path)
    }

    // MARK: Events

    /// A real click in the middle of a control. A background window is never key and drops a press routed through it, even on a control that accepts first mouse,
    /// so the press goes to the view under the point as a key window would deliver it; the control's tracking loop finds the queued release.
    private static func press(_ control: NSView) {
        guard let window = control.window else { return log("not in a window: \(control)") }
        // Views no longer clip to their bounds, so the visible part is the intersection of both.
        let visible = control.visibleRect.intersection(control.bounds)
        let point = control.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        guard !window.isKeyWindow, let target = window.contentView?.superview?.hitTest(point), let down = mouseEvent(.leftMouseDown, at: point, in: window) else { return click(in: window, at: point) }
        // A key window makes the pressed view first responder before it gets the press.
        if target.acceptsFirstResponder { window.makeFirstResponder(target) }
        if let up = mouseEvent(.leftMouseUp, at: point, in: window) { NSApp.postEvent(up, atStart: false) }
        target.mouseDown(with: down)
    }

    /// Clicks the pop-up with a real press, takes the menu it opens and closes it, then chooses the entry the way the menu would.
    private static func pick(_ title: String, from popup: NSPopUpButton) {
        guard let window = popup.window, let down = mouseEvent(.leftMouseDown, at: popup.convert(NSPoint(x: popup.bounds.midX, y: popup.bounds.midY), to: nil), in: window) else { return }
        nonisolated(unsafe) var opened: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            opened = menu
            let close = Timer(timeInterval: 0.3, repeats: false) { _ in menu?.cancelTracking() }
            RunLoop.current.add(close, forMode: .eventTracking)
            RunLoop.current.add(close, forMode: .common)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        popup.mouseDown(with: down)
        guard let menu = opened, let index = menu.items.firstIndex(where: { $0.title == title }) else { return log("pop-up opened no menu with \(title)") }
        log("pop-up menu: \(menu.items.map(\.title).joined(separator: ", "))")
        menu.performActionForItem(at: index)
    }

    /// Clicks into the field, selects everything with ⌘↓ ⇧⌘↑ and types the text key by key.
    private static func replaceText(in view: NSView, with text: String) {
        guard let window = view.window else { return }
        press(view)
        // Without an active input context a background window's text view drops typed characters.
        (window.firstResponder as? NSTextView)?.inputContext?.activate()
        press(key: "cmd-down", in: window)
        press(key: "shift-cmd-up", in: window)
        for character in text.replacingOccurrences(of: "\\n", with: "\n") {
            press(key: character == "\n" ? "return" : String(character), in: window)
        }
    }

    /// Sends key down and up for a letter or a named key with modifiers, such as `opt-up` or `shift-cmd-up`, to the window's first responder.
    static func press(key spec: String, in window: NSWindow) {
        var parts = spec.count > 1 ? spec.split(separator: "-").map(String.init) : [spec]
        let key = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "opt": flags.insert(.option)
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let named: [String: (Int, UInt16)] = ["up": (NSUpArrowFunctionKey, 126), "down": (NSDownArrowFunctionKey, 125), "return": (13, 36), "delete": (127, 51), "tab": (9, 48)]
        let characters: String
        let keyCode: UInt16
        if let (scalar, code) = named[key], let unicode = UnicodeScalar(scalar) {
            characters = String(Character(unicode))
            keyCode = code
            if code == 126 || code == 125 { flags.formUnion([.function, .numericPad]) }
        } else {
            characters = key
            keyCode = 0
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(event)
        }
    }

    private static func renderWindow(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        window.appearance = NSApp.appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        // Glass and vibrant text blend with what lies behind them, so a window background goes underneath.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.displayIgnoringOpacity(view.bounds, in: context)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("window written to \(path)")
    }

    private static func split(_ text: String, at separator: Character) -> (String, String) {
        guard let index = text.firstIndex(of: separator) else { return (text, "") }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
