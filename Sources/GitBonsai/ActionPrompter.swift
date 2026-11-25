import AppKit
import GitEngine

/// How a repository tab asks and tells the user: forms, confirmations, save locations, reports of failed git commands, toasts and the way to the conflicts.
/// One implementation per tab, shared by all its controllers.
@MainActor
protocol Prompting: AnyObject, Sendable {
    /// The tab's window while it is shown, as parent of a sheet that the tab itself runs.
    var window: NSWindow? { get }
    func ask(_ form: ActionForm) async -> ActionForm.Values?
    /// True when the first button was chosen.
    func confirm(_ alert: NSAlert) async -> Bool
    /// Runs `perform` when the first button was chosen of an alert whose destructive first button is not the default, so Return cancels.
    func confirmDiscard(_ alert: NSAlert, then perform: @escaping () -> Void)
    func choose(_ alert: NSAlert) async -> NSApplication.ModalResponse
    func saveLocation(title: LocalizedStringResource, suggestedName: String) async -> URL?
    /// Says what went wrong, as a toast or a sheet; `report` fills in the defaults.
    func reportFailure(_ error: Error, title: LocalizedStringResource, summary: LocalizedStringResource?, actions: [FailureAction])
    func reportUnlessStopped(_ error: Error, title: LocalizedStringResource, actions: [FailureAction], in repository: Repository) async
    func reportConflictingReturn(of stash: String)
    func showSheet(title: LocalizedStringResource, summary: LocalizedStringResource, details: String?, actions: [FailureAction])
    func toast(_ text: RefString, action: ToastAction?)
    /// The toast action that shows the working directory with its conflicts.
    var showConflictsAction: ToastAction { get }
}

extension Prompting {
    func report(_ error: Error, title: LocalizedStringResource, summary: LocalizedStringResource? = nil, actions: [FailureAction] = []) {
        reportFailure(error, title: title, summary: summary, actions: actions)
    }

    func toast(_ text: RefString) {
        toast(text, action: nil)
    }
}

/// Asks on the tab's window; a question or report of a tab in the background waits for the user to come back to it instead of being dropped.
@MainActor
final class ActionPrompter: Prompting {
    private let lifecycle: TabLifecycle
    private let toastView: Toast
    private let pasteboard: Pasteboard
    /// Shows the working directory with its conflicts; the tab sets it once its parts exist.
    var onShowConflicts: (() -> Void)?

    init(lifecycle: TabLifecycle, toast: Toast, pasteboard: Pasteboard) {
        self.lifecycle = lifecycle
        toastView = toast
        self.pasteboard = pasteboard
    }

    var window: NSWindow? { lifecycle.window }

    /// The form's values, or nil when it was cancelled.
    func ask(_ form: ActionForm) async -> ActionForm.Values? {
        form.prepare()
        guard await present(form.alert) == .alertFirstButtonReturn else { return nil }
        return form.values
    }

    func confirm(_ alert: NSAlert) async -> Bool {
        await present(alert) == .alertFirstButtonReturn
    }

    func confirmDiscard(_ alert: NSAlert, then perform: @escaping () -> Void) {
        Task {
            if await present(alert) == .alertFirstButtonReturn { perform() }
        }
    }

    /// The button chosen in an alert with more than one way forward.
    func choose(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await present(alert)
    }

    func saveLocation(title: LocalizedStringResource, suggestedName: String) async -> URL? {
        guard let window = await presentingWindow() else { return nil }
        return await SheetSupport.chooseFile(title: title.text, name: suggestedName, on: window)
    }

    func toast(_ text: RefString, action: ToastAction?) {
        toastView.show(text, action: action)
    }

    var showConflictsAction: ToastAction {
        ToastAction(title: LocalizedStringResource("failure.toast.showConflicts", defaultValue: "Show conflicts", bundle: .module)) { [weak self] in self?.onShowConflicts?() }
    }

    /// Says what went wrong. A failure that changed nothing and needs no decision, such as an unreachable server, is a toast whose "Details" opens the sheet;
    /// anything else is a sheet with one sentence, the ways forward as buttons and git's output collapsed below. `summary` replaces the app's sentence for git's message.
    func reportFailure(_ error: Error, title: LocalizedStringResource, summary: LocalizedStringResource?, actions: [FailureAction]) {
        let title = RefString(title)
        let sentence = summary.map(RefString.init) ?? GitFailureText.summary(of: error)
        let details = GitFailureText.details(of: error).flatMap { $0 == sentence.plain ? nil : $0 }
        if actions.isEmpty, GitFailureText.isPassing(error) {
            let more = details.map { _ in ToastAction(title: LocalizedStringResource("failure.toast.details", defaultValue: "Details", bundle: .module)) { [weak self] in self?.showSheet(title: .verbatim(title), summary: .verbatim(sentence), details: details, actions: []) } }
            toast(RefString(LocalizedStringResource("failure.toast.summary", defaultValue: "\(title.marked): \(sentence.marked)", bundle: .module, comment: "Toast of a failure: what failed, then git's reason.")), action: more)
            return
        }
        showSheet(title: .verbatim(title), summary: .verbatim(sentence), details: details, actions: actions)
    }

    /// A rebase, cherry-pick, revert or merge that stopped on conflicts is a state, not an error: the banner and the conflict list show it, so only other failures are reported.
    /// A stash that applied with conflicts leaves no operation behind; the working directory shows the conflicts, and a toast leads there.
    func reportUnlessStopped(_ error: Error, title: LocalizedStringResource, actions: [FailureAction], in repository: Repository) async {
        if (error as? GitError)?.stoppedOnConflict == true {
            if await repository.operationInProgress() != nil { return }
            toast(RefString(title), action: showConflictsAction)
            return
        }
        report(error, title: title, actions: actions)
    }

    /// Changes set aside for a command conflicted when they came back: the working directory shows the conflicts, and the stash named `stash` stays.
    func reportConflictingReturn(of stash: String) {
        toast(RefString(LocalizedStringResource("failure.toast.stashConflict", defaultValue: "Local changes conflict on their way back; the stash “\(stash)” stays", bundle: .module)), action: showConflictsAction)
    }

    /// The sheet of a failure, also for a decision that a failure leads to, such as a rejected push. The chosen action runs once the sheet is gone.
    func showSheet(title: LocalizedStringResource, summary: LocalizedStringResource, details: String?, actions: [FailureAction]) {
        let title = RefString(title)
        let summary = RefString(summary)
        let sheet = FailureSheet(title: title, summary: summary, details: details, actions: actions, pasteboard: pasteboard)
        Task {
            guard let window = await presentingWindow() else { return }
            guard let index = await sheet.run(on: window) else { return }
            actions[index].run()
        }
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = await presentingWindow() else { return .cancel }
        return await alert.beginSheet(on: window)
    }

    private func presentingWindow() async -> NSWindow? {
        await lifecycle.windowWhenShown()
    }
}

extension NSAlert {
    /// The button Esc presses: Cancel, otherwise the last button, which is where an alert puts the choice that changes nothing.
    var cancelButton: NSButton? {
        buttons.first { $0.title == String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module) } ?? buttons.last
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
        return response
    }

    private static let escape = "\u{1b}"
}

