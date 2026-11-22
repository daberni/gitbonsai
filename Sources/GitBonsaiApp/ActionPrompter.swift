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
        if ScreenshotHarness.isActive { return ScreenshotHarness.answer(form) }
        guard await present(form.alert) == .alertFirstButtonReturn else { return nil }
        return form.values
    }

    /// True when the first button was chosen.
    func confirm(_ alert: NSAlert) async -> Bool {
        if ScreenshotHarness.isActive { return ScreenshotHarness.answer(alert) }
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

    /// Shows git's own message. A conflict is not undone: the repository stays in the state git left it in.
    func report(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let message = (error as? GitError)?.stderr ?? error.localizedDescription
        // Progress lines overwrite themselves with carriage returns; only what stays visible in a terminal is shown.
        let visible = message.split(separator: "\n", omittingEmptySubsequences: false).map { $0.split(separator: "\r").last.map(String.init) ?? "" }
        alert.informativeText = visible.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if ScreenshotHarness.isActive {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        Task { _ = await present(alert) }
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window?() else { return .cancel }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
