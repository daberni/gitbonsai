import AppKit
import GitEngine

/// The commands of a repository tab: those its controllers register, and the ones that belong to the tab as a whole (commit form, worktree, search, opening the folder elsewhere).
extension RepositoryViewController: CommandProvider {
    var commandState: RepositoryCommandState {
        RepositoryCommandState(status: viewModel.status, remotes: fetchController.remotes, stashCount: viewModel.stashes.count, operation: operationBanner.progress?.kind)
    }

    private var commandProviders: [CommandProvider] {
        [fetchController, pullPush, checkoutController, sidebarActions, stashesController, staging, commitActions.interactiveRebase, operationBanner]
    }

    /// Every repository command, in the order the empty bar lists them.
    func allCommands() -> [Command] {
        let state = commandState
        let providers = commandProviders.flatMap { $0.commands(state) }
        return providers + commands(state)
    }

    func commands(_ state: RepositoryCommandState) -> [Command] {
        commitCommands(state) + worktreeCommands(state) + openCommands() + copyCommands(state) + viewCommands()
    }

    // MARK: View

    private func viewCommands() -> [Command] {
        // Each title on its own: the compiler extracts only the first branch of a conditional expression into the String Catalog.
        let sidebarTitle: LocalizedStringResource
        if split.showsSidebar { sidebarTitle = "Hide sidebar" } else { sidebarTitle = "Show sidebar" }
        let detailTitle: LocalizedStringResource
        if split.showsDetail { detailTitle = "Hide detail panel" } else { detailTitle = "Show detail panel" }
        return [
            Command(.toggleSidebar, title: sidebarTitle) { [weak self] in self?.split.toggleSidebar() },
            Command(.toggleDetail, title: detailTitle) { [weak self] in self?.split.toggleDetail() },
        ]
    }

    // MARK: Commit form

    private func commitCommands(_ state: RepositoryCommandState) -> [Command] {
        [
            Command(.commit, context: state.stagedCount > 0 ? String(localized: "\(state.stagedCount) staged", bundle: .module, comment: "Count of staged files after the Commit command.") : nil, blocker: CommandRules.commit(state)) { [weak self] in self?.showCommitForm(amend: false) },
            Command(.amend, blocker: CommandRules.amend(state)) { [weak self] in self?.showCommitForm(amend: true) },
            Command(.editMessage, context: selectedCommitForMessage?.shortID, disabledReason: editMessageReason) { [weak self] in self?.editSelectedCommitMessage() },
        ]
    }

    /// Selects the working directory so the commit form shows, and puts the cursor into its subject; amend ticks the box and loads the last message.
    private func showCommitForm(amend: Bool) {
        if let row = viewModel.currentRow { history.select(row: row, scroll: true) }
        if amend { commitController.beginAmend() }
        commitController.form.focusSubject()
    }

    // MARK: Worktrees and search

    private func worktreeCommands(_ state: RepositoryCommandState) -> [Command] {
        let others = viewModel.worktrees.map(\.worktree).filter { !viewModel.isCurrent($0) && !$0.isBare && !$0.isPrunable }
        let current = (repositoryPath as NSString).lastPathComponent
        return [
            Command(.switchWorktree, context: current, disabledReason: others.isEmpty ? "No other worktree" : nil, action: .choose(placeholder: "Search worktrees") { [weak self] in
                others.map { worktree in
                    let folder = (worktree.path as NSString).lastPathComponent
                    return Command(id: worktree.path, title: .verbatim(folder), glyph: .glyph(worktree.isMain ? .bonsaiMain : .bonsaiLinked), context: worktree.branch ?? String(localized: "Detached HEAD", bundle: .module)) { self?.onSwitchWorktree?(worktree.path) }
                }
            }),
            Command(.search) { [weak self] in
                guard let self else { return }
                view.window?.makeFirstResponder(toolbar.searchField)
            },
        ]
    }

    // MARK: Elsewhere

    private func openCommands() -> [Command] {
        let folder = URL(fileURLWithPath: repositoryPath, isDirectory: true)
        let name = (repositoryPath as NSString).lastPathComponent
        let terminal = ExternalApps.terminal()
        let editor = ExternalApps.editor(forRepository: repositoryPath)
        return [
            Command(.openTerminal, keywords: [terminal?.app.name].compactMap { $0 }, context: terminal.map { "\(name) · \($0.app.name)" }, disabledReason: terminal == nil ? "No terminal found" : nil) {
                ExternalApps.openInTerminal(folder)
            },
            Self.chooseApp(.chooseTerminal, kind: .terminal, folder: folder, context: name, preferred: terminal),
            Command(.openEditor, keywords: [editor?.app.name].compactMap { $0 }, context: editor.map { "\(name) · \($0.app.name)" }, disabledReason: editor == nil ? "No editor found" : nil) {
                guard let editor else { return }
                ExternalApps.open(folder, in: editor.app, at: editor.url)
            },
            Self.chooseApp(.chooseEditor, kind: .editor, folder: folder, context: name, preferred: editor),
            Command(.revealInFinder, context: name) {
                if ScreenshotHarness.isActive { return ScreenshotHarness.reportOpening("Finder", "reveal \(folder.path)") }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            },
        ]
    }

    /// "Open in editor with…" and "Open in terminal with…": the apps checked in the settings, the default marked.
    private static func chooseApp(_ spec: CommandSpec, kind: ExternalApps.Kind, folder: URL, context: String, preferred: ExternalApps.Choice?) -> Command {
        let shown = ExternalApps.shown(kind)
        let none: LocalizedStringResource = kind == .editor ? "No editor found" : "No terminal found"
        let placeholder: LocalizedStringResource = kind == .editor ? "Search editors" : "Search terminals"
        return Command(spec, keywords: shown.map(\.app.name), context: context, disabledReason: shown.isEmpty ? none : nil, action: .choose(placeholder: placeholder) {
            shown.map { choice in
                Command(id: choice.app.bundleID, title: .verbatim(choice.app.name), glyph: .app(choice.url), context: choice.app.bundleID == preferred?.app.bundleID ? String(localized: "Default", bundle: .module, comment: "Marks the default app in the list of editors or terminals.") : nil) {
                    ExternalApps.open(folder, in: choice.app, at: choice.url)
                }
            }
        })
    }

    private func copyCommands(_ state: RepositoryCommandState) -> [Command] {
        [
            Command(.copyBranch, context: state.branch, blocker: CommandRules.copyBranchName(state)) {
                if let branch = state.branch { ActionRunner.copy(branch) }
            },
            Command(.copyHead, context: state.headSHA.map { String($0.prefix(7)) }, blocker: CommandRules.copyHead(state)) {
                if let sha = state.headSHA { ActionRunner.copy(sha) }
            },
        ]
    }
}
