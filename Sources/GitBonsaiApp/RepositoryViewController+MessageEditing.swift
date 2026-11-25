import AppKit
import GitEngine

/// Editing a commit message in place, and amending at an edit stop.
extension RepositoryViewController {
    // MARK: Message editing

    /// The one commit selected, when it is a commit and not the working directory or a stash.
    var selectedCommitForMessage: Commit? {
        guard let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .commit || viewModel.kinds[row] == .merge else { return nil }
        return viewModel.commits[row]
    }

    /// Why ⌘E cannot edit the selected commit's message right now; nil when it can.
    var editMessageReason: LocalizedStringResource? {
        guard let commit = selectedCommitForMessage else { return LocalizedStringResource("commit.editDisabled.noSelection", defaultValue: "No commit selected", bundle: .module) }
        if inlineReword.isEditing { return LocalizedStringResource("commit.editDisabled.alreadyEditing", defaultValue: "Already being edited", bundle: .module) }
        switch commitActions.interactiveRebase.rewordAccess(for: commit) {
        case .allowed: return nil
        case let .disabled(reason): return .verbatim(reason)
        case nil: return viewModel.currentBranch.map { LocalizedStringResource("commit.editDisabled.notInHistory", defaultValue: "Not in the history of \($0)", bundle: .module) } ?? LocalizedStringResource("common.detachedHead", defaultValue: "Detached HEAD", bundle: .module)
        }
    }

    func editSelectedCommitMessage() {
        guard let commit = selectedCommitForMessage else { return NSSound.beep() }
        inlineReword.begin(commit)
    }

    /// From the commit menu the commit may not be the selected one; it is selected first, so the panel shows it.
    func editMessage(of commit: Commit) {
        if selectedCommitForMessage?.id != commit.id { history.navigate(to: commit.id) }
        inlineReword.begin(commit)
    }

    /// The focus goes back to the history. After a reword the panel shows the selected commit afresh, so no editor of a commit that is gone stays open.
    func messageEditingClosed() {
        if detail.messageEditor != nil {
            shownSelection = nil
            selectionChanged(to: history.selectedRows)
        }
        view.window?.makeFirstResponder(history.tableView)
    }

    /// At an edit stop the commit form amends the stopped commit: shown under the working directory, or under HEAD while nothing changed.
    func amendAtEditStop() {
        guard let row = viewModel.currentRow else { return }
        history.select(row: row, scroll: true)
        rightColumn.showsBar = true
        commitUseCase.beginAmend()
    }
}
