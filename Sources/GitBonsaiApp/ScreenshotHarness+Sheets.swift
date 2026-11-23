import AppKit

/// Harness switches for the keyboard on sheets: Esc and Return pressed on a real sheet.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SHEET_KEY=escape|return` shows forms and confirmations as real sheets and presses that key on them once they are up; `GITBONSAI_FORM` fills a form first and `GITBONSAI_SHEET_FOCUS=message` puts the focus into its multi-line message.
    /// Needs `GITBONSAI_FOREGROUND=1`: AppKit gives Return to the default button only in the key window, and pressing the key activates the app. A background run ignores the switch and answers as without it.
    static var keysSheets: Bool {
        guard isActive, sheetKey != nil else { return false }
        if runsInBackground, !didWarnAboutSheetKey {
            didWarnAboutSheetKey = true
            sheetLog("GITBONSAI_SHEET_KEY needs GITBONSAI_FOREGROUND=1; ignored in this background run")
        }
        return !runsInBackground
    }

    private static var didWarnAboutSheetKey = false

    private static var sheetKey: (name: String, characters: String, keyCode: UInt16)? {
        switch environment["GITBONSAI_SHEET_KEY"] {
        case "escape": ("escape", "\u{1b}", 53)
        case "return": ("return", "\r", 36)
        default: nil
        }
    }

    static func pressKey(on form: ActionForm) {
        var answers: [String: String] = [:]
        for pair in (environment["GITBONSAI_FORM"] ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { answers[parts[0]] = parts[1] }
        }
        form.fill(answers)
        pressKey(on: form.alert)
    }

    /// Posts key down and up to the event queue once the sheet is up, so they take the path of a key typed on the keyboard; prints what had focus and how the sheet ended.
    static func pressKey(on alert: NSAlert) {
        guard let key = sheetKey else { return }
        let sheet = alert.window
        after(1.0) {
            // A foreground run launched from a shell is not always activated; a sheet that is not key loses its default button's Return.
            NSApp.activate()
            sheet.makeKey()
            if environment["GITBONSAI_SHEET_FOCUS"] == "message", let message = views(of: NSTextView.self, in: sheet).first(where: { $0.isEditable && !$0.isFieldEditor }) { sheet.makeFirstResponder(message) }
            let responder = sheet.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            let keys = alert.buttons.map { button in "\(button.title) \(["\r": "⏎", "\u{1b}": "esc"][button.keyEquivalent] ?? "-")" }
            sheetLog("sheet \(alert.messageText): \(key.name) pressed, sheet is key \(sheet.isKeyWindow), focus \(responder), buttons \(keys)")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            after(0.5) {
                let fields = views(of: NSTextField.self, in: sheet).filter(\.isEditable).map(\.stringValue)
                let texts = views(of: NSTextView.self, in: sheet).filter { $0.isEditable && !$0.isFieldEditor }.map { $0.string.replacingOccurrences(of: "\n", with: "\\n") }
                sheetLog("sheet \(alert.messageText): \(sheet.sheetParent == nil ? "closed" : "still open"), fields \(fields), texts \(texts)")
            }
        }
    }

    /// Prints which button ended a sheet that a harness key was pressed on.
    static func sheetEnded(_ alert: NSAlert, with response: NSApplication.ModalResponse) {
        guard keysSheets else { return }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        sheetLog("sheet \(alert.messageText): answered \(alert.buttons.indices.contains(index) ? "„\(alert.buttons[index].title)“" : "response \(response.rawValue)")")
    }

    private static func sheetLog(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: Failure sheets

    /// `GITBONSAI_REPORT_CLICK=<button>` shows failure sheets as real sheets and clicks that button with real events once they are up; `GITBONSAI_REPORT_DETAILS=1` first opens "Git Output" with a click.
    static var clicksReports: Bool { isActive && environment["GITBONSAI_REPORT_CLICK"] != nil }

    /// Without `GITBONSAI_REPORT_CLICK` a failure sheet is not shown; `GITBONSAI_REPORT_SHOT=<png>` renders it with its details open.
    static func renderReport(_ sheet: FailureSheet) {
        guard let path = environment["GITBONSAI_REPORT_SHOT"] else { return }
        sheet.details?.isExpanded = true
        sheet.fitToContent()
        renderWindow(sheet.window, to: path)
    }

    /// Prints the sheet's buttons and what the details look like, renders it to `GITBONSAI_REPORT_SHOT` and clicks the named button.
    static func clickReport(_ sheet: FailureSheet) {
        let window = sheet.window
        after(0.8) {
            sheetLog("failure sheet up: \(sheet.title), attached \(window.sheetParent != nil), buttons \(sheet.buttons.map(buttonTitle))")
            if environment["GITBONSAI_REPORT_DETAILS"] == "1", let details = sheet.details { clickCentre(of: details.disclosure, in: window) }
            after(0.5) {
                if let details = sheet.details {
                    let box = details.output.enclosingScrollView.map { $0.convert($0.bounds, to: details) } ?? .zero
                    sheetLog("failure details: expanded \(details.isExpanded), output box \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height)) in \(Int(details.bounds.width)), selectable \(details.output.isSelectable), clip \(details.output.enclosingScrollView.map { NSStringFromRect($0.contentView.bounds) } ?? "-"), text \(NSStringFromRect(details.output.frame)) origin \(NSStringFromPoint(details.output.textContainerOrigin)) used \(details.output.layoutManager.flatMap { lm in details.output.textContainer.map { NSStringFromRect(lm.usedRect(for: $0)) } } ?? "-"), sheet \(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                if let path = environment["GITBONSAI_REPORT_SHOT"] { renderWindow(window, to: path) }
                guard let title = environment["GITBONSAI_REPORT_CLICK"], let button = sheet.buttons.first(where: { buttonTitle($0) == title }) else {
                    return sheetLog("failure sheet: no button \(environment["GITBONSAI_REPORT_CLICK"] ?? "")")
                }
                clickCentre(of: button, in: window)
                after(0.3) { sheetLog("failure sheet after \(title): \(window.sheetParent == nil ? "closed" : "still open")") }
            }
        }
    }

    private static func buttonTitle(_ control: NSControl) -> String {
        (control as? PrimaryButton)?.title ?? (control as? SecondaryButton)?.title ?? ""
    }

    private static func clickCentre(of view: NSView, in window: NSWindow) {
        click(in: window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }
}
