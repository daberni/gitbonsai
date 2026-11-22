import AppKit
import GitEngine

/// Runs the commit form: what the button may do, amend with the last message, the commit itself and what follows it.
@MainActor
final class CommitController {
    let form = CommitFormView()
    var window: (() -> NSWindow?)?

    private let viewModel: GraphViewModel
    private var stagedCount = 0
    private var signing: String?
    /// The text typed before amend was switched on, put back when it is switched off again.
    private var draft: (subject: String, body: String)?
    private var amendedMessage = ""
    private var isCommitting = false

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        form.onEdit = { [weak self] in self?.updateButton() }
        form.onAmendChanged = { [weak self] on in self?.amendChanged(on) }
        form.onCommit = { [weak self] in self?.commit() }
        Task { [weak self] in
            guard let self else { return }
            signing = await viewModel.repository.signingFormat()
            updateButton()
        }
    }

    func update(status: RepositoryStatus?) {
        stagedCount = status?.staged.count ?? 0
        updateButton()
    }

    private var message: String {
        let subject = form.subjectText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = form.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
    }

    /// Commit needs a subject and something staged; amend needs a subject and either staged changes or a changed message.
    private func updateButton() {
        let hasSubject = !form.subjectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canCommit: Bool = if form.isAmend {
            hasSubject && (stagedCount > 0 || message != amendedMessage)
        } else {
            hasSubject && stagedCount > 0
        }
        form.show(signing: signing, canCommit: canCommit && !isCommitting, buttonTitle: form.isAmend ? LocalizedStringResource("Amend", comment: "Button that amends the last commit.") : LocalizedStringResource("Commit", comment: "Button that commits."))
    }

    /// Ticks amend and loads the last message, for an edit stop of an interactive rebase.
    func beginAmend() {
        guard !form.isAmend else { return }
        form.isAmend = true
        amendChanged(true)
    }

    private func amendChanged(_ on: Bool) {
        if on {
            draft = (form.subjectText, form.bodyText)
            Task { [weak self] in
                guard let self else { return }
                let last = await viewModel.repository.lastCommitMessage() ?? ""
                amendedMessage = last
                let parts = last.components(separatedBy: "\n")
                form.subjectText = parts.first ?? ""
                form.bodyText = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                updateButton()
            }
        } else {
            form.subjectText = draft?.subject ?? ""
            form.bodyText = draft?.body ?? ""
            draft = nil
            updateButton()
        }
    }

    private func commit() {
        guard form.isAmend else { run(amend: false); return }
        Task { [weak self] in
            guard let self else { return }
            guard await viewModel.repository.headIsPushed() else { run(amend: true); return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Requires a force push", bundle: .module)
            alert.informativeText = String(localized: "The last commit is already in the upstream. After the amend, the local and the remote branch differ, and a push only works with force.", bundle: .module)
            alert.addButton(withTitle: String(localized: "Amend anyway", bundle: .module))
            alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
            present(alert) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.run(amend: true) }
            }
        }
    }

    private func run(amend: Bool) {
        let message = message
        let repository = viewModel.repository
        isCommitting = true
        updateButton()
        Task { [weak self] in
            do {
                try await repository.commit(message: message, amend: amend)
                self?.clear()
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = amend ? String(localized: "Amend failed", bundle: .module) : String(localized: "Commit failed", bundle: .module)
                alert.informativeText = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(error)"
                self?.present(alert) { _ in }
            }
            self?.isCommitting = false
            await self?.viewModel.refresh(note: nil)
            self?.updateButton()
        }
    }

    private func clear() {
        form.subjectText = ""
        form.bodyText = ""
        form.isAmend = false
        draft = nil
        amendedMessage = ""
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard ScreenshotHarness.outputPath == nil, let window = window?() else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.beginSheetModal(for: window) { response in completion(response) }
    }
}
