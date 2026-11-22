import AppKit
import GitEngine

/// Harness switches for "Repository klonen".
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_CLONE=1` opens the clone sheet once the window is up; `GITBONSAI_CLONE_CLICK=1` opens it with a real click on the empty tab's "Klonen …" instead.
    static var wantsClone: Bool { environment["GITBONSAI_CLONE"] != nil && environment["GITBONSAI_CLONE_CLICK"] == nil }

    /// Harness runs read a pasteboard of their own, which `GITBONSAI_CLONE_PASTE=<text>` fills, so they never read or change the user's.
    static var clonePasteboard: NSPasteboard {
        guard isActive else { return .general }
        let board = NSPasteboard(name: NSPasteboard.Name("app.gitbonsai.harness"))
        if let text = environment["GITBONSAI_CLONE_PASTE"], board.string(forType: .string) != text {
            board.clearContents()
            board.setString(text, forType: .string)
        }
        return board
    }

    static func clickCloneIfAsked(on welcome: WelcomeView) {
        guard isActive, environment["GITBONSAI_CLONE_CLICK"] != nil else { return }
        welcome.layoutSubtreeIfNeeded()
        pressButton(welcome.cloneButton)
    }

    /// The window is captured once the sheet is closed, so the capture shows the cloned repository's tab.
    static func holdsCapture(for cloner: CloneController) -> Bool {
        isActive && cloner.isShowing
    }

    static func traceClone(_ line: String) {
        guard isActive else { return }
        FileHandle.standardError.write(Data("clone: \(line)\n".utf8))
    }

    /// `GITBONSAI_CLONE_FORM=url=…;path=…;branch=…;submodules=1;shallow=1` fills the sheet, `GITBONSAI_CLONE_SHOT=<png>` renders it filled,
    /// `GITBONSAI_CLONE_RUN=1` clicks "Klonen" with a real click, `GITBONSAI_CLONE_SHOT_DURING=<png>` renders it once receiving passes a third,
    /// and `GITBONSAI_CLONE_CANCEL_AT=<fraction>` clicks "Abbrechen" once the progress passes that fraction. Without RUN the sheet is cancelled after the shot.
    static func driveClone(_ cloner: CloneController) {
        guard isActive, let sheet = cloner.sheet else { return }
        if let pasted = clonePasteboard.string(forType: .string) { traceClone("pasteboard \"\(pasted)\", URL field \"\(sheet.urlField.stringValue)\"") }
        if let form = environment["GITBONSAI_CLONE_FORM"] {
            var answers: [String: String] = [:]
            for pair in form.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { answers[parts[0]] = parts[1] }
            }
            cloner.fill(answers)
        }
        traceClone("destination \"\(sheet.destinationField.stringValue)\", warning \"\(sheet.warning.isHidden ? "" : sheet.warning.stringValue)\", Klonen \(sheet.cloneButton.isEnabled ? "enabled" : "disabled")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let path = environment["GITBONSAI_CLONE_SHOT"] { render(sheet.window, to: path) }
            guard environment["GITBONSAI_CLONE_RUN"] != nil else {
                pressButton(sheet.cancelButton)
                return
            }
            pressButton(sheet.cloneButton)
            watchProgress(of: sheet)
        }
    }

    /// Looks at the sheet every few milliseconds until it closes: renders it during the progress, cancels when asked, and renders and cancels a failure so the run ends.
    private static func watchProgress(of sheet: CloneSheet, shotTaken: Bool = false, cancelled: Bool = false) {
        guard sheet.window.sheetParent != nil else { return }
        var shotTaken = shotTaken
        var cancelled = cancelled
        let fraction = sheet.progressBar.fraction
        if !shotTaken, fraction > 0.33, sheet.progressLabel.stringValue.hasPrefix(String(localized: "clone.progress.receiving", defaultValue: "Receiving objects", bundle: .module)), let path = environment["GITBONSAI_CLONE_SHOT_DURING"] {
            shotTaken = true
            traceClone("progress \(sheet.progressLabel.stringValue)")
            render(sheet.window, to: path)
        }
        if !cancelled, let cancelAt = environment["GITBONSAI_CLONE_CANCEL_AT"].flatMap(Double.init), fraction > cancelAt {
            cancelled = true
            traceClone("progress \(sheet.progressLabel.stringValue)")
            pressButton(sheet.cancelButton)
        }
        if !sheet.failure.isHidden {
            (sheet.failure.arrangedSubviews.last as? FailureDetailsView)?.isExpanded = true
            if let path = environment["GITBONSAI_CLONE_SHOT"] { render(sheet.window, to: path) }
            pressButton(sheet.cancelButton)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { watchProgress(of: sheet, shotTaken: shotTaken, cancelled: cancelled) }
        }
    }

    /// A real click in the middle of the button, delivered the way a key window would.
    private static func pressButton(_ button: NSButton) {
        guard let window = button.window else { return }
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard let down = mouseEvent(.leftMouseDown, at: point, in: window), let up = mouseEvent(.leftMouseUp, at: point, in: window) else { return }
        NSApp.postEvent(up, atStart: false)
        traceClone("click \(button.title)")
        if let view = window.contentView?.superview?.hitTest(point) { view.mouseDown(with: down) } else { window.sendEvent(down) }
    }

    private static func render(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        window.appearance = NSApp.appearance
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        // The sheet's glass blends with what lies behind it, so a window background goes underneath.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
