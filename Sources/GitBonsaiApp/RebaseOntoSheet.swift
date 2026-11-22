import AppKit
import GitEngine

/// Asks for the one open base of `git rebase --onto <new base> <old base> <branch>`: the new base when the old one is the clicked commit, or the old base when the clicked commit is the new one.
/// A branch, tag or commit is typed or picked; the sheet says how many commits move and keeps the confirm button disabled until the answer names a commit that moves something.
@MainActor
final class RebaseOntoSheet: NSObject, NSComboBoxDelegate {
    enum Choice {
        case newBase(oldBase: Commit, moving: Int)
        /// `place` names the new base in the text, such as „main“ or "diesen Commit".
        case oldBase(newBase: Commit, place: String)
    }

    /// An entry of the pick list; `title` may describe the commit `revision` names.
    struct Candidate {
        let title: String
        let revision: String
    }

    let alert = NSAlert()
    private let repository: Repository
    private let branch: String
    private let choice: Choice
    private let candidates: [Candidate]
    private let baseField = NSComboBox()
    private let result = NSTextField(labelWithString: "")
    /// Each edit starts a new check; only the latest one may update the sheet.
    private var check = 0
    private(set) var resolvedBase: String?

    var typedBase: String { baseField.stringValue.trimmingCharacters(in: .whitespaces) }

    init(branch: String, choice: Choice, candidates: [Candidate], suggestion: String?, hint: String?, repository: Repository) {
        self.repository = repository
        self.branch = branch
        self.choice = choice
        self.candidates = candidates
        super.init()
        let caption: String
        switch choice {
        case let .newBase(oldBase, moving):
            let commits = moving == 1 ? "Der Commit" : "Die \(moving) Commits"
            alert.messageText = "Rebase „\(branch)“ ab \(oldBase.id.prefix(7)) auf eine neue Basis"
            alert.informativeText = ([
                "\(commits) von „\(branch)“ nach \(oldBase.id.prefix(7)) „\(oldBase.subject)“ \(moving == 1 ? "kommt" : "kommen") auf die neue Basis. \(oldBase.id.prefix(7)) und alles davor bleibt, wo es ist.",
            ] + [hint].compactMap { $0 }).joined(separator: "\n\n")
            caption = "Neue Basis"
        case let .oldBase(newBase, place):
            alert.messageText = "Rebase „\(branch)“ auf \(place) – bisherige Basis wählen"
            alert.informativeText = ([
                "Die Commits von „\(branch)“ nach der bisherigen Basis kommen auf \(newBase.id.prefix(7)) „\(newBase.subject)“. Die Basis und alles davor bleibt zurück.",
            ] + [hint].compactMap { $0 }).joined(separator: "\n\n")
            caption = "Bisherige Basis"
        }
        alert.addButton(withTitle: "Rebase")
        alert.addButton(withTitle: "Abbrechen")

        baseField.addItems(withObjectValues: candidates.map(\.title))
        baseField.completes = true
        baseField.numberOfVisibleItems = Theme.RebaseSheet.visibleChoices
        baseField.placeholderString = "Branch, Tag oder Commit"
        baseField.stringValue = suggestion ?? ""
        baseField.delegate = self
        result.font = Theme.caption
        result.lineBreakMode = .byTruncatingTail

        let label = NSTextField(labelWithString: caption)
        label.font = Theme.caption
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, baseField, result])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.ActionSheet.labelSpacing
        for view in [baseField, result] { view.widthAnchor.constraint(equalToConstant: Theme.ActionSheet.fieldWidth).isActive = true }
        alert.accessoryView = stack
        alert.buttons.first?.isEnabled = false
    }

    /// The resolved new and old base, or nil when the sheet was cancelled. Under the harness `GITBONSAI_ONTO=<base>` fills the field first.
    func ask(using prompter: ActionPrompter) async -> (newBase: String, oldBase: String)? {
        if let answer = ScreenshotHarness.ontoBase { baseField.stringValue = answer }
        await validate()
        prepare()
        guard await prompter.confirm(alert), let resolvedBase else { return nil }
        switch choice {
        case .newBase(let oldBase, _): return (resolvedBase, oldBase.id)
        case .oldBase(let newBase, _): return (newBase.id, resolvedBase)
        }
    }

    func controlTextDidChange(_ notification: Notification) { Task { await validate() } }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field shows the picked value only after this notification returns.
        DispatchQueue.main.async { Task { await self.validate() } }
    }

    private func prepare() {
        guard let stack = alert.accessoryView else { return }
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.layout()
        alert.window.initialFirstResponder = baseField
    }

    private func validate() async {
        check += 1
        let current = check
        let typed = typedBase
        let revision = candidates.first { $0.title == typed }?.revision ?? typed
        let resolved = await repository.resolveCommit(revision)
        let (oldBase, newBase): (String?, String?) = switch choice {
        case .newBase(let old, _): (old.id, resolved)
        case .oldBase(let new, _): (resolved, new.id)
        }
        let moving = if let oldBase { (try? await repository.commitCount(from: oldBase, to: branch)) ?? 0 } else { 0 }
        guard current == check else { return }
        let message: String?
        switch resolved {
        case nil where typed.isEmpty: message = "Noch keine Basis gewählt"
        case nil: message = "„\(typed)“ ist kein Commit"
        case _ where oldBase == newBase: message = "Bisherige und neue Basis wären gleich; es gäbe nichts zu verschieben"
        case _ where moving == 0: message = "Über dieser Basis liegt kein Commit von „\(branch)“"
        default: message = nil
        }
        resolvedBase = message == nil ? resolved : nil
        alert.buttons.first?.isEnabled = resolvedBase != nil
        result.textColor = resolvedBase == nil ? Theme.persimmon : Theme.inkMuted
        let commits = moving == 1 ? "1 Commit wandert" : "\(moving) Commits wandern"
        result.stringValue = message ?? "\(commits) auf \(newBase?.prefix(7) ?? "")"
    }
}
