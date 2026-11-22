import AppKit
import GitEngine

/// Asks for the new base of `git rebase --onto <new base> <old base> <branch>`: a branch, tag or commit typed or picked from the refs.
/// It says how many commits move and keeps the confirm button disabled until the new base names a commit.
@MainActor
final class RebaseOntoSheet: NSObject, NSComboBoxDelegate {
    let alert = NSAlert()
    private let repository: Repository
    private let oldBase: String
    private let moving: Int
    private let baseField = NSComboBox()
    private let result = NSTextField(labelWithString: "")
    /// Each edit starts a new check; only the latest one may update the sheet.
    private var check = 0
    private(set) var resolvedBase: String?

    var newBase: String { baseField.stringValue.trimmingCharacters(in: .whitespaces) }

    init(branch: String, oldBase: Commit, moving: Int, candidates: [String], suggestion: String?, hint: String?, repository: Repository) {
        self.repository = repository
        self.oldBase = oldBase.id
        self.moving = moving
        super.init()
        let commits = moving == 1 ? "Der Commit" : "Die \(moving) Commits"
        alert.messageText = "„\(branch)“ ab \(oldBase.id.prefix(7)) auf eine neue Basis verschieben"
        alert.informativeText = ([
            "\(commits) von „\(branch)“ nach \(oldBase.id.prefix(7)) „\(oldBase.subject)“ \(moving == 1 ? "kommt" : "kommen") auf die neue Basis. \(oldBase.id.prefix(7)) und alles davor bleibt, wo es ist.",
        ] + [hint].compactMap { $0 }).joined(separator: "\n\n")
        alert.addButton(withTitle: "Verschieben")
        alert.addButton(withTitle: "Abbrechen")

        baseField.addItems(withObjectValues: candidates)
        baseField.completes = true
        baseField.numberOfVisibleItems = Theme.RebaseSheet.visibleChoices
        baseField.placeholderString = "Branch, Tag oder Commit"
        baseField.stringValue = suggestion ?? ""
        baseField.delegate = self
        result.font = Theme.caption
        result.lineBreakMode = .byTruncatingTail

        let caption = NSTextField(labelWithString: "Neue Basis")
        caption.font = Theme.caption
        caption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [caption, baseField, result])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.ActionSheet.labelSpacing
        for view in [baseField, result] { view.widthAnchor.constraint(equalToConstant: Theme.ActionSheet.fieldWidth).isActive = true }
        alert.accessoryView = stack
        alert.buttons.first?.isEnabled = false
    }

    /// The chosen new base, or nil when the sheet was cancelled. Under the harness `GITBONSAI_ONTO=<base>` fills the field first.
    func ask(using prompter: ActionPrompter) async -> String? {
        if let answer = ScreenshotHarness.ontoBase { baseField.stringValue = answer }
        await validate()
        prepare()
        guard await prompter.confirm(alert), resolvedBase != nil else { return nil }
        return newBase
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
        let base = newBase
        let resolved = await repository.resolveCommit(base)
        guard current == check else { return }
        resolvedBase = resolved == oldBase ? nil : resolved
        alert.buttons.first?.isEnabled = resolvedBase != nil
        result.textColor = resolvedBase == nil ? Theme.persimmon : Theme.inkMuted
        let commits = moving == 1 ? "1 Commit wandert" : "\(moving) Commits wandern"
        switch resolved {
        case nil where base.isEmpty: result.stringValue = "Noch keine neue Basis gewählt"
        case nil: result.stringValue = "„\(base)“ ist kein Commit"
        case oldBase: result.stringValue = "Das ist die bisherige Basis; es gäbe nichts zu verschieben"
        case let sha?: result.stringValue = "\(commits) auf \(sha.prefix(7))"
        }
    }
}
