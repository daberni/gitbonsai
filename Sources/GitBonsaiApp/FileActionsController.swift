import AppKit
import GitEngine

/// The context menu of a file in the detail panel's lists, and running its entries with the questions they raise.
/// Staging, unstaging and discarding stay with `StagingController`; the menu only offers them.
@MainActor
final class FileActionsController {
    let prompter = ActionPrompter()
    /// The working tree changed outside of git's index operations; open diffs need to read it again.
    var onChange: (() -> Void)?
    private let viewModel: GraphViewModel
    private let staging: StagingController

    init(viewModel: GraphViewModel, staging: StagingController) {
        self.viewModel = viewModel
        self.staging = staging
    }

    /// The entries in groups: index operations (working directory only), external apps, copying, and what rewrites the file.
    /// Entries that need the file on disk are left out when it is not there, for instance for a deleted file.
    func menuItems(for file: FileRowView.Model) -> [NSMenuItem] {
        let selection = file.selection
        let onDisk = FileManager.default.fileExists(atPath: url(of: selection).path)
        let isConflict = file.state == .unmerged
        let groups = [indexItems(selection, isConflict: isConflict), openItems(selection, onDisk: onDisk, isConflict: isConflict), copyItems(selection), rewriteItems(file, onDisk: onDisk, isConflict: isConflict)].filter { !$0.isEmpty }
        return groups.enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group }
    }

    // MARK: Menu

    /// Untracked files are not offered the permanent discard here; moving them to the Trash does the same and can be undone.
    private func indexItems(_ selection: FileSelection, isConflict: Bool) -> [NSMenuItem] {
        guard !isConflict else { return [] }
        let path = selection.path
        switch selection.source {
        case .unstaged:
            return [
                ActionMenuItem("Stage") { [weak self] in self?.staging.stage([path]) },
                ActionMenuItem("Discard Changes…") { [weak self] in self?.staging.discard(selection) },
            ]
        case .untracked:
            return [ActionMenuItem("Stage") { [weak self] in self?.staging.stage([path]) }]
        case .staged:
            return [ActionMenuItem("Unstage") { [weak self] in self?.staging.unstage([path]) }]
        case .commit, .revisions:
            return []
        }
    }

    private func openItems(_ selection: FileSelection, onDisk: Bool, isConflict: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !isConflict { items.append(ActionMenuItem("Open in Diff Tool") { [weak self] in self?.openDiffTool(selection) }) }
        guard onDisk else { return items }
        let file = url(of: selection)
        let editor = ExternalApps.editor(forRepository: viewModel.repository.path)
        let editorTitle: LocalizedStringResource = editor.map { editor -> LocalizedStringResource in "Open in \(editor.app.name)" } ?? "Open in Editor"
        items.append(ActionMenuItem(editorTitle) { [weak self] in self?.openInEditor(file) })
        items.append(ActionMenuItem("Open with Default App") { [weak self] in self?.open(file, with: nil) })
        items.append(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) })
        return items
    }

    /// ⌥ turns "Copy Path" into "Copy Full Path".
    private func copyItems(_ selection: FileSelection) -> [NSMenuItem] {
        let relative = ActionMenuItem("Copy Path") { Self.copy(selection.path) }
        relative.keyEquivalentModifierMask = []
        let full = ActionMenuItem("Copy Full Path") { [weak self] in
            guard let self else { return }
            Self.copy(url(of: selection).path)
        }
        full.keyEquivalentModifierMask = .option
        full.isAlternate = true
        return [relative, full]
    }

    private func rewriteItems(_ file: FileRowView.Model, onDisk: Bool, isConflict: Bool) -> [NSMenuItem] {
        let selection = file.selection
        switch selection.source {
        case .commit(let commit):
            let title: LocalizedStringResource = file.state == .deleted ? "Restore Version Before This Commit" : "Restore from This Commit"
            return [ActionMenuItem(title) { [weak self] in self?.restore(selection.path, of: commit) }]
        case .revisions:
            return []
        case .unstaged, .staged, .untracked:
            guard onDisk, !isConflict else { return [] }
            return [ActionMenuItem("Move to Trash…") { [weak self] in self?.moveToTrash(selection) }]
        }
    }

    // MARK: Actions

    private func openDiffTool(_ selection: FileSelection) {
        let repository = viewModel.repository
        Task {
            guard await repository.hasDiffTool() else {
                let alert = NSAlert()
                alert.setText("No Diff Tool Set Up", info: "Git doesn’t know which program to show diffs with. Set one, for example with “git config --global diff.tool opendiff”.")
                alert.addButton(withTitle: String(localized: "OK", bundle: .module))
                _ = await prompter.confirm(alert)
                return
            }
            do {
                try await repository.openDiffTool(for: selection.path, originalPath: selection.originalPath, in: selection.source)
            } catch {
                prompter.report(error, title: "Couldn’t Start Diff Tool")
            }
        }
    }

    private func open(_ file: URL, with app: URL?) {
        guard let app else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.prompter.report(error, title: "Couldn’t Open File") }
        }
    }

    /// The same default editor as the command bar's "Open in Editor"; without any editor the system's default app.
    private func openInEditor(_ file: URL) {
        guard let editor = ExternalApps.editor(forRepository: viewModel.repository.path) else { return open(file, with: nil) }
        ExternalApps.open(file, in: editor.app, at: editor.url) { [weak self] error in
            guard let error else { return }
            self?.prompter.report(error, title: "Couldn’t Open File")
        }
    }

    /// Asks only when something local would be lost: an edit, a staged change, or an untracked file at the same path.
    private func restore(_ path: String, of commit: Commit) {
        let repository = viewModel.repository
        let name = (path as NSString).lastPathComponent
        Task {
            do {
                let revision = try await repository.restoreRevision(for: path, of: commit)
                if try await repository.hasLocalChanges(at: path) {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.setText("Restore \(RefName.path(name)) from \(RefName.commit(revision))?", info: "The local changes to \(RefName.path(path)) will be overwritten. This can’t be undone. Staged changes stay in the index.")
                    Self.addButtons(to: alert, confirm: "Restore")
                    guard await prompter.confirm(alert) else { return }
                }
                try await repository.restore(path, of: commit)
                await viewModel.refresh(note: "git restore --source=\(revision.prefix(7))")
            } catch {
                prompter.report(error, title: "Couldn’t Restore File")
                await viewModel.refresh(note: nil)
            }
            onChange?()
        }
    }

    private func moveToTrash(_ selection: FileSelection) {
        let file = url(of: selection)
        Task {
            let alert = NSAlert()
            alert.alertStyle = .warning
            let info: LocalizedStringResource = selection.source == .untracked ? "\(RefName.path(selection.path)) is removed from the working directory and goes to the Trash." : "\(RefName.path(selection.path)) is removed from the working directory and goes to the Trash. Git then shows it as deleted."
            alert.setText("Move \(RefName.path(selection.name)) to the Trash?", info: info)
            Self.addButtons(to: alert, confirm: "Move to Trash")
            guard await prompter.confirm(alert) else { return }
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            } catch {
                prompter.report(error, title: "Couldn’t Move File to Trash")
            }
            await viewModel.refresh(note: nil)
            onChange?()
        }
    }

    // MARK: Parts

    private func url(of selection: FileSelection) -> URL {
        URL(fileURLWithPath: viewModel.repository.path).appendingPathComponent(selection.path)
    }

    /// The destructive button is never the default, so Return cancels.
    private static func addButtons(to alert: NSAlert, confirm: LocalizedStringResource) {
        let button = alert.addButton(withTitle: confirm.text)
        button.hasDestructiveAction = true
        button.keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module)).keyEquivalent = "\r"
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
