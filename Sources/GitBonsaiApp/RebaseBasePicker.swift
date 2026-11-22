import AppKit
import GitEngine

/// "from <old base> to <target>" at the top of the interactive rebase sheet. The old base is a `RefPicker`: the detected candidates under "Suggestions", then branches, remote branches and tags, or any commit typed.
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
        picker.sectionTitles[.current] = String(localized: "rebase.basePicker.suggestions", defaultValue: "Suggestions", bundle: .module, comment: "Section of the base picker with the detected old bases.")
        picker.setCatalog(catalog, selection: base)
        picker.button.toolTip = String(localized: "rebase.basePicker.toolTip", defaultValue: "The old base: its commits and everything before them stay behind", bundle: .module)
        picker.button.setAccessibilityLabel(String(localized: "rebase.basePicker.accessibility", defaultValue: "Old base", bundle: .module))
        // Captions between the controls of one line, "from <old base> to <target>"; the controls cannot sit inside one sentence.
        let from = Self.caption(String(localized: "rebase.basePicker.from", defaultValue: "from", bundle: .module, comment: "Rebase sheet, before the old base picker: from <old base> to <target>."))
        let to = Self.caption(String(localized: "rebase.basePicker.to", defaultValue: "to", bundle: .module, comment: "Rebase sheet, before the target: from <old base> to <target>."))
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
        guard let item = await picker.choose(text.trimmingCharacters(in: .whitespaces)) else { return show(String(localized: "rebase.base.notACommit", defaultValue: "“\(text)” is not a commit", bundle: .module), isProblem: true) }
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
