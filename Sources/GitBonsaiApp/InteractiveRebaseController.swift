import AppKit
import GitEngine

/// The commit menu's interactive rebase: the sheet onto any commit, and its one-step forms (edit message, drop, move up, move down) with their questions. Editing the message hands over to the detail panel.
/// One-step entries are disabled, with the reason as tooltip, where git would have to flatten a merge, where there is no parent to start from, and for commits off the current branch's line.
@MainActor
final class InteractiveRebaseController {
    enum RewordAccess: Equatable {
        case allowed
        case disabled(String)
    }

    let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    /// The sheet while it is open, for the harness.
    private(set) var sheet: InteractiveRebaseSheet?
    /// The rebase finished without stopping.
    var onEnded: (() -> Void)?
    /// "Edit Message" was chosen; the message is edited in place in the detail panel.
    var onReword: ((Commit) -> Void)?
    /// Beyond this many commits below HEAD the menu does not walk the history and offers nothing.
    private static let maximumDistance = 5000

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
    }

    // MARK: Menu

    func menuItems(for commit: Commit) -> [NSMenuItem] {
        guard let branch = viewModel.currentBranch, viewModel.headSHA != nil else { return [] }
        let line = firstParentLine(to: commit.id)
        let reason = line == nil ? Self.offLineReason(branch) : nil
        let ownRangeHasMerge = line.map { $0.contains { $0.parents.count > 1 } } ?? false
        let isHead = commit.id == viewModel.headSHA
        let parent = commit.parents.first.flatMap { viewModel.rowIndex(of: $0) }.map { viewModel.commits[$0] }

        let ownStep = reason ?? (commit.parents.isEmpty ? Self.rootReason : ownRangeHasMerge ? Self.mergeReason : nil)
        let up = ownStep ?? (isHead ? String(localized: "Already the topmost commit", bundle: .module) : nil)
        let down = ownStep ?? (parent == nil ? String(localized: "The commit below is not loaded", bundle: .module) : parent!.parents.isEmpty ? String(localized: "Only the repository’s first commit lies below", bundle: .module) : parent!.parents.count > 1 ? Self.mergeReason : nil)

        let reword = item("Edit Message", disabledBecause: ownStep) { [weak self] in self?.onReword?(commit) }
        reword.keyEquivalent = CommandShortcut.editMessage.key
        reword.keyEquivalentModifierMask = CommandShortcut.editMessage.modifiers
        return [
            reword,
            item("Move up", disabledBecause: up) { [weak self] in self?.singleStep(.moveUp, commit, branch: branch) },
            item("Move down", disabledBecause: down) { [weak self] in self?.singleStep(.moveDown, commit, branch: branch) },
            item("Drop Commit…", disabledBecause: ownStep) { [weak self] in self?.singleStep(.drop, commit, branch: branch) },
        ]
    }

    /// Whether the message of `commit` can be edited: nil for commits off the current branch's line, where the detail panel offers nothing, otherwise the reason it cannot, or `.allowed`.
    func rewordAccess(for commit: Commit) -> RewordAccess? {
        guard viewModel.currentBranch != nil, viewModel.headSHA != nil, let line = firstParentLine(to: commit.id) else { return nil }
        if commit.parents.isEmpty { return .disabled(Self.rootReason) }
        return line.contains { $0.parents.count > 1 } ? .disabled(Self.mergeReason) : .allowed
    }

    /// Why an in-place rebase from `commit`, an ancestor of HEAD, is not offered; nil when it is.
    func inPlaceReason(for commit: Commit) -> String? {
        guard let line = firstParentLine(to: commit.id) else { return Self.offLineReason(viewModel.currentBranch ?? "HEAD") }
        if commit.id == viewModel.headSHA { return String(localized: "Nothing lies above this commit", bundle: .module) }
        return line.dropLast().contains { $0.parents.count > 1 } ? Self.mergeReason : nil
    }

    private static var mergeReason: String { String(localized: "A merge lies in between", bundle: .module) }
    private static var rootReason: String { String(localized: "The repository’s first commit has no parent", bundle: .module) }

    private static func offLineReason(_ branch: String) -> String {
        String(localized: "Not on the line of \(branch)", bundle: .module, comment: "Tooltip of a disabled rebase entry: the commit is not on the first-parent line of this branch.")
    }

    private func item(_ title: LocalizedStringResource, disabledBecause reason: String?, _ handler: @escaping () -> Void) -> NSMenuItem {
        guard let reason else { return ActionMenuItem(title, handler: handler) }
        let item = NSMenuItem(title: title.text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = reason
        return item
    }

    /// HEAD and its first parents down to `target`, both included; nil when `target` is not on that line within reach of the loaded history.
    private func firstParentLine(to target: String) -> [Commit]? {
        guard var id = viewModel.headSHA else { return nil }
        var line: [Commit] = []
        while line.count < Self.maximumDistance, let row = viewModel.rowIndex(of: id) {
            let commit = viewModel.commits[row]
            line.append(commit)
            if id == target { return line }
            guard let parent = commit.parents.first else { return nil }
            id = parent
        }
        return nil
    }

    // MARK: Sheet

    /// Opens the sheet for a rebase of `branch` onto `target`: in place on an ancestor of HEAD, otherwise from the detected base, which the sheet can change.
    func openSheet(branch: String, onto target: Commit, targetName: RefString, detection: RebaseBaseDetection) {
        let repository = viewModel.repository
        let hasLocalChanges = viewModel.status?.entries.contains { !$0.isUntracked && !$0.isIgnored } ?? false
        let upstream = viewModel.status?.branch.upstream
        Task {
            do {
                let range = try await repository.rebaseRange(onto: target.id, detection: detection)
                guard let base = await repository.rebaseCommit(range.base), let targetCommit = await repository.rebaseCommit(target.id) else { throw RebasePlanError.baseNotInHistory }
                let branches = await repository.stackedBranches(in: range.commits)
                let published = await repository.publishedCommitCount(rewrittenBy: range.base)
                let model = InteractiveRebaseModel(branch: branch, range: range, base: base, target: targetCommit, targetName: targetName, branches: branches, published: published, hasLocalChanges: hasLocalChanges)
                let suggestions = await Self.suggestions(of: detection, range: range, target: target.id, targetName: targetName, in: repository)
                let tips = ((try? await repository.refTips()) ?? []).filter { !($0.kind == .localBranch && $0.name == branch) }
                let picker = RebaseBasePicker(base: suggestions.initial, target: RefString("\(targetName.marked) · \(RefName.commit(targetCommit.id)) “\(targetCommit.subject)”"), catalog: RefCatalog(tips: tips, current: suggestions.items), repository: repository, note: Self.note(for: detection, range: range))
                // The sheet owns the picker and goes away when it closes, which ends this reference to the controller.
                picker.changeBase = { [weak model] revision in
                    guard let model else { return nil }
                    return await self.changeBase(of: model, to: revision, onto: target.id)
                }
                let sheet = InteractiveRebaseSheet(model: model, basePicker: picker)
                sheet.publishedHint = { CommitActionsController.publishedHint($0, upstream: upstream) }
                guard let window = prompter.window?() else { return }
                self.sheet = sheet
                ScreenshotHarness.driveRebaseSheet(sheet)
                let plan = await sheet.run(on: window)
                self.sheet = nil
                guard let plan else { return }
                if plan.dropsEverything {
                    let confirmed = await ActionRunner(viewModel: viewModel, prompter: prompter).confirm("Drop all commits?", info: "\(RefName.branch(branch)) will be reset to \(RefName.commit(model.targetCommit.id)) “\(model.targetCommit.subject)”. Undo from the status line.", button: "Drop Commits")
                    guard confirmed else { return }
                }
                let hint = CommitActionsController.publishedHint(model.published, upstream: upstream)
                start(plan, note: CommitActionsController.note(Self.command(plan), hint))
            } catch {
                report(error, title: "Interactive rebase not possible")
            }
        }
    }

    /// "git rebase -i 1a2b3c4" in place, "git rebase -i --onto 4d5e6f7 1a2b3c4" otherwise.
    static func command(_ plan: RebasePlan) -> String {
        plan.onto.map { "git rebase -i --onto \($0.prefix(7)) \(plan.base.prefix(7))" } ?? "git rebase -i \(plan.base.prefix(7))"
    }

    /// Loads the range from another old base into the open sheet; returns why it cannot.
    private func changeBase(of model: InteractiveRebaseModel, to revision: String, onto target: String) async -> String? {
        let repository = viewModel.repository
        guard let base = await repository.rebaseCommit(revision) else { return String(localized: "“\(revision)” is not a commit", bundle: .module) }
        do {
            let range = try await repository.rebaseRange(from: base.id, onto: target)
            let branches = await repository.stackedBranches(in: range.commits)
            let published = await repository.publishedCommitCount(rewrittenBy: range.base)
            model.replace(range: range, base: base, branches: branches, published: published)
            return range.isInPlace ? Self.inPlaceNote : nil
        } catch let error as RebasePlanError {
            return Self.describe(error)
        } catch {
            return "\(error)"
        }
    }

    /// The bases the picker suggests: the detected ones described by why they were found, then the merge base; `initial` is the base the range starts from, listed among them.
    private static func suggestions(of detection: RebaseBaseDetection, range: RebaseRange, target: String, targetName: RefString, in repository: Repository) async -> (items: [RefCatalog.Item], initial: RefCatalog.Item) {
        var items: [RefCatalog.Item] = []
        if !range.isInPlace {
            let bases: [RebaseBase] = switch detection {
            case .detected(let base): [base]
            case .tie(let bases): bases
            case .plain: []
            }
            for base in bases {
                if let commit = await repository.commitSummary(base.commit) { items.append(.commit(commit, note: RebaseOntoController.without(base.reason).plain)) }
            }
            if let mergeBase = await repository.mergeBase(target, "HEAD"), !items.contains(where: { $0.revision == mergeBase }), let commit = await repository.commitSummary(mergeBase) {
                items.append(.commit(commit, note: String(localized: "merge base", bundle: .module, comment: "Why the base picker offers a commit: it is the merge base.")))
            }
        }
        if let initial = items.first(where: { $0.revision == range.base }) { return (items, initial) }
        let commit = await repository.commitSummary(range.base) ?? CommitSummary(sha: range.base, date: Date(), subject: "")
        let initial = RefCatalog.Item.commit(commit, note: range.isInPlace ? targetName.plain : nil)
        return ([initial] + items, initial)
    }

    private static func note(for detection: RebaseBaseDetection, range: RebaseRange) -> String {
        if range.isInPlace { return inPlaceNote }
        return switch detection {
        case .detected: String(localized: "detected", bundle: .module, comment: "Next to the old base of an interactive rebase: the app found it.")
        case .tie: String(localized: "ambiguous: please check the base", bundle: .module)
        case .plain: String(localized: "merge base, nothing better detected", bundle: .module)
        }
    }

    private static var inPlaceNote: String {
        String(localized: "in place", bundle: .module, comment: "Next to the old base of an interactive rebase: the commits stay on their base and only the list is edited.")
    }

    // MARK: Single steps

    private func singleStep(_ step: RebaseSingleStep, _ commit: Commit, branch: String) {
        let repository = viewModel.repository
        Task {
            do {
                let plan = try await repository.singleStepPlan(step, commit: commit.id)
                let hint = await publishedHint(plan)
                // Only dropping asks: it takes the commit's changes out of the branch. Moving is undone from the status line.
                if step == .drop {
                    let alert = NSAlert()
                    alert.setText(RefString("Drop \(RefName.commit(commit.id)) “\(commit.subject)”?"), info: Self.rewriteNote(plan, branch: branch, hint: hint))
                    alert.addButton(withTitle: String(localized: "Drop Commit", bundle: .module))
                    alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
                    alert.buttons.first?.hasDestructiveAction = true
                    guard await prompter.confirm(alert) else { return }
                }
                // The status line names the step inside the command; drop is git's own todo verb.
                let verb = switch step {
                case .drop: "drop"
                case .moveUp: String(localized: "move up", bundle: .module, comment: "Status line, inside “git rebase -i (move up 1a2b3c4)”: the commit was moved up one step.")
                default: String(localized: "move down", bundle: .module, comment: "Status line, inside “git rebase -i (move down 1a2b3c4)”: the commit was moved down one step.")
                }
                start(plan, note: CommitActionsController.note("git rebase -i (\(verb) \(commit.shortID))", hint))
            } catch {
                report(error, title: "Rebase not possible")
            }
        }
    }

    /// "Rewrites 3 commits of main. Undo from the status line." and the hint about published commits, each its own paragraph.
    private static func rewriteNote(_ plan: RebasePlan, branch: String, hint: RefString?) -> RefString {
        let count = plan.steps.count
        let note = RefString("Rewrites \(count) commits of \(RefName.branch(branch)). Undo from the status line.")
        return RefString(marked: ([note] + [hint].compactMap { $0 }).map(\.marked).joined(separator: "\n\n"))
    }

    private func publishedHint(_ plan: RebasePlan) async -> RefString? {
        CommitActionsController.publishedHint(await viewModel.repository.publishedCommitCount(rewrittenBy: plan.base), upstream: viewModel.status?.branch.upstream)
    }

    // MARK: Running

    /// Runs the plan. An `edit` stop or a conflict leaves the banner to say what comes next; a failed command is also reported.
    func start(_ plan: RebasePlan, note: String) {
        let repository = viewModel.repository
        Task {
            do {
                let outcome = try await repository.startInteractiveRebase(plan)
                await viewModel.refresh(note: note)
                switch outcome {
                case .finished:
                    onEnded?()
                case let .stopped(progress, output):
                    // A conflict or an edit stop is a state the banner shows; only a failed command is worth a message.
                    if case let .exec(command)? = progress.stop {
                        prompter.report(GitError(arguments: ["rebase"], exitCode: 1, stderr: output), title: "“\(command)” failed, rebase stopped")
                    }
                }
            } catch {
                await viewModel.refresh(note: nil)
                report(error, title: "Rebase failed")
            }
        }
    }

    private func report(_ error: Error, title: LocalizedStringResource) {
        guard let planError = error as? RebasePlanError else { return prompter.report(error, title: title) }
        prompter.report(GitError(arguments: [], exitCode: 0, stderr: Self.describe(planError)), title: title)
    }

    static func describe(_ error: RebasePlanError) -> String {
        switch error {
        case .baseNotInHistory: String(localized: "The commit is not in the history of the current branch.", bundle: .module)
        case .mergeInRange: String(localized: "A merge lies between the commit and HEAD; an interactive rebase would flatten it.", bundle: .module)
        case .nothingToRebase: String(localized: "Nothing lies above this commit that could be rewritten.", bundle: .module)
        case .notOnCurrentBranch: String(localized: "The commit is not on the line of the current branch.", bundle: .module)
        case .rootCommit: String(localized: "The repository’s first commit has no parent the rebase could start from.", bundle: .module)
        case .nothingAbove: String(localized: "No commit lies above this one to swap with.", bundle: .module)
        case let .invalidPlan(.nothingToFoldInto(commit)): String(localized: "\(commit.shortID) has no commit above it to fold into.", bundle: .module)
        case let .invalidPlan(.emptyMessage(commit)): String(localized: "The commit from \(commit.shortID) needs a message.", bundle: .module)
        }
    }
}
