import AppKit
import GitEngine

/// The context menu of a file in the detail panel's lists, and running its entries with the questions they raise.
/// Staging, unstaging and discarding stay with `StagingUseCase`; the menu only offers them.
@MainActor
final class FileActions {
    private let prompter: any Prompting
    private let settings: AppSettings
    private let pasteboard: Pasteboard
    /// The working tree changed outside of git's index operations; open diffs need to read it again.
    var onChange: (() -> Void)?
    private let viewModel: GraphViewModel
    private let staging: StagingUseCase
    private let conflicts: ConflictActions

    init(context: RepositoryContext, staging: StagingUseCase, conflicts: ConflictActions) {
        viewModel = context.model
        prompter = context.prompter
        settings = context.settings
        pasteboard = context.app.pasteboard
        self.staging = staging
        self.conflicts = conflicts
    }

    /// The entries in groups: index operations (working directory only), external apps, copying, and what rewrites the files.
    /// Every entry acts on all `files` at once. For one file, entries that need it on disk are left out when it is not there; for several, an entry that does not fit every file stays visible, disabled, with the reason as its tooltip.
    /// Conflicted files alone get the conflict entries in place of the index operations.
    func groups(for files: [FileRowView.Model]) -> [[MenuEntry]] {
        guard !files.isEmpty else { return [] }
        if files.allSatisfy({ $0.state == .unmerged }) {
            return conflicts.groups(for: files.map(\.selection.path)) + [openItems(files), copyItems(files.map(\.selection)), rewriteItems(files)]
        }
        return [indexItems(files), openItems(files), copyItems(files.map(\.selection)), rewriteItems(files)]
    }

    // MARK: Menu

    /// One "Discard…" for every working-directory selection: tracked changes are restored, untracked files go to the Trash.
    private func indexItems(_ files: [FileRowView.Model]) -> [MenuEntry] {
        let selections = files.map(\.selection)
        let paths = selections.map(\.path)
        let conflicts = files.contains { $0.state == .unmerged }
        let stageable = !conflicts && selections.allSatisfy(\.isStageable)
        let unstageable = !conflicts && selections.allSatisfy(\.isUnstageable)
        let isWorking = selections.contains { $0.isStageable || $0.isUnstageable }
        guard isWorking else { return [] }
        let discard = LocalizedStringResource("files.menu.discard", defaultValue: "Discard…", bundle: .module)
        if files.count == 1 {
            guard !conflicts else { return [] }
            if unstageable { return [MenuEntry(LocalizedStringResource("files.menu.unstage", defaultValue: "Unstage", bundle: .module)) { [weak self] in self?.staging.unstage(paths) }] }
            return [
                MenuEntry(LocalizedStringResource("files.menu.stage", defaultValue: "Stage", bundle: .module)) { [weak self] in self?.staging.stage(paths) },
                MenuEntry(discard) { [weak self] in self?.staging.discard(selections) },
            ]
        }
        let reason = conflicts ? Self.conflictReason : nil
        return [
            Self.item(LocalizedStringResource("files.menu.stage", defaultValue: "Stage", bundle: .module), disabledBy: stageable ? nil : reason ?? LocalizedStringResource("files.menu.notAllUnstaged", defaultValue: "Not every selected file has unstaged changes", bundle: .module)) { [weak self] in self?.staging.stage(paths) },
            Self.item(LocalizedStringResource("files.menu.unstage", defaultValue: "Unstage", bundle: .module), disabledBy: unstageable ? nil : reason ?? LocalizedStringResource("files.menu.notAllStaged", defaultValue: "Not every selected file is staged", bundle: .module)) { [weak self] in self?.staging.unstage(paths) },
            Self.item(discard, disabledBy: stageable ? nil : reason ?? LocalizedStringResource("files.menu.notAllUnstaged", defaultValue: "Not every selected file has unstaged changes", bundle: .module)) { [weak self] in self?.staging.discard(selections) },
        ]
    }

    private func openItems(_ files: [FileRowView.Model]) -> [MenuEntry] {
        let selections = files.map(\.selection)
        let urls = selections.map(url(of:))
        let onDisk = urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let conflicts = files.contains { $0.state == .unmerged }
        var items: [MenuEntry] = []
        if let only = selections.first, files.count == 1 {
            if !conflicts { items.append(MenuEntry(LocalizedStringResource("files.menu.openDiffTool", defaultValue: "Open in diff tool", bundle: .module)) { [weak self] in self?.openDiffTool(only) }) }
            guard onDisk else { return items }
        } else {
            items.append(Self.item(LocalizedStringResource("files.menu.openDiffTool", defaultValue: "Open in diff tool", bundle: .module), disabledBy: LocalizedStringResource("files.menu.oneAtATime", defaultValue: "The diff tool opens one file at a time", bundle: .module)) {})
        }
        let missing: LocalizedStringResource? = onDisk ? nil : LocalizedStringResource("files.menu.notAllOnDisk", defaultValue: "Not every selected file is in the working directory", bundle: .module)
        let editor = ExternalApps.editor(forRepository: viewModel.repository.path, settings: settings)
        let editorTitle: LocalizedStringResource = editor.map { editor -> LocalizedStringResource in LocalizedStringResource("files.menu.openIn", defaultValue: "Open in \(editor.app.name)", bundle: .module) } ?? LocalizedStringResource("command.openEditor.title", defaultValue: "Open in editor", bundle: .module)
        items.append(Self.item(editorTitle, disabledBy: missing) { [weak self] in urls.forEach { self?.openInEditor($0) } })
        items.append(Self.item(LocalizedStringResource("files.menu.openDefaultApp", defaultValue: "Open with default app", bundle: .module), disabledBy: missing) { urls.forEach { ExternalApps.openWithDefaultApp($0) } })
        items.append(Self.item(LocalizedStringResource("common.showInFinder", defaultValue: "Show in Finder", bundle: .module), disabledBy: missing) { ExternalApps.reveal(urls) })
        return items
    }

    /// ⌥ turns "Copy path" into "Copy full path"; several paths go to the pasteboard one per line.
    private func copyItems(_ selections: [FileSelection]) -> [MenuEntry] {
        let relative = MenuEntry(LocalizedStringResource("files.menu.copyPath", defaultValue: "Copy path", bundle: .module)) { [pasteboard] in pasteboard.copy(selections.map(\.path).joined(separator: "\n")) }
        var full = MenuEntry(LocalizedStringResource("files.menu.copyFullPath", defaultValue: "Copy full path", bundle: .module)) { [weak self] in
            guard let self else { return }
            self.pasteboard.copy(selections.map { self.url(of: $0).path }.joined(separator: "\n"))
        }
        full.alternateModifiers = .option
        return [relative, full]
    }

    private func rewriteItems(_ files: [FileRowView.Model]) -> [MenuEntry] {
        let selections = files.map(\.selection)
        let commits = selections.compactMap { selection -> Commit? in if case .commit(let commit) = selection.source { commit } else { nil } }
        if let commit = commits.first {
            let paths = selections.map(\.path)
            let revertPaths = selections.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
            let oneCommit = commits.count == selections.count && commits.allSatisfy { $0.id == commit.id }
            let reason: LocalizedStringResource? = oneCommit ? nil : LocalizedStringResource("files.menu.differentCommits", defaultValue: "The selected files belong to different Commits", bundle: .module)
            let restoreTitle: LocalizedStringResource = files.count == 1 && files[0].state == .deleted ? LocalizedStringResource("files.menu.restoreBefore", defaultValue: "Restore version before this Commit", bundle: .module) : LocalizedStringResource("files.menu.restoreFrom", defaultValue: "Restore from this Commit", bundle: .module)
            return [
                Self.item(restoreTitle, disabledBy: reason) { [weak self] in self?.restore(paths, of: commit) },
                Self.item(LocalizedStringResource("files.menu.revertChanges", defaultValue: "Revert changes of this Commit", bundle: .module), disabledBy: reason) { [weak self] in self?.revertChanges(of: commit, paths: revertPaths) },
            ]
        }
        return []
    }

    private static let conflictReason = LocalizedStringResource("files.menu.hasConflicts", defaultValue: "Some selected files have unresolved conflicts", bundle: .module)

    /// An entry that is shown but cannot be chosen says why in its tooltip.
    private static func item(_ title: LocalizedStringResource, disabledBy reason: LocalizedStringResource?, handler: @escaping @MainActor () -> Void) -> MenuEntry {
        .action(title, disabledBecause: reason?.text, action: handler)
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
            do {
                try await repository.openDiffTool(for: selection.path, originalPath: selection.originalPath, in: selection.source)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.diffToolNotStarted", defaultValue: "Couldn’t Start Diff Tool", bundle: .module))
            }
        }
    }

    /// The same default editor as the command bar's "Open in editor"; without any editor the system's default app.
    private func openInEditor(_ file: URL) {
        guard let editor = ExternalApps.editor(forRepository: viewModel.repository.path, settings: settings) else { return ExternalApps.openWithDefaultApp(file) }
        ExternalApps.open(file, in: editor.app, at: editor.url) { [weak self] error in
            guard let error else { return }
            self?.prompter.report(error, title: LocalizedStringResource("failure.file.notOpened", defaultValue: "Couldn’t Open File", bundle: .module))
        }
    }

    /// Asks only when something local would be lost: an edit, a staged change, or an untracked file at the same path.
    private func restore(_ paths: [String], of commit: Commit) {
        let repository = viewModel.repository
        Task {
            do {
                let revision = try await repository.restoreRevision(for: paths[0], of: commit)
                if try await repository.hasLocalChanges(at: paths) {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    let names = RefString(marked: paths.map(RefName.path).joined(separator: "\n") + "\n← " + RefName.commit(revision))
                    if paths.count == 1 {
                        alert.setConfirmation(LocalizedStringResource("files.restore.title", defaultValue: "Restore File?", bundle: .module), names: names)
                    } else {
                        alert.setConfirmation(LocalizedStringResource("files.restoreSeveral.title", defaultValue: "Restore Files?", bundle: .module), names: names)
                    }
                    Self.addButtons(to: alert, confirm: LocalizedStringResource("files.restore.confirm", defaultValue: "Restore", bundle: .module))
                    guard await prompter.confirm(alert) else { return }
                }
                try await repository.restore(paths, of: commit)
                await viewModel.refresh(note: "git restore --source=\(revision.prefix(RefString.shortSHA))")
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.notRestored", defaultValue: "Couldn’t Restore File", bundle: .module))
                await viewModel.refresh(note: nil)
            }
            onChange?()
        }
    }

    /// Writes into the working tree only and never over local edits it cannot merge: git applies the whole patch or nothing.
    private func revertChanges(of commit: Commit, paths: [String]) {
        let repository = viewModel.repository
        Task {
            do {
                try await repository.revertChanges(of: commit, paths: paths)
                await viewModel.refresh(note: "git apply --reverse")
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.notReverted", defaultValue: "Couldn’t Revert Changes", bundle: .module))
                await viewModel.refresh(note: nil)
            }
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
