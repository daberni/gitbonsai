import AppKit
import GitEngine

/// "von <old base> nach <target>" at the top of the interactive rebase sheet. The old base is a `RefPicker`: the detected candidates under "Vorschläge", then branches, remote branches and tags, or any commit typed.
/// Each choice asks `changeBase` to load the new range; only the latest choice may answer.
@MainActor
final class RebaseBasePicker {
    private typealias M = Theme.InteractiveRebase

    let view: NSStackView
    let picker: RefPicker
    private let status = NSTextField(labelWithString: "")
    private var current: String
    private var check = 0
    /// Loads the range from the base `revision` names; returns why it cannot, or nil when the sheet now shows it.
    var changeBase: ((String) async -> String?)?

    /// `base` is chosen first; `catalog` lists it with the other candidates under its current section.
    init(base: RefCatalog.Item, target: RefString, catalog: RefCatalog, repository: Repository, note: String?) {
        current = base.revision
        picker = RefPicker(repository: repository)
        picker.sectionTitles[.current] = "Vorschläge"
        picker.setCatalog(catalog, selection: base)
        picker.button.toolTip = "Die bisherige Basis: ihre Commits und alles davor bleiben zurück"
        picker.button.setAccessibilityLabel("Bisherige Basis")
        let from = Self.caption("von")
        let to = Self.caption("nach")
        let targetLabel = NSTextField(labelWithString: "")
        targetLabel.font = Theme.bodyMedium
        targetLabel.textColor = Theme.ink
        targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.setText(target)
        targetLabel.toolTip = target.plain
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = Theme.caption
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view = NSStackView(views: [from, picker.button, to, targetLabel, status])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = Theme.Space.s
        view.setCustomSpacing(Theme.Space.l, after: targetLabel)
        picker.button.widthAnchor.constraint(equalToConstant: M.baseFieldWidth).isActive = true
        picker.onChange = { [weak self] item in Task { await self?.baseChosen(item.revision) } }
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

    /// Under the harness `GITBONSAI_ONTO=<base>` and the `base:` step choose the base by name or revision, as picking it in the list would.
    func type(_ text: String) async {
        guard let item = await picker.choose(text.trimmingCharacters(in: .whitespaces)) else { return show("„\(text)“ ist kein Commit", isProblem: true) }
        await baseChosen(item.revision)
    }

    private func baseChosen(_ revision: String) async {
        check += 1
        let edit = check
        guard revision != current else { return }
        let problem = await changeBase?(revision)
        guard edit == check else { return }
        if problem == nil { current = revision }
        show(problem, isProblem: problem != nil)
    }
}
