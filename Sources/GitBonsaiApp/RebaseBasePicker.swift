import AppKit
import GitEngine

/// "von <old base> nach <target>" at the top of the interactive rebase sheet. The old base is a combo box: detected candidates first, then branches and tags, or any commit typed.
/// Each edit that names a commit asks `changeBase` to load the new range; only the latest edit may answer.
@MainActor
final class RebaseBasePicker: NSObject, NSComboBoxDelegate {
    private typealias M = Theme.InteractiveRebase

    /// An entry of the pick list; `title` may describe the commit `revision` names.
    struct Candidate {
        let title: String
        let revision: String
    }

    let view: NSStackView
    let field = NSComboBox()
    private let status = NSTextField(labelWithString: "")
    private var candidates: [Candidate]
    private var current: String
    private var check = 0
    /// Loads the range from the base `revision` names; returns why it cannot, or nil when the sheet now shows it.
    var changeBase: ((String) async -> String?)?

    init(base: Candidate, target: String, candidates: [Candidate], note: String?) {
        self.candidates = candidates
        current = base.revision
        let from = Self.caption("von")
        let to = Self.caption("nach")
        let targetLabel = NSTextField(labelWithString: target)
        targetLabel.font = Theme.bodyMedium
        targetLabel.textColor = Theme.ink
        targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.toolTip = target
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addItems(withObjectValues: candidates.map(\.title))
        field.completes = true
        field.numberOfVisibleItems = M.visibleBaseChoices
        field.placeholderString = "Branch, Tag oder Commit"
        field.stringValue = base.title
        field.font = Theme.body
        field.toolTip = "Die bisherige Basis: ihre Commits und alles davor bleiben zurück"
        field.setAccessibilityLabel("Bisherige Basis")
        status.font = Theme.caption
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view = NSStackView(views: [from, field, to, targetLabel, status])
        view.orientation = .horizontal
        view.alignment = .firstBaseline
        view.spacing = Theme.Space.s
        view.setCustomSpacing(Theme.Space.l, after: targetLabel)
        super.init()
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: M.baseFieldWidth).isActive = true
        show(note, isProblem: false)
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.caption
        label.textColor = Theme.inkMuted
        return label
    }

    func show(_ text: String?, isProblem: Bool) {
        status.stringValue = text ?? ""
        status.toolTip = text
        status.textColor = isProblem ? Theme.persimmon : Theme.inkMuted
    }

    func controlTextDidChange(_ notification: Notification) { Task { await baseEdited() } }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field shows the picked value only after this notification returns.
        DispatchQueue.main.async { Task { await self.baseEdited() } }
    }

    /// Under the harness `GITBONSAI_ONTO=<base>` and the `base:` step type the base.
    func type(_ text: String) async {
        field.stringValue = text
        await baseEdited()
    }

    private func baseEdited() async {
        check += 1
        let edit = check
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        let revision = candidates.first { $0.title == typed }?.revision ?? typed
        guard !typed.isEmpty else { return show("Noch keine Basis gewählt", isProblem: true) }
        guard revision != current else { return }
        let problem = await changeBase?(revision)
        guard edit == check else { return }
        if problem == nil { current = revision }
        show(problem, isProblem: problem != nil)
    }
}
