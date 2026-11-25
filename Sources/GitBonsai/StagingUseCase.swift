import AppKit
import GitEngine

/// Moves changes between working tree and index, discards unstaged changes after asking, shows git's message when that fails, and refreshes the tab afterwards.
@MainActor
final class StagingUseCase {
    /// The index or the working tree changed; open diffs need to read them again.
    var onChange: (() -> Void)?
    let viewModel: GraphViewModel
    let prompter: any Prompting
    let runner: ActionRunner

    init(context: RepositoryContext) {
        viewModel = context.model
        prompter = context.prompter
        runner = context.runner
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
        confirm(title: LocalizedStringResource("files.discardHunk.title", defaultValue: "Discard Hunk?", bundle: .module), names: RefString(marked: RefName.path(file.path))) { [weak self] in
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
            confirm(title: LocalizedStringResource("files.discard.title", defaultValue: "Discard Changes?", bundle: .module), names: RefString(marked: RefName.path(tracked[0])), then: perform)
        case (0, 1):
            confirmDeletion(of: untracked[0], then: perform)
        default:
            let names = RefString(marked: (tracked + untracked).map(RefName.path).joined(separator: "\n"))
            let text: LocalizedStringResource? = untracked.isEmpty ? nil : LocalizedStringResource("files.discardSeveral.infoUntracked", defaultValue: "\(untracked.count) untracked files are deleted.", bundle: .module)
            confirm(title: LocalizedStringResource("files.discardSeveral.title", defaultValue: "Discard Changes to several Files?", bundle: .module), names: names, text: text, then: perform)
        }
    }

    private static let discardFailure: LocalizedStringResource = LocalizedStringResource("failure.files.notDiscarded", defaultValue: "Changes not discarded", bundle: .module)

    /// Git has never seen an untracked file, so the sheet says plainly that it is gone for good.
    private func confirmDeletion(of path: String, then perform: @escaping () -> Void) {
        confirm(title: LocalizedStringResource("files.deleteUntracked.title", defaultValue: "Delete untracked File?", bundle: .module), names: RefString(marked: RefName.path(path)), then: perform)
    }

    /// The question comes as a sheet on the window; the destructive button is never the default, so Return does not discard, and Esc cancels too.
    private func confirm(title: LocalizedStringResource, names: RefString, text: LocalizedStringResource? = nil, then perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.setConfirmation(title, names: names, info: text)
        let discard = alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard", bundle: .module))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        cancel.keyEquivalent = "\r"
        prompter.confirmDiscard(alert, then: perform)
    }

    // MARK: Running

    private func run(failure: LocalizedStringResource = LocalizedStringResource("failure.files.indexNotChanged", defaultValue: "Index not changed", bundle: .module), _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        Task { [weak self] in
            do {
                try await operation(repository)
            } catch {
                self?.prompter.report(error, title: failure)
            }
            await self?.viewModel.refresh(note: nil)
            self?.onChange?()
        }
    }
}
