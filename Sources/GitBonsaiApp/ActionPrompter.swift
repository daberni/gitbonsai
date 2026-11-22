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

    /// The button chosen in an alert with more than one way forward.
    func choose(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if ScreenshotHarness.keysSheets {
            ScreenshotHarness.pressKey(on: alert)
        } else if ScreenshotHarness.clicksSheets {
            ScreenshotHarness.clickSheet(alert)
        } else if ScreenshotHarness.isActive {
            return ScreenshotHarness.answerChoice(alert)
        }
        return await present(alert)
    }

    func saveLocation(title: LocalizedStringResource, suggestedName: String) async -> URL? {
        if ScreenshotHarness.isActive { return ScreenshotHarness.saveLocation }
        guard let window = window?() else { return nil }
        let panel = NSSavePanel()
        panel.title = title.text
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }

    /// Where failures that need no answer go, as a toast with an optional action; without it they get the sheet too.
    var onToast: ((RefString, ToastAction?) -> Void)?
    /// Shows the working directory with its conflicts, for the toast of a stash that applied with conflicts.
    var onShowConflicts: (() -> Void)?

    /// Says what went wrong. A failure that changed nothing and needs no decision, such as an unreachable server, is a toast whose "Details" opens the sheet;
    /// anything else is a sheet with one sentence, the ways forward as buttons and git's output collapsed below. `summary` replaces the app's sentence for git's message.
    func report(_ error: Error, title: LocalizedStringResource, summary: LocalizedStringResource? = nil, actions: [FailureAction] = []) {
        let title = RefString(title)
        let sentence = summary.map(RefString.init) ?? GitFailureText.summary(of: error)
        let details = GitFailureText.details(of: error).flatMap { $0 == sentence.plain ? nil : $0 }
        if actions.isEmpty, GitFailureText.isPassing(error), let onToast {
            let more = details.map { _ in ToastAction(title: "Details") { [weak self] in self?.showSheet(title: .verbatim(title), summary: .verbatim(sentence), details: details, actions: []) } }
            onToast(RefString(LocalizedStringResource("\(title.marked): \(sentence.marked)", comment: "Toast of a failure: what failed, then git's reason.")), more)
            return
        }
        showSheet(title: .verbatim(title), summary: .verbatim(sentence), details: details, actions: actions)
    }

    /// A rebase, cherry-pick, revert or merge that stopped on conflicts is a state, not an error: the banner and the conflict list show it, so only other failures are reported.
    /// A stash that applied with conflicts leaves no operation behind; the working directory shows the conflicts, and a toast leads there.
    func report(_ error: Error, title: LocalizedStringResource, actions: [FailureAction] = [], unlessStoppedIn repository: Repository) async {
        if (error as? GitError)?.stoppedOnConflict == true {
            if await repository.operationInProgress() != nil { return }
            if let onToast {
                onToast(RefString(title), onShowConflicts.map { show in ToastAction(title: "Show Conflicts") { show() } })
                return
            }
        }
        report(error, title: title, actions: actions)
    }

    /// Changes set aside for a command conflicted when they came back: the working directory shows the conflicts, and the stash named `stash` stays.
    func reportConflictingReturn(of stash: String) {
        onToast?(RefString("Local changes conflict on their way back; the stash “\(stash)” stays"), onShowConflicts.map { show in ToastAction(title: "Show Conflicts") { show() } })
    }

    /// The sheet of a failure, also for a decision that a failure leads to, such as a rejected push. The chosen action runs once the sheet is gone.
    func showSheet(title: LocalizedStringResource, summary: LocalizedStringResource, details: String?, actions: [FailureAction]) {
        let title = RefString(title)
        let summary = RefString(summary)
        let sheet = FailureSheet(title: title, summary: summary, details: details, actions: actions)
        if ScreenshotHarness.isActive {
            FileHandle.standardError.write(Data("\(title.plain): \(summary.plain)\(details.map { " [Details: \($0.replacingOccurrences(of: "\n", with: " ⏎ "))]" } ?? "")\(actions.isEmpty ? "" : " {\(actions.map(\.title).joined(separator: " | "))}")\n".utf8))
            guard ScreenshotHarness.clicksReports else { return ScreenshotHarness.renderReport(sheet) }
        }
        guard let window = window?() else { return }
        if ScreenshotHarness.clicksReports { ScreenshotHarness.clickReport(sheet) }
        Task {
            guard let index = await sheet.run(on: window) else { return }
            actions[index].run()
        }
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window?() else { return .cancel }
        return await alert.beginSheet(on: window)
    }
}

extension NSAlert {
    /// The button Esc presses: Cancel, otherwise the last button, which is where an alert puts the choice that changes nothing.
    var cancelButton: NSButton? {
        buttons.first { $0.title == String(localized: "Cancel", bundle: .module) } ?? buttons.last
    }

    /// Shows the alert as a sheet on which Esc presses `cancelButton`, as macOS dialogs do.
    /// NSAlert gives Esc only to a button titled "Cancel". A key equivalent is one key per button, so a cancel button that already holds ⏎, as in destructive confirmations and one-button reports, gets Esc from a key monitor for as long as the sheet is up.
    func beginSheet(on window: NSWindow) async -> NSApplication.ModalResponse {
        // An alert without buttons gets its "OK" only when it is shown; added here, it takes part in the Esc handling.
        if buttons.isEmpty { addButton(withTitle: "OK") }
        applyRefText()
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
