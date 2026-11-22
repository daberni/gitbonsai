import AppKit
import GitEngine

/// The commit menu's interactive rebase: the sheet onto any commit, and its one-step forms (edit message, drop, move up, move down) with their questions.
/// One-step entries are disabled, with the reason as tooltip, where git would have to flatten a merge, where there is no parent to start from, and for commits off the current branch's line.
@MainActor
final class InteractiveRebaseController {
    private let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    /// The sheet while it is open, for the harness.
    private(set) var sheet: InteractiveRebaseSheet?
    /// The rebase finished without stopping.
    var onEnded: (() -> Void)?
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
        let reason = line == nil ? "Liegt nicht auf der Linie von „\(branch)“" : nil
        let ownRangeHasMerge = line.map { $0.contains { $0.parents.count > 1 } } ?? false
        let isHead = commit.id == viewModel.headSHA
        let parent = commit.parents.first.flatMap { viewModel.rowIndex(of: $0) }.map { viewModel.commits[$0] }

        let ownStep = reason ?? (commit.parents.isEmpty ? Self.rootReason : ownRangeHasMerge ? Self.mergeReason : nil)
        let up = ownStep ?? (isHead ? "Ist schon der oberste Commit" : nil)
        let down = ownStep ?? (parent == nil ? "Der Commit darunter ist nicht geladen" : parent!.parents.isEmpty ? "Darunter liegt nur der erste Commit des Repositorys" : parent!.parents.count > 1 ? Self.mergeReason : nil)

        return [
            item("Nachricht bearbeiten …", disabledBecause: ownStep) { [weak self] in self?.reword(commit, branch: branch) },
            item("Nach oben verschieben", disabledBecause: up) { [weak self] in self?.singleStep(.moveUp, commit, branch: branch) },
            item("Nach unten verschieben", disabledBecause: down) { [weak self] in self?.singleStep(.moveDown, commit, branch: branch) },
            item("Commit verwerfen …", disabledBecause: ownStep) { [weak self] in self?.singleStep(.drop, commit, branch: branch) },
        ]
    }

    /// Why an in-place rebase from `commit`, an ancestor of HEAD, is not offered; nil when it is.
    func inPlaceReason(for commit: Commit) -> String? {
        guard let line = firstParentLine(to: commit.id) else { return "Liegt nicht auf der Linie von „\(viewModel.currentBranch ?? "HEAD")“" }
        if commit.id == viewModel.headSHA { return "Über diesem Commit liegt nichts" }
        return line.dropLast().contains { $0.parents.count > 1 } ? Self.mergeReason : nil
    }

    private static let mergeReason = "Dazwischen liegt ein Merge"
    private static let rootReason = "Der erste Commit des Repositorys hat keinen Vorgänger"

    private func item(_ title: String, disabledBecause reason: String?, _ handler: @escaping () -> Void) -> NSMenuItem {
        guard let reason else { return ActionMenuItem(title, handler: handler) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
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
    func openSheet(branch: String, onto target: Commit, targetName: String, detection: RebaseBaseDetection) {
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
                let picker = RebaseBasePicker(base: suggestions.initial, target: "\(targetName) · \(targetCommit.shortID) „\(targetCommit.subject)“", catalog: RefCatalog(tips: tips, current: suggestions.items), repository: repository, note: Self.note(for: detection, range: range))
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
                    let confirmed = await ActionRunner(viewModel: viewModel, prompter: prompter).confirm("Alle Commits verwerfen?", info: "„\(branch)“ wird auf \(model.targetCommit.shortID) „\(model.targetCommit.subject)“ zurückgesetzt. Rückgängig über die Statuszeile.", button: "Verwerfen")
                    guard confirmed else { return }
                }
                let hint = CommitActionsController.publishedHint(model.published, upstream: upstream)
                start(plan, note: CommitActionsController.note(Self.command(plan), hint))
            } catch {
                report(error, title: "Interaktives Rebase nicht möglich")
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
        guard let base = await repository.rebaseCommit(revision) else { return "„\(revision)“ ist kein Commit" }
        do {
            let range = try await repository.rebaseRange(from: base.id, onto: target)
            let branches = await repository.stackedBranches(in: range.commits)
            let published = await repository.publishedCommitCount(rewrittenBy: range.base)
            model.replace(range: range, base: base, branches: branches, published: published)
            return range.isInPlace ? "an Ort und Stelle" : nil
        } catch let error as RebasePlanError {
            return Self.describe(error)
        } catch {
            return "\(error)"
        }
    }

    /// The bases the picker suggests: the detected ones described by why they were found, then the merge base; `initial` is the base the range starts from, listed among them.
    private static func suggestions(of detection: RebaseBaseDetection, range: RebaseRange, target: String, targetName: String, in repository: Repository) async -> (items: [RefCatalog.Item], initial: RefCatalog.Item) {
        var items: [RefCatalog.Item] = []
        if !range.isInPlace {
            let bases: [RebaseBase] = switch detection {
            case .detected(let base): [base]
            case .tie(let bases): bases
            case .plain: []
            }
            for base in bases {
                if let commit = await repository.commitSummary(base.commit) { items.append(.commit(commit, note: RebaseOntoController.without(base.reason))) }
            }
            if let mergeBase = await repository.mergeBase(target, "HEAD"), !items.contains(where: { $0.revision == mergeBase }), let commit = await repository.commitSummary(mergeBase) {
                items.append(.commit(commit, note: "Merge-Base"))
            }
        }
        if let initial = items.first(where: { $0.revision == range.base }) { return (items, initial) }
        let commit = await repository.commitSummary(range.base) ?? CommitSummary(sha: range.base, date: Date(), subject: "")
        let initial = RefCatalog.Item.commit(commit, note: range.isInPlace ? targetName : nil)
        return ([initial] + items, initial)
    }

    private static func note(for detection: RebaseBaseDetection, range: RebaseRange) -> String {
        if range.isInPlace { return "an Ort und Stelle" }
        return switch detection {
        case .detected: "erkannt"
        case .tie: "mehrdeutig: bitte die Basis prüfen"
        case .plain: "Merge-Base, nichts Besseres erkannt"
        }
    }

    // MARK: Single steps

    private func reword(_ commit: Commit, branch: String) {
        let repository = viewModel.repository
        Task {
            do {
                var plan = try await repository.singleStepPlan(.reword(""), commit: commit.id)
                let original = plan.steps[0].commit?.message ?? commit.subject
                let hint = await publishedHint(plan)
                let form = ActionForm(title: "Nachricht von \(commit.shortID) bearbeiten", info: Self.rewriteNote(plan, branch: branch, hint: hint), confirm: "Ändern")
                form.addMessage(label: "Nachricht", value: original)
                guard let values = await prompter.ask(form), let message = values.text[ActionForm.messageKey]?.trimmingCharacters(in: .whitespacesAndNewlines), message != original else { return }
                plan.messages[commit.id] = message
                start(plan, note: CommitActionsController.note("git rebase -i (reword \(commit.shortID))", hint))
            } catch {
                report(error, title: "Nachricht nicht geändert")
            }
        }
    }

    private func singleStep(_ step: RebaseSingleStep, _ commit: Commit, branch: String) {
        let repository = viewModel.repository
        Task {
            do {
                let plan = try await repository.singleStepPlan(step, commit: commit.id)
                let hint = await publishedHint(plan)
                // Only dropping asks: it takes the commit's changes out of the branch. Moving is undone from the status line.
                if step == .drop {
                    let alert = NSAlert()
                    alert.messageText = "\(commit.shortID) „\(commit.subject)“ verwerfen?"
                    alert.informativeText = Self.rewriteNote(plan, branch: branch, hint: hint)
                    alert.addButton(withTitle: "Verwerfen")
                    alert.addButton(withTitle: "Abbrechen")
                    alert.buttons.first?.hasDestructiveAction = true
                    guard await prompter.confirm(alert) else { return }
                }
                let verb = switch step {
                case .drop: "drop"
                case .moveUp: "nach oben"
                default: "nach unten"
                }
                start(plan, note: CommitActionsController.note("git rebase -i (\(verb) \(commit.shortID))", hint))
            } catch {
                report(error, title: "Rebase nicht möglich")
            }
        }
    }

    /// "Schreibt 3 Commits von „main“ neu. Rückgängig über die Statuszeile." and the hint about published commits.
    private static func rewriteNote(_ plan: RebasePlan, branch: String, hint: String?) -> String {
        let count = plan.steps.count
        return (["Schreibt \(count == 1 ? "1 Commit" : "\(count) Commits") von „\(branch)“ neu. Rückgängig über die Statuszeile."] + [hint].compactMap { $0 }).joined(separator: "\n\n")
    }

    private func publishedHint(_ plan: RebasePlan) async -> String? {
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
                        prompter.report(GitError(arguments: ["rebase"], exitCode: 1, stderr: output), title: "„\(command)“ fehlgeschlagen, Rebase angehalten")
                    }
                }
            } catch {
                await viewModel.refresh(note: nil)
                report(error, title: "Rebase fehlgeschlagen")
            }
        }
    }

    private func report(_ error: Error, title: String) {
        guard let planError = error as? RebasePlanError else { return prompter.report(error, title: title) }
        prompter.report(GitError(arguments: [], exitCode: 0, stderr: Self.describe(planError)), title: title)
    }

    static func describe(_ error: RebasePlanError) -> String {
        switch error {
        case .baseNotInHistory: "Der Commit liegt nicht in der Historie des aktuellen Branches."
        case .mergeInRange: "Zwischen dem Commit und HEAD liegt ein Merge; ein interaktives Rebase würde ihn flach machen."
        case .nothingToRebase: "Über diesem Commit liegt nichts, das neu geschrieben werden könnte."
        case .notOnCurrentBranch: "Der Commit liegt nicht auf der Linie des aktuellen Branches."
        case .rootCommit: "Der erste Commit des Repositorys hat keinen Vorgänger, ab dem das Rebase beginnen könnte."
        case .nothingAbove: "Über diesem Commit liegt keiner, mit dem er tauschen könnte."
        case let .invalidPlan(.nothingToFoldInto(commit)): "\(commit.shortID) hat keinen Commit über sich, in den er aufgehen könnte."
        case let .invalidPlan(.emptyMessage(commit)): "Der Commit aus \(commit.shortID) braucht eine Nachricht."
        }
    }
}
