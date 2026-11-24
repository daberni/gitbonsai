import AppKit
import GitEngine

/// Runs the commit form: what the button may do, amend with the last message, the template, co-authors and sign-off, the commit itself and what follows it.
@MainActor
final class CommitController {
    let form = CommitFormView()

    private let viewModel: GraphViewModel
    private var stagedCount = 0
    /// Staged, unstaged and untracked files, for commit all.
    private var changeCount = 0
    private var conflictCount = 0
    private var signing: String?
    /// The text typed before amend was switched on, put back when it is switched off again.
    private var draft: (subject: String, body: String)?
    private var amendedMessage = ""
    /// From the first ⌘⏎ until the refresh after it, including the check whether HEAD is pushed and its alert, so a second press never commits twice.
    private var isCommitting = false
    /// Counts amend switches, so the last message that arrives after amend was switched off again, or on anew, is dropped.
    private var amendToggles = 0
    /// The body `commit.template` prefills into an empty form.
    private var template: String?
    private var coAuthors: [KnownAuthor] = []
    /// Loaded when the co-author menu first opens.
    private var knownAuthors: [KnownAuthor]?

    /// Gives the window that questions are shown on.
    private let prompter: any Prompting

    init(context: RepositoryContext) {
        viewModel = context.model
        prompter = context.prompter
        form.onEdit = { [weak self] in self?.updateButton() }
        form.onAmendChanged = { [weak self] on in self?.amendChanged(on) }
        form.onCommit = { [weak self] in self?.commit(amend: self?.form.isAmend ?? false) }
        form.onAmendCommit = { [weak self] in self?.commit(amend: true) }
        form.onCommitAll = { [weak self] in self?.commitAll() }
        form.onShiftChanged = { [weak self] in self?.updateButton() }
        form.onCoAuthorMenu = { [weak self] anchor in self?.showCoAuthorMenu(at: anchor) }
        Task { [weak self] in
            guard let self else { return }
            signing = await viewModel.repository.signingFormat()
            template = await viewModel.repository.commitTemplate()
            applyTemplate()
            updateButton()
        }
    }

    func update(status: RepositoryStatus?) {
        stagedCount = status?.staged.count ?? 0
        conflictCount = status?.conflicted.count ?? 0
        changeCount = stagedCount + (status?.unstaged.count ?? 0) + conflictCount
        updateButton()
    }

    private var message: String {
        let subject = form.subjectText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = form.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
    }

    private var trailers: [CommitTrailer] {
        coAuthors.map { CommitTrailer(key: CommitTrailer.coAuthorKey, value: $0.identity) }
    }

    /// Commit needs a subject and something staged; amend needs a subject and either staged changes or a changed message.
    private func canCommit(amend: Bool) -> Bool {
        guard !isCommitting, !form.subjectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return amend ? stagedCount > 0 || message != amendedMessage || !trailers.isEmpty || form.isSignOff : stagedCount > 0
    }

    /// Commit all needs a subject and any change, but no unresolved conflict: staging would mark it resolved.
    private var canCommitAll: Bool {
        guard !isCommitting, !form.subjectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return changeCount > 0 && conflictCount == 0
    }

    /// The template goes into the body only while the form is empty, so it never replaces what was typed.
    private func applyTemplate() {
        guard let template, !form.isAmend, form.subjectText.isEmpty, form.bodyText.isEmpty else { return }
        form.bodyText = template
    }

    private func updateButton() {
        if form.isAmend {
            form.show(signing: signing, canCommit: canCommit(amend: true), buttonTitle: LocalizedStringResource("commit.form.amend", defaultValue: "Amend", bundle: .module, comment: "Button that amends the last commit."))
        } else if form.isShiftHeld {
            form.show(signing: signing, canCommit: canCommitAll, buttonTitle: LocalizedStringResource("commit.form.commitAll", defaultValue: "Commit All", bundle: .module, comment: "The commit button while Shift is held: stages every change and commits."))
        } else {
            form.show(signing: signing, canCommit: canCommit(amend: false), buttonTitle: LocalizedStringResource("commit.form.commit", defaultValue: "Commit", bundle: .module, comment: "Button that commits."))
        }
    }

    /// Ticks amend and loads the last message, for an edit stop of an interactive rebase.
    func beginAmend() {
        guard !form.isAmend else { return }
        form.isAmend = true
        amendChanged(true)
    }

    private func amendChanged(_ on: Bool) {
        amendToggles += 1
        let toggle = amendToggles
        if on {
            draft = (form.subjectText, form.bodyText)
            Task { [weak self] in
                guard let self else { return }
                let last = await viewModel.repository.lastCommitMessage() ?? ""
                guard toggle == amendToggles else { return }
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

    private func commit(amend: Bool) {
        guard canCommit(amend: amend) else { return }
        guard amend else { run(amend: false); return }
        isCommitting = true
        updateButton()
        Task { [weak self] in
            guard let self else { return }
            guard await viewModel.repository.headIsPushed() else { run(amend: true); return }
            let alert = NSAlert()
            alert.messageText = String(localized: "commit.amendPushed.title", defaultValue: "Requires a force push", bundle: .module)
            alert.addButton(withTitle: String(localized: "commit.amendPushed.confirm", defaultValue: "Amend anyway", bundle: .module))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
            present(alert) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    run(amend: true)
                } else {
                    isCommitting = false
                    updateButton()
                }
            }
        }
    }

    private func commitAll() {
        guard canCommitAll else { return }
        run(amend: false, all: true)
    }

    private func run(amend: Bool, all: Bool = false) {
        let message = message
        let trailers = trailers
        let signOff = form.isSignOff
        let repository = viewModel.repository
        isCommitting = true
        updateButton()
        Task { [weak self] in
            do {
                if all {
                    try await repository.commitAll(message: message, trailers: trailers, signOff: signOff)
                } else {
                    try await repository.commit(message: message, amend: amend, trailers: trailers, signOff: signOff)
                }
                self?.clear()
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = amend ? String(localized: "failure.commit.amendFailed", defaultValue: "Amend failed", bundle: .module) : String(localized: "failure.commit.failed", defaultValue: "Commit failed", bundle: .module)
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
        coAuthors = []
        form.show(coAuthors: [])
        applyTemplate()
    }

    // MARK: Co-authors

    private func showCoAuthorMenu(at anchor: NSView) {
        Task { [weak self] in
            guard let self else { return }
            if knownAuthors == nil { knownAuthors = await viewModel.repository.knownAuthors() }
            let menu = NSMenu()
            for author in knownAuthors ?? [] {
                let item = NSMenuItem(title: author.name, action: #selector(CoAuthorTarget.toggle(_:)), keyEquivalent: "")
                item.target = coAuthorTarget
                item.representedObject = author.identity
                item.toolTip = author.email
                item.state = coAuthors.contains(author) ? .on : .off
                menu.addItem(item)
            }
            if menu.items.isEmpty {
                let none = NSMenuItem(title: String(localized: "commit.form.noAuthors", defaultValue: "No authors yet", bundle: .module), action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
        }
    }

    private lazy var coAuthorTarget = CoAuthorTarget { [weak self] identity in self?.toggleCoAuthor(identity) }

    private func toggleCoAuthor(_ identity: String) {
        guard let author = knownAuthors?.first(where: { $0.identity == identity }) else { return }
        if let index = coAuthors.firstIndex(of: author) { coAuthors.remove(at: index) } else { coAuthors.append(author) }
        form.show(coAuthors: coAuthors.map(\.name))
        updateButton()
    }

    /// Adds a co-author by identity, as the harness does instead of opening the menu.
    func addCoAuthor(name: String, email: String) {
        let author = KnownAuthor(name: name, email: email)
        knownAuthors = (knownAuthors ?? []) + [author]
        toggleCoAuthor(author.identity)
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        // harness: the harness reads and answers the alert through Accessibility; the app always shows it.
        guard ScreenshotHarness.outputPath == nil, let window = prompter.window else {
            ScreenshotHarness.render(alert)
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            // Without a sheet nobody confirms: the same as cancelling.
            completion(.cancel)
            return
        }
        alert.beginSheetModal(for: window) { response in completion(response) }
    }
}

/// The menu items' target: `NSMenuItem` needs an Objective-C object to call.
@MainActor
private final class CoAuthorTarget: NSObject {
    private let action: (String) -> Void

    init(action: @escaping (String) -> Void) {
        self.action = action
    }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String else { return }
        action(identity)
    }
}
