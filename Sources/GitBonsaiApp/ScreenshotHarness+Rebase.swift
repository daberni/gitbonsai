import AppKit
import GitEngine

/// Harness switches for the interactive rebase: the sheet driven by real clicks, drags and keys, the amend at an edit stop and the undo in the status line.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_REBASE_DETECTION_DELAY=<seconds>` holds back the rebase base detection of commit menus, as in a large repository.
    static var rebaseDetectionDelay: Double { environment["GITBONSAI_REBASE_DETECTION_DELAY"].flatMap(Double.init) ?? 0 }

    /// `GITBONSAI_REBASE_SCRIPT=<step>;<step>…` drives the sheet once it is open; open it with `GITBONSAI_MENU_RUN=<row>:Rebase <branch> interaktiv`.
    /// Steps: `drag:<row>><gap>` drags a row by its grip to the gap before row `gap`, `click:<row>`, `key:<key>` (a letter, `opt-up`, `opt-down`, `up`, `down`),
    /// `popup:<row>=<action>` picks from the row's pop-up, `subject:<row>=<text>` and `message:<text>` replace text by typing (`\n` for a new line),
    /// `toggle:update-refs|autostash`, `size:<width>x<height>` (the sheet's content size, kept within its limits), `base:<revision>` (the old base), `resize:<column>><points>` (drags a column edge over the rows), `print`, `shot:<png>`, `start`, `cancel`. Each step is a real event through the sheet's window.
    static func driveRebaseSheet(_ sheet: InteractiveRebaseSheet) {
        guard isActive, let script = environment["GITBONSAI_REBASE_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        after(0.5) { runRebaseSteps(steps[...], on: sheet) }
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
        case "resize":
            // `resize:<column>><points>` drags that column's right edge sideways over the rows with real events.
            let (name, delta) = split(argument, at: ">")
            guard let column = RebaseColumns.Column(rawValue: name), let delta = Double(delta), let edge = sheet.list.columns.dividers(in: sheet.list.scrollView.contentView.bounds.width).first(where: { $0.0 == column })?.1, table.numberOfRows > 0 else { break }
            let y = table.rect(ofRow: 0).midY
            // The edge has to be in view to be grabbed, as for a user who scrolls to it first.
            table.scrollToVisible(NSRect(x: edge - Theme.Space.xl, y: y, width: 2 * Theme.Space.xl, height: 1))
            drag(in: window, from: table.convert(NSPoint(x: edge, y: y), to: nil), to: table.convert(NSPoint(x: edge + delta, y: y), to: nil), steps: 6)
            let widths = RebaseColumns.Column.allCases.map { "\($0.rawValue) \(Int(sheet.list.columns.width(of: $0)))" }.joined(separator: ", ")
            log("rebase columns: \(widths), rows \(Int(table.bounds.width)) wide in \(Int(sheet.list.scrollView.contentView.bounds.width))")
        case "base":
            Task { await sheet.basePicker.type(argument) }
        case "toggle":
            guard let box = argument == "update-refs" ? sheet.updateRefsBox : sheet.autostashBox else { break }
            press(box)
        case "print":
            log("rebase rows, top first: " + sheet.model.steps.indices.map { sheet.model.plan.step(atRow: $0) }.map { "\(sheet.model.steps[$0].action.rawValue) \(sheet.model.steps[$0].commit?.shortID ?? "") \(sheet.model.subject(at: $0))" }.joined(separator: " | "))
            log("rebase preview: " + sheet.preview.textLines.joined(separator: " | "))
            log("rebase message: \(sheet.messageView.string.replacingOccurrences(of: "\n", with: "\\n")), start \(sheet.startButton.isEnabled ? "an" : "aus"), selected \(sheet.list.selectedIndex.map(String.init) ?? "-")")
        case "shot":
            renderWindow(window, to: argument)
        case "size":
            let (width, height) = split(argument, at: "x")
            guard let width = Double(width), let height = Double(height) else { break }
            // A user's resize stops at the sheet's limits; setting the size directly does not, so it is clamped here.
            let minimum = window.contentMinSize
            let maximum = window.contentMaxSize
            window.setContentSize(NSSize(width: min(max(width, minimum.width), maximum.width), height: min(max(height, minimum.height), maximum.height)))
            window.layoutIfNeeded()
            log("rebase sheet size \(window.frame.size)")
        case "start":
            press(sheet.startButton)
        case "cancel":
            press(sheet.cancelButton)
        default:
            log("unknown rebase step \(step)")
        }
        after(0.4) { runRebaseSteps(steps.dropFirst(), on: sheet) }
    }

    /// `GITBONSAI_PRINT_SELECTION=<seconds>,…` prints whether the toast shows, the selected history row, whether it is HEAD and whether a diff covers the history after each delay.
    /// `GITBONSAI_REBASE_MENU=<row>,<row>` prints the interactive rebase entries of those rows with the reason a disabled one gives.
    /// `GITBONSAI_EDIT_AMEND=<subject>` at an edit stop clicks "Amend Commit…" in the banner, types the subject into the commit form, clicks Amend and then Continue, all with real events.
    /// `GITBONSAI_REBASE_UNDO=1` clicks "Undo…" in the status line; the question is answered by `GITBONSAI_CONFIRM=1`.
    static func driveRebase(on tab: RepositoryViewController) {
        if let script = environment["GITBONSAI_REWORD_SCRIPT"] {
            let steps = script.split(separator: ";").map(String.init)
            after(0.5) { runRewordSteps(steps[...], on: tab) }
        }
        for row in (environment["GITBONSAI_REBASE_MENU"] ?? "").split(separator: ",").compactMap({ Int($0) }) where tab.viewModel.commits.indices.contains(row) {
            let items = tab.commitActions.interactiveRebase.menuItems(for: tab.viewModel.commits[row])
            log("rebase menu \(row): " + items.map { $0.action == nil ? "\($0.plainTitle) (aus: \($0.toolTip ?? ""))" : $0.plainTitle }.joined(separator: "; "))
        }
        if let subject = environment["GITBONSAI_EDIT_AMEND"] {
            after(0.6) { amendAtEditStop(on: tab, subject: subject) }
        }
        for delay in (environment["GITBONSAI_PRINT_SELECTION"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
            after(delay) {
                let row = tab.history.tableView.selectedRow
                let selected = tab.viewModel.commits.indices.contains(row) ? tab.viewModel.commits[row].id : "-"
                log("toast \(tab.toast.view.isHidden ? "hidden" : "shown"), selection: row \(row), HEAD \(selected == tab.viewModel.headSHA ? "selected" : "not selected"), history \(tab.history.view.window == nil ? "hidden behind a diff" : "shown"), status: \(tab.viewModel.statusText)")
            }
        }
        if environment["GITBONSAI_REBASE_UNDO"] == "1" {
            after(0.8) {
                let button = tab.undo.button
                log("undo \(button.isHidden ? "hidden" : "shown: \(button.toolTip ?? "")")")
                guard !button.isHidden else { return }
                press(button)
                after(1.5) { log("status: \(tab.viewModel.statusText); undo \(button.isHidden ? "hidden" : "shown")") }
            }
        }
    }

    /// `GITBONSAI_REWORD_SCRIPT=<step>;<step>…` edits a commit message in place in the detail panel. Steps: `select:<row>` (selects the history row), `menu` (runs "Edit Message" from the selected row's commit menu),
    /// `dblclick` (a real double click on the subject), `pencil` (a real click on the pencil), `cmd-e` (⌘E through the main menu: its validation, then its action),
    /// `subject:<text>` and `body:<text>` (typed, `\n` for a new line), `key:<key>` (`escape`, `cmd-return`, `return`, a letter), `save`, `cancel` (real clicks), `print`, `shot:<png>`, `wait:<seconds>`.
    private static func runRewordSteps(_ steps: ArraySlice<String>, on tab: RepositoryViewController) {
        guard let step = steps.first, let window = tab.view.window else { return }
        log("reword step \(step)")
        let (name, argument) = split(step, at: ":")
        let detail = views(of: DetailView.self, in: window).first
        let editor = detail?.messageEditor
        var delay = 0.5
        switch name {
        case "select":
            // Row clicks need a key window (see the navigation switches); selecting is not what this script checks.
            guard let row = Int(argument), row < tab.history.tableView.numberOfRows else { break }
            tab.history.select(row: row, scroll: true)
        case "menu":
            let row = tab.history.tableView.selectedRow
            guard let items = tab.history.menuItems?(row) else { break }
            let menu = NSMenu()
            items.forEach(menu.addItem)
            let editMessage = String(localized: "commit.action.editMessage", defaultValue: "Edit Message", bundle: .module)
            if let item = items.first(where: { $0.title.hasPrefix(editMessage) }), item.action == nil {
                log("menu entry „\(item.title)“ disabled: \(item.toolTip ?? "")")
                break
            }
            choose(editMessage, in: menu)
        case "dblclick":
            guard let label = detail?.subjectLabel else { log("no subject label"); break }
            let point = label.convert(NSPoint(x: Theme.Space.s, y: label.bounds.midY), to: nil)
            // The selectable subject tracks the mouse until its release, so each release waits in the queue before the press.
            for count in 1...2 {
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
                }
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                // The second press goes through the event queue like a real one, where the subject catches it before the field editor of the first.
                guard let down = event(.leftMouseDown) else { continue }
                if count == 1 { Self.press(down, in: window) } else { NSApp.postEvent(down, atStart: true) }
            }
        case "pencil":
            guard let button = detail?.editMessageButton else { log("no pencil"); break }
            log("pencil \(button.isEnabled ? "enabled" : "disabled"): \(button.toolTip ?? "")")
            press(button)
        case "cmd-e":
            let shortcut = CommandShortcut.editMessage
            guard let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first(where: { $0.keyEquivalent == shortcut.key && $0.keyEquivalentModifierMask == shortcut.modifiers }), let action = item.action else { log("no ⌘E in the main menu"); break }
            let enabled = (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
            let reason = tab.allCommands().first { $0.id == CommandSpec.editMessage.id }?.disabledReason
            log("⌘E „\(item.title)“ \(enabled ? "enabled" : "disabled: \(reason ?? "")")")
            if enabled { NSApp.sendAction(action, to: item.target, from: item) } else { NSSound.beep() }
        case "subject":
            guard let editor else { log("no editor"); break }
            replaceText(in: editor.subject.field, with: argument)
        case "body":
            guard let editor else { log("no editor"); break }
            replaceText(in: editor.body, with: argument)
        case "key" where argument == "cmd-return":
            // NSApplication offers key equivalents to the key window before its first responder sees the key; a background window is never key, so the harness offers it the same way.
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: KeyCode.return) else { break }
            traceSaving(on: tab, in: window)
            log("⌘⏎ taken as key equivalent: \(window.performKeyEquivalent(with: event))")
            delay = 2
        case "key":
            press(key: argument, in: window)
        case "save":
            guard let editor else { log("no editor"); break }
            traceSaving(on: tab, in: window)
            press(editor.saveButton)
            delay = 2
        case "cancel":
            guard let editor else { log("no editor"); break }
            press(editor.cancelButton)
        case "wait":
            delay = Double(argument) ?? 1
        case "print":
            printReword(on: tab, editor: editor, detail: detail)
        case "shot":
            renderWindow(window, to: argument)
        default:
            log("unknown reword step \(step)")
        }
        after(delay) { runRewordSteps(steps.dropFirst(), on: tab) }
    }

    /// For two seconds after saving, prints every state of selection and detail panel that can reach the screen, each time the run loop goes to sleep and only when it changed, to show that nothing else flashes up in between.
    private static func traceSaving(on tab: RepositoryViewController, in window: NSWindow) {
        nonisolated(unsafe) var last = ""
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated {
                let model = tab.viewModel
                let row = tab.history.tableView.selectedRow
                let selected = model.commits.indices.contains(row) ? "\(model.commits[row].shortID) \(model.commits[row].subject)" : "row \(row)"
                let detail = views(of: DetailView.self, in: window).first
                let panel = detail?.messageEditor != nil ? "editor (saving \(detail?.messageEditor?.isSaving == true))" : "\(detail?.shownShortSHA ?? "-") \(detail?.subjectLabel?.stringValue ?? "-")"
                let state = "selected \(selected) · panel \(panel)"
                guard state != last else { return }
                last = state
                log("saving trace: \(state)")
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        after(2) { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    /// The first rows of the history, the selection, the panel's header and the editor's state.
    private static func printReword(on tab: RepositoryViewController, editor: CommitMessageEditor?, detail: DetailView?) {
        let model = tab.viewModel
        let rows = model.commits.indices.prefix(6).filter { model.kinds[$0] != .wip }.map { "\(model.commits[$0].shortID) \(model.commits[$0].subject)\(model.commits[$0].id == model.headSHA ? " (HEAD)" : "")" }
        log("log: " + rows.joined(separator: " | "))
        let row = tab.history.tableView.selectedRow
        let selected = model.commits.indices.contains(row) ? "\(model.commits[row].shortID) \(model.commits[row].subject)" : "row \(row)"
        log("selected: \(selected); panel: \(detail?.shownShortSHA ?? "-") \(detail?.subjectLabel?.stringValue ?? "-"); pencil \(detail?.editMessageButton.map { $0.isHidden ? "hidden" : $0.isEnabled ? "enabled" : "disabled" } ?? "none")")
        if let editor {
            log("editor: subject „\(editor.subject.stringValue)“, body „\(editor.body.string.replacingOccurrences(of: "\n", with: "\\n"))“, note „\(editor.noteText)“, Sichern \(editor.saveButton.isEnabled ? "an" : "aus"), focus \(editor.window?.firstResponder.map { "\(type(of: $0))" } ?? "none")")
        } else {
            log("editor: closed")
        }
        log("status: \(model.statusText); undo \(tab.undo.button.isHidden ? "hidden" : "shown")")
    }

    private static func amendAtEditStop(on tab: RepositoryViewController, subject: String) {
        let banner = tab.operationBanner.view
        log("banner: \(banner.isHidden ? "hidden" : banner.text), amend \(banner.amendButton.isHidden ? "hidden" : "shown")")
        guard !banner.amendButton.isHidden else { return }
        press(banner.amendButton)
        after(0.8) {
            let form = tab.commitController.form
            guard let window = form.window, let field = views(of: PlainTextField.self, in: window).first(where: { $0.isDescendant(of: form) }), let button = views(of: PrimaryButton.self, in: window).first(where: { $0.isDescendant(of: form) }) else {
                return log("commit form not shown")
            }
            log("commit form: amend \(form.isAmend), subject \(form.subjectText)")
            replaceText(in: field, with: subject)
            after(0.4) {
                log("amend button \(button.title) enabled \(button.isEnabled)")
                press(button)
                after(1.5) {
                    log("banner after amend: \(banner.isHidden ? "hidden" : banner.text)")
                    press(banner.continueButton)
                    after(1.5) {
                        log("banner after continue: \(banner.isHidden ? "hidden" : banner.text)")
                        log("status: \(tab.viewModel.statusText); undo \(tab.undo.button.isHidden ? "hidden" : "shown")")
                    }
                }
            }
        }
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
    /// `title` is a todo verb such as `squash`; the pop-up shows its localized label.
    private static func pick(_ action: String, from popup: NSPopUpButton) {
        let title = RebaseAction(rawValue: action).map(RebaseStepRowView.label) ?? action
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
        let named: [String: (Int, UInt16)] = ["up": (NSUpArrowFunctionKey, 126), "down": (NSDownArrowFunctionKey, 125), "return": (13, 36), "delete": (127, 51), "tab": (9, 48), "escape": (27, 53)]
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

    static func renderWindow(_ window: NSWindow, to path: String) {
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
