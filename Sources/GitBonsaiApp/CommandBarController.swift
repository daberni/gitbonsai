import AppKit
import GitEngine

/// The command bar (⌘⇧P): filters the commands the window and the active tab register, runs the chosen one, and continues in a second list for commands that need an argument.
/// ↑ ↓ move, ⏎ runs, ⌥⏎ checks out a ref of "Go to Ref…", Esc closes, ⌫ on an empty field goes back a step. Disabled commands stay listed with their reason, below the enabled ones, so the bar also says why something cannot run now.
@MainActor
final class CommandBarController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CommandBarController()

    private struct Step {
        let title: String?
        let placeholder: String
        let commands: [Command]
        var query = ""
    }

    private var overlay: CommandBarOverlay?
    private var steps: [Step] = []
    private var rows: [CommandRowView.Content] = []
    private weak var previousResponder: NSResponder?
    private let recents = CommandRecents()

    var isOpen: Bool { overlay != nil }
    private var panel: CommandBarPanel? { overlay?.panel }

    /// Opens the bar over the window's content with `commands`; a second ⇧⌘P while it is open closes it.
    func toggle(in window: NSWindow, commands: [Command]) {
        if isOpen { return close() }
        open(in: window, commands: commands)
    }

    /// Opens the bar, or starts it over; with `step`, a command that takes an argument, it opens right at that command's second list, as a menu item ending in "…" does.
    func open(in window: NSWindow, commands: [Command], step: Command? = nil) {
        if isOpen { close() }
        guard let host = window.contentView else { return }
        previousResponder = window.firstResponder
        let overlay = CommandBarOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        overlay.onClickOutside = { [weak self] in self?.close() }
        self.overlay = overlay
        let panel = overlay.panel
        panel.table.dataSource = self
        panel.table.delegate = self
        panel.search.onChange = { [weak self] text in self?.queryChanged(text) }
        panel.search.onCommand = { [weak self] command in self?.handle(command) ?? false }
        steps = [Step(title: nil, placeholder: String(localized: "commandBar.search.placeholder", defaultValue: "Search commands", bundle: .module), commands: commands)]
        if let step, case .choose(let placeholder, let build) = step.action {
            steps.append(Step(title: step.title, placeholder: placeholder.text, commands: build()))
        }
        showStep()
        window.makeFirstResponder(panel.search.field)
    }

    func close() {
        guard let overlay else { return }
        let window = overlay.window
        overlay.removeFromSuperview()
        self.overlay = nil
        steps = []
        rows = []
        if let previousResponder, let window { window.makeFirstResponder(previousResponder) }
    }

    // MARK: Steps

    private func showStep() {
        guard let panel, let step = steps.last else { return }
        panel.showStep(steps.count > 1 ? step.title.map(Self.withoutEllipsis) : nil)
        panel.search.placeholder = step.placeholder
        panel.search.stringValue = step.query
        reload()
    }

    /// A step's title is the command that opened it, without the ellipsis that promised the step: "Switch to tab…" heads its list as "Switch to Tab".
    private static func withoutEllipsis(_ title: String) -> String {
        guard title.hasSuffix("…") else { return title }
        return String(title.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private func queryChanged(_ text: String) {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].query = text
        reload()
    }

    /// Ranks the current step's commands for its query and selects the first enabled one.
    private func reload() {
        guard let panel, let step = steps.last else { return }
        let byID = Dictionary(step.commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = step.commands.compactMap(\.ref?.target)
        if !targets.isEmpty {
            rows = RefJump.rank(targets, query: step.query).compactMap { match in byID[match.target.id].map { CommandRowView.Content(command: $0, titleRanges: match.nameRanges) } }
        } else {
            let candidates = step.commands.map { CommandRanking.Candidate(id: $0.id, title: $0.title, keywords: $0.keywords + [$0.context].compactMap { $0 }, isEnabled: $0.isEnabled) }
            let recent = steps.count == 1 ? recents.ids : []
            rows = CommandRanking.rank(candidates, query: step.query, recent: recent).compactMap { result in byID[result.id].map { CommandRowView.Content(command: $0, titleRanges: result.titleRanges) } }
        }
        panel.table.reloadData()
        panel.showRows(rows.count)
        select(rows.isEmpty ? nil : 0)
    }

    private func select(_ index: Int?) {
        guard let table = panel?.table else { return }
        guard let index else { return table.deselectAll(nil) }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    // MARK: Keys

    private func handle(_ command: Selector) -> Bool {
        guard let table = panel?.table else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            if !rows.isEmpty { select(min(table.selectedRow + 1, rows.count - 1)) }
        case #selector(NSResponder.moveUp(_:)):
            if !rows.isEmpty { select(max(table.selectedRow - 1, 0)) }
        case #selector(NSResponder.insertNewline(_:)):
            run(row: table.selectedRow)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            checkout(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.deleteBackward(_:)):
            guard steps.count > 1, steps.last?.query.isEmpty == true else { return false }
            steps.removeLast()
            showStep()
        default:
            return false
        }
        return true
    }

    /// Runs the command in `row`: a second step opens in place, anything else closes the bar first so its sheets and focus land on the window.
    func run(row: Int) {
        guard rows.indices.contains(row) else { return }
        let command = rows[row].command
        guard command.isEnabled else { return NSSound.beep() }
        recents.note(steps.count == 1 ? command.id : nil)
        switch command.action {
        case .run(let perform):
            close()
            perform()
        case .choose(let placeholder, let build):
            steps.append(Step(title: command.title, placeholder: placeholder.text, commands: build()))
            showStep()
        }
    }

    /// ⌥⏎ on a ref of "Go to Ref…" checks it out; elsewhere, or where it cannot be checked out, it beeps.
    private func checkout(row: Int) {
        guard rows.indices.contains(row), let ref = rows[row].command.ref, ref.checkoutBlocked == nil else { return NSSound.beep() }
        close()
        ref.checkout()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PanelSelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = CommandRowView()
        view.content = rows[row]
        view.onPress = { [weak self] in self?.run(row: row) }
        return view
    }

    // MARK: Screenshot harness

    /// The step's title, the field and each listed row with selection, context or reason and shortcut.
    var harnessDescription: String {
        guard let panel else { return "command bar closed" }
        var lines = ["command bar\(steps.last?.title.map { " step \"\($0)\"" } ?? ""): field \"\(panel.search.stringValue)\", \(rows.count) rows"]
        for (index, row) in rows.enumerated() {
            let command = row.command
            let mark = index == panel.table.selectedRow ? ">" : " "
            let highlighted = row.titleRanges.map { (command.title as NSString).substring(with: $0) }.joined(separator: "|")
            var line = "\(mark) \(command.title)"
            if let context = command.context { line += " · \(context)" }
            if let reason = command.disabledReason { line += " [disabled: \(reason)]" }
            if let ref = command.ref { line += ref.checkoutBlocked.map { " [⌥⏎: \($0)]" } ?? " [⌥⏎]" }
            if let shortcut = command.shortcut { line += " \(MainMenu.displayedShortcut(of: command.id) ?? shortcut.display)" }
            if !highlighted.isEmpty { line += " {\(highlighted)}" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Ids of the commands run from the bar's first list, most recent first. Harness runs keep their own list.
@MainActor
final class CommandRecents {
    private static let key = "commandBarRecents"
    private static let limit = 8
    private var defaults: UserDefaults { ScreenshotHarness.defaults }

    var ids: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    func note(_ id: String?) {
        guard let id else { return }
        defaults.set(Array(([id] + ids.filter { $0 != id }).prefix(Self.limit)), forKey: Self.key)
    }
}
