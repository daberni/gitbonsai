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
                ActionMenuItem(LocalizedStringResource("files.menu.stage", defaultValue: "Stage", bundle: .module)) { [weak self] in self?.staging.stage([path]) },
                ActionMenuItem(LocalizedStringResource("files.menu.discard", defaultValue: "Discard changes…", bundle: .module)) { [weak self] in self?.staging.discard(selection) },
            ]
        case .untracked:
            return [ActionMenuItem(LocalizedStringResource("files.menu.stage", defaultValue: "Stage", bundle: .module)) { [weak self] in self?.staging.stage([path]) }]
        case .staged:
            return [ActionMenuItem(LocalizedStringResource("files.menu.unstage", defaultValue: "Unstage", bundle: .module)) { [weak self] in self?.staging.unstage([path]) }]
        case .commit, .revisions:
            return []
        }
    }

    private func openItems(_ selection: FileSelection, onDisk: Bool, isConflict: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !isConflict { items.append(ActionMenuItem(LocalizedStringResource("files.menu.openDiffTool", defaultValue: "Open in diff tool", bundle: .module)) { [weak self] in self?.openDiffTool(selection) }) }
        guard onDisk else { return items }
        let file = url(of: selection)
        let editor = ExternalApps.editor(forRepository: viewModel.repository.path)
        let editorTitle: LocalizedStringResource = editor.map { editor -> LocalizedStringResource in LocalizedStringResource("files.menu.openIn", defaultValue: "Open in \(editor.app.name)", bundle: .module) } ?? LocalizedStringResource("command.openEditor.title", defaultValue: "Open in editor", bundle: .module)
        items.append(ActionMenuItem(editorTitle) { [weak self] in self?.openInEditor(file) })
        items.append(ActionMenuItem(LocalizedStringResource("files.menu.openDefaultApp", defaultValue: "Open with default app", bundle: .module)) { ExternalApps.openWithDefaultApp(file) })
        items.append(ActionMenuItem(LocalizedStringResource("common.showInFinder", defaultValue: "Show in Finder", bundle: .module)) { ExternalApps.reveal([file]) })
        return items
    }

    /// ⌥ turns "Copy path" into "Copy full path".
    private func copyItems(_ selection: FileSelection) -> [NSMenuItem] {
        let relative = ActionMenuItem(LocalizedStringResource("files.menu.copyPath", defaultValue: "Copy path", bundle: .module)) { ActionRunner.copy(selection.path) }
        relative.keyEquivalentModifierMask = []
        let full = ActionMenuItem(LocalizedStringResource("files.menu.copyFullPath", defaultValue: "Copy full path", bundle: .module)) { [weak self] in
            guard let self else { return }
            ActionRunner.copy(url(of: selection).path)
        }
        full.keyEquivalentModifierMask = .option
        full.isAlternate = true
        return [relative, full]
    }

    private func rewriteItems(_ file: FileRowView.Model, onDisk: Bool, isConflict: Bool) -> [NSMenuItem] {
        let selection = file.selection
        switch selection.source {
        case .commit(let commit):
            let title: LocalizedStringResource = file.state == .deleted ? LocalizedStringResource("files.menu.restoreBefore", defaultValue: "Restore version before this Commit", bundle: .module) : LocalizedStringResource("files.menu.restoreFrom", defaultValue: "Restore from this Commit", bundle: .module)
            return [ActionMenuItem(title) { [weak self] in self?.restore(selection.path, of: commit) }]
        case .revisions:
            return []
        case .unstaged, .staged, .untracked:
            guard onDisk, !isConflict else { return [] }
            return [ActionMenuItem(LocalizedStringResource("files.menu.moveToTrash", defaultValue: "Move to Trash…", bundle: .module)) { [weak self] in self?.moveToTrash(selection) }]
        }
    }

    // MARK: Actions

    private func openDiffTool(_ selection: FileSelection) {
        let repository = viewModel.repository
        Task {
            guard await repository.hasDiffTool() else {
                let alert = NSAlert()
                alert.setText(LocalizedStringResource("files.diffTool.missingTitle", defaultValue: "No Diff Tool Set Up", bundle: .module), info: LocalizedStringResource("files.diffTool.missingInfo", defaultValue: "Git doesn’t know which program to show diffs with. Set one, for example with “git config --global diff.tool opendiff”.", bundle: .module))
                alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module))
                _ = await prompter.confirm(alert)
                return
            }
            // git starts the configured program itself, so harness runs stop before it.
            if ScreenshotHarness.isActive { return ScreenshotHarness.reportOpening("diff tool", "git difftool \(selection.path)") }
            do {
                try await repository.openDiffTool(for: selection.path, originalPath: selection.originalPath, in: selection.source)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.diffToolNotStarted", defaultValue: "Couldn’t Start Diff Tool", bundle: .module))
            }
        }
    }

    /// The same default editor as the command bar's "Open in editor"; without any editor the system's default app.
    private func openInEditor(_ file: URL) {
        guard let editor = ExternalApps.editor(forRepository: viewModel.repository.path) else { return ExternalApps.openWithDefaultApp(file) }
        ExternalApps.open(file, in: editor.app, at: editor.url) { [weak self] error in
            guard let error else { return }
            self?.prompter.report(error, title: LocalizedStringResource("failure.file.notOpened", defaultValue: "Couldn’t Open File", bundle: .module))
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
                    alert.setText(LocalizedStringResource("files.restore.title", defaultValue: "Restore \(RefName.path(name)) from \(RefName.commit(revision))?", bundle: .module), info: LocalizedStringResource("files.restore.info", defaultValue: "The local changes to \(RefName.path(path)) will be overwritten. This can’t be undone. Staged changes stay in the index.", bundle: .module))
                    Self.addButtons(to: alert, confirm: LocalizedStringResource("files.restore.confirm", defaultValue: "Restore", bundle: .module))
                    guard await prompter.confirm(alert) else { return }
                }
                try await repository.restore(path, of: commit)
                await viewModel.refresh(note: "git restore --source=\(revision.prefix(RefString.shortSHA))")
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.notRestored", defaultValue: "Couldn’t Restore File", bundle: .module))
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
            let info: LocalizedStringResource = selection.source == .untracked ? LocalizedStringResource("files.trash.infoUntracked", defaultValue: "\(RefName.path(selection.path)) is removed from the working directory and goes to the Trash.", bundle: .module) : LocalizedStringResource("files.trash.info", defaultValue: "\(RefName.path(selection.path)) is removed from the working directory and goes to the Trash. Git then shows it as deleted.", bundle: .module)
            alert.setText(LocalizedStringResource("files.trash.title", defaultValue: "Move \(RefName.path(selection.name)) to the Trash?", bundle: .module), info: info)
            Self.addButtons(to: alert, confirm: LocalizedStringResource("files.trash.confirm", defaultValue: "Move to Trash", bundle: .module))
            guard await prompter.confirm(alert) else { return }
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.notTrashed", defaultValue: "Couldn’t Move File to Trash", bundle: .module))
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
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)).keyEquivalent = "\r"
    }
}
