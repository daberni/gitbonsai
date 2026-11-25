import AppKit
import GitEngine

/// Squashes the selected commits into one: the multi-selection's menu entry and command, the sheet with the combined message, and the run through the interactive rebase so commits above are replayed and Undo works.
@MainActor
final class SquashUseCase {
    private let viewModel: GraphViewModel
    private let prompter: any Prompting
    private let interactiveRebase: InteractiveRebaseUseCase
    /// The commits selected in the history, in any order.
    var selectedCommitIDs: (() -> [String])?
    /// Beyond this many commits below HEAD the rule does not walk the history.
    private static let maximumDistance = 5000

    init(context: RepositoryContext, interactiveRebase: InteractiveRebaseUseCase) {
        viewModel = context.model
        prompter = context.prompter
        self.interactiveRebase = interactiveRebase
    }

    private static var title: LocalizedStringResource { LocalizedStringResource("rebase.squash.menu.title", defaultValue: "Squash Commits…", bundle: .module) }

    /// The entry for the menu of a row that belongs to a selection of several commits; nil otherwise.
    func menuItem(for commit: Commit) -> NSMenuItem? {
        let selected = selectedCommitIDs?() ?? []
        guard selected.count > 1, selected.contains(commit.id) else { return nil }
        if let blocker = blocker(for: selected) {
            let item = NSMenuItem(title: Self.title.text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = blocker.reason.text
            return item
        }
        return ActionMenuItem(Self.title) { [weak self] in self?.squash(selected) }
    }

    func blocker(for selected: [String]) -> CommandBlocker? {
        CommandRules.squash(commandState, selected: Set(selected), line: firstParentLine())
    }

    private var commandState: RepositoryCommandState {
        RepositoryCommandState(status: viewModel.status, remotes: [], stashCount: 0, operation: nil)
    }

    /// HEAD and its first parents as far as the history is loaded, newest first.
    private func firstParentLine() -> [(id: String, parentCount: Int)] {
        var line: [(id: String, parentCount: Int)] = []
        var next = viewModel.headSHA
        while let id = next, line.count < Self.maximumDistance, let row = viewModel.rowIndex(of: id) {
            let commit = viewModel.commits[row]
            line.append((id, commit.parents.count))
            next = commit.parents.first
        }
        return line
    }

    /// Plans the squash, asks for the message and runs it. Uncommitted changes are stashed for it and brought back.
    func squash(_ selected: [String]) {
        let repository = viewModel.repository
        let hasLocalChanges = viewModel.status?.entries.contains { !$0.isUntracked && !$0.isIgnored } ?? false
        Task {
            var plan: RebasePlan
            do {
                plan = try await repository.squashPlan(selected)
            } catch {
                let reason = (error as? RebasePlanError).map(InteractiveRebaseUseCase.describe)
                prompter.report(reason.map { GitError(arguments: [], exitCode: 0, stderr: $0) } ?? error, title: LocalizedStringResource("failure.squash.notPossible", defaultValue: "Squash not possible", bundle: .module))
                return
            }
            guard let oldest = plan.steps.first?.commit else { return }
            let count = selected.count
            let hint = await interactiveRebase.publishedHint(plan)
            let form = ActionForm(title: LocalizedStringResource("rebase.squash.sheet.title", defaultValue: "Squash \(count) Commits", bundle: .module), info: hint.map { .verbatim($0.plain) }, confirm: LocalizedStringResource("rebase.squash.sheet.confirm", defaultValue: "Squash", bundle: .module))
            form.addMessage(label: LocalizedStringResource("rebase.squash.sheet.message", defaultValue: "Message", bundle: .module), value: plan.messages[oldest.id] ?? "")
            sheet = form
            defer { sheet = nil }
            guard let values = await prompter.ask(form), let message = values.text[ActionForm.messageKey] else { return }
            plan.messages[oldest.id] = message.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.autostash = hasLocalChanges
            interactiveRebase.start(plan, note: CommitActions.note("git rebase -i (squash \(oldest.shortID) +\(count - 1))", hint))
        }
    }

    /// The sheet while it is open, for the harness.
    private(set) var sheet: ActionForm?
}

extension SquashUseCase: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        let selected = selectedCommitIDs?() ?? []
        let blocker = state.operation.map { CommandBlocker.operationInProgress($0) } ?? blocker(for: selected)
        let context = selected.count > 1 ? String(localized: "common.commitCount", defaultValue: "\(selected.count) commits", bundle: .module) : nil
        return [Command(.squash, context: context, blocker: blocker) { [weak self] in self?.squash(selected) }]
    }
}
