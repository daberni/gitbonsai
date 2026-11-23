import AppKit
import GitEngine

/// Moves changes between working tree and index, discards unstaged changes after asking, shows git's message when that fails, and refreshes the tab afterwards.
@MainActor
final class StagingController {
    /// The index or the working tree changed; open diffs need to read them again.
    var onChange: (() -> Void)?
    var window: (() -> NSWindow?)?
    let viewModel: GraphViewModel

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    func stage(_ paths: [String]) {
        run { try await $0.stage(paths) }
    }

    func unstage(_ paths: [String]) {
        run { try await $0.unstage(paths) }
    }

    func stage(_ hunk: DiffHunk, of file: FileDiff) {
        run { try await $0.stage(hunk, of: file) }
    }

    func unstage(_ hunk: DiffHunk, of file: FileDiff) {
        run { try await $0.unstage(hunk, of: file) }
    }

    // MARK: Discarding

    /// Reverts one hunk of an unstaged file once the user confirmed it; the only hunk of an untracked file deletes the file.
    func discard(_ hunk: DiffHunk, of file: FileDiff, untracked: Bool) {
        if untracked {
            confirmDeletion(of: file.path) { [weak self] in
                self?.run(failure: Self.discardFailure) { try await $0.discard(hunk, of: file) }
            }
            return
        }
        // The changed lines, not the context around them: added lines by their new number, removed ones by their old.
        let changed = hunk.lines.compactMap { line -> Int? in
            switch line.kind {
            case .added: line.newNumber
            case .removed: line.oldNumber
            case .context: nil
            }
        }
        let first = changed.min() ?? hunk.newStart
        let last = changed.max() ?? first
        let text: LocalizedStringResource = if first == last {
            LocalizedStringResource("files.discardHunk.infoLine", defaultValue: "The changes in line \(first) of \(RefName.path(file.path)) are lost. This cannot be undone.", bundle: .module)
        } else {
            LocalizedStringResource("files.discardHunk.infoLines", defaultValue: "The changes in lines \(first)–\(last) of \(RefName.path(file.path)) are lost. This cannot be undone.", bundle: .module)
        }
        confirm(title: LocalizedStringResource("files.discardHunk.title", defaultValue: "Discard hunk?", bundle: .module), text: text) { [weak self] in
            self?.run(failure: Self.discardFailure) { try await $0.discard(hunk, of: file) }
        }
    }

    /// Reverts tracked files to their staged content and deletes untracked ones, once the user confirmed it; staged changes stay. Other files are left out.
    func discard(_ files: [FileSelection]) {
        let tracked = files.filter { $0.source == .unstaged }.map(\.path)
        let untracked = files.filter { $0.source == .untracked }.map(\.path)
        let perform: () -> Void = { [weak self] in
            self?.run(failure: Self.discardFailure) { repository in
                try await repository.discardUnstagedChanges(tracked)
                try await repository.removeUntracked(untracked)
            }
        }
        switch (tracked.count, untracked.count) {
        case (0, 0):
            return
        case (1, 0):
            let path = tracked[0]
            confirm(title: LocalizedStringResource("files.discard.title", defaultValue: "Discard changes to \(RefName.path((path as NSString).lastPathComponent))?", bundle: .module), text: LocalizedStringResource("files.discard.info", defaultValue: "All unstaged changes to \(RefName.path(path)) are lost. Staged changes stay. This cannot be undone.", bundle: .module), then: perform)
        case (0, 1):
            confirmDeletion(of: untracked[0], then: perform)
        default:
            let count = tracked.count + untracked.count
            let text: LocalizedStringResource = untracked.isEmpty ? LocalizedStringResource("files.discardSeveral.info", defaultValue: "Their unstaged changes are lost. Staged changes stay. This cannot be undone.", bundle: .module) : LocalizedStringResource("files.discardSeveral.infoUntracked", defaultValue: "Unstaged changes are lost and \(untracked.count) untracked files are deleted. Staged changes stay. This cannot be undone.", bundle: .module)
            confirm(title: LocalizedStringResource("files.discardSeveral.title", defaultValue: "Discard changes to \(count) files?", bundle: .module), text: text, then: perform)
        }
    }

    private static let discardFailure: LocalizedStringResource = LocalizedStringResource("failure.files.notDiscarded", defaultValue: "Changes not discarded", bundle: .module)

    /// Git has never seen an untracked file, so the sheet says plainly that it is gone for good.
    private func confirmDeletion(of path: String, then perform: @escaping () -> Void) {
        let name = (path as NSString).lastPathComponent
        confirm(title: LocalizedStringResource("files.deleteUntracked.title", defaultValue: "Delete \(RefName.path(name))?", bundle: .module), text: LocalizedStringResource("files.deleteUntracked.info", defaultValue: "The untracked file \(RefName.path(path)) is deleted. Git does not know it, so it cannot be restored.", bundle: .module), then: perform)
    }

    /// The question comes as a sheet on the window; the destructive button is never the default, so Return does not discard, and Esc cancels too.
    private func confirm(title: LocalizedStringResource, text: LocalizedStringResource, then perform: @escaping () -> Void) {
        guard let window = window?() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.setText(title, info: text)
        let discard = alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard", bundle: .module))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        cancel.keyEquivalent = "\r"
        if ScreenshotHarness.keysSheets { ScreenshotHarness.pressKey(on: alert) } else { ScreenshotHarness.answerDiscardSheet(alert) }
        Task {
            if await alert.beginSheet(on: window) == .alertFirstButtonReturn { perform() }
        }
    }

    // MARK: Running

    private func run(failure: LocalizedStringResource = LocalizedStringResource("failure.files.indexNotChanged", defaultValue: "Index not changed", bundle: .module), _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        Task { [weak self] in
            do {
                try await operation(repository)
            } catch {
                self?.report(error, title: failure)
            }
            await self?.viewModel.refresh(note: nil)
            self?.onChange?()
        }
    }

    private func report(_ error: Error, title: LocalizedStringResource) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title.text
        alert.informativeText = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(error)"
        guard ScreenshotHarness.outputPath == nil, let window = window?() else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.beginSheetModal(for: window)
    }
}
