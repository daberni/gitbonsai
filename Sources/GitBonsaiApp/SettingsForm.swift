import AppKit

/// Lays out one settings section as the system settings do: labels right-aligned in front of their controls, explanations under the controls.
@MainActor
final class SettingsForm {
    private let grid = NSGridView()

    init() {
        grid.rowSpacing = Theme.Settings.rowSpacing
        grid.columnSpacing = Theme.Settings.columnSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A control with its label; nil leaves the label column free.
    func addRow(_ label: LocalizedStringResource?, _ control: NSView) {
        let title = NSTextField(labelWithString: label.map { String(localized: "\($0.text):", bundle: .module, comment: "A settings label in front of its control.") } ?? "")
        title.alignment = .right
        let row = grid.addRow(with: [title, control])
        row.rowAlignment = .firstBaseline
    }

    /// An explanation under the row above, close to its control.
    func addCaption(_ caption: NSTextField) {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, caption])
        if grid.numberOfRows > 1 { grid.row(at: grid.numberOfRows - 2).bottomPadding = Theme.Settings.captionGap - Theme.Settings.rowSpacing }
        row.yPlacement = .top
    }

    /// The finished section: the grid inside the settings width, with the label column sized to its longest label.
    func makeView() -> NSView {
        grid.column(at: 0).xPlacement = .trailing
        let view = NSView()
        view.addSubview(grid)
        let inset = Theme.Settings.inset
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Theme.Settings.width),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: inset),
        ])
        return view
    }

    static func statusLine() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = Theme.caption
        field.lineBreakMode = .byTruncatingMiddle
        field.widthAnchor.constraint(equalToConstant: Theme.Settings.captionWidth).isActive = true
        return field
    }

    static func caption(_ text: LocalizedStringResource) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text.text)
        field.font = Theme.caption
        field.textColor = Theme.inkMuted
        field.preferredMaxLayoutWidth = Theme.Settings.captionWidth
        return field
    }
}

/// Settings sections size the window to their content.
class SettingsPaneController: NSViewController {
    func buildForm(_ form: SettingsForm) {}

    override func loadView() {
        let form = SettingsForm()
        buildForm(form)
        view = form.makeView()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = view.fittingSize
    }
}
