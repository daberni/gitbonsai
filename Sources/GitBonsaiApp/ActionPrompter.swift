import AppKit
import GitEngine

/// Asks the user on the tab's window: forms, confirmations, save locations, and reports of failed git commands.
/// Under the screenshot harness the answers come from `ScreenshotHarness` instead, so no sheet waits for a click.
@MainActor
final class ActionPrompter {
    var window: (() -> NSWindow?)?

    /// The form's values, or nil when it was cancelled.
    func ask(_ form: ActionForm) async -> ActionForm.Values? {
        form.prepare()
        if ScreenshotHarness.keysSheets { ScreenshotHarness.pressKey(on: form) } else if ScreenshotHarness.isActive { return ScreenshotHarness.answer(form) }
        guard await present(form.alert) == .alertFirstButtonReturn else { return nil }
        return form.values
    }

    /// True when the first button was chosen.
    func confirm(_ alert: NSAlert) async -> Bool {
        if ScreenshotHarness.keysSheets {
            ScreenshotHarness.pressKey(on: alert)
        } else if ScreenshotHarness.clicksSheets {
            ScreenshotHarness.clickSheet(alert)
        } else if ScreenshotHarness.isActive {
            return ScreenshotHarness.answer(alert)
        }
        return await present(alert) == .alertFirstButtonReturn
    }

    func saveLocation(title: String, suggestedName: String) async -> URL? {
        if ScreenshotHarness.isActive { return ScreenshotHarness.saveLocation }
        guard let window = window?() else { return nil }
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }

    /// Says in one sentence what went wrong; git's own output sits behind "Details". A conflict is not undone: the repository stays in the state git left it in.
    func report(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = GitFailureText.summary(of: error)
        let details = GitFailureText.details(of: error)
        if let details, details != alert.informativeText {
            let view = FailureDetailsView(details: details)
            view.frame.size = view.fittingSize
            view.onToggle = { [weak alert] in alert?.layout() }
            alert.accessoryView = view
        }
        if ScreenshotHarness.isActive {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\(details.map { " [Details: \($0.replacingOccurrences(of: "\n", with: " ⏎ "))]" } ?? "")\n".utf8))
            ScreenshotHarness.renderReport(alert)
            return
        }
        Task { _ = await present(alert) }
    }

    /// A rebase, cherry-pick, revert or merge that stopped on conflicts is a state, not an error: the banner and the conflict list show it, so only other failures are reported.
    func report(_ error: Error, title: String, unlessStoppedIn repository: Repository) async {
        if (error as? GitError)?.stoppedOnConflict == true, await repository.operationInProgress() != nil { return }
        report(error, title: title)
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window?() else { return .cancel }
        return await alert.beginSheet(on: window)
    }
}

extension NSAlert {
    /// The button Esc presses: "Abbrechen", otherwise the last button, which is where an alert puts the choice that changes nothing.
    var cancelButton: NSButton? {
        buttons.first { $0.title == "Abbrechen" } ?? buttons.last
    }

    /// Shows the alert as a sheet on which Esc presses `cancelButton`, as macOS dialogs do.
    /// NSAlert gives Esc only to a button titled "Cancel". A key equivalent is one key per button, so a cancel button that already holds ⏎, as in destructive confirmations and one-button reports, gets Esc from a key monitor for as long as the sheet is up.
    func beginSheet(on window: NSWindow) async -> NSApplication.ModalResponse {
        // An alert without buttons gets its "OK" only when it is shown; added here, it takes part in the Esc handling.
        if buttons.isEmpty { addButton(withTitle: "OK") }
        var monitor: Any?
        if let cancel = cancelButton, !buttons.contains(where: { $0.keyEquivalent == Self.escape }) {
            if cancel.keyEquivalent.isEmpty {
                cancel.keyEquivalent = Self.escape
            } else {
                let sheet = self.window
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window === sheet, event.charactersIgnoringModifiers == Self.escape, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
                    cancel.performClick(nil)
                    return nil
                }
            }
        }
        let response = await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        ScreenshotHarness.sheetEnded(self, with: response)
        return response
    }

    private static let escape = "\u{1b}"
}
