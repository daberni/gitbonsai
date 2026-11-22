import Foundation
import GitEngine

/// The state the interactive rebase sheet edits: the plan from the old base onto the target, the commits as they were, and what each row shows.
/// The old base can change while the sheet is open; the list then starts over with the new range.
@MainActor
final class InteractiveRebaseModel {
    let branch: String
    /// The commit the steps land on, and how the sheet names it: „main“ or a short SHA.
    let targetCommit: RebaseCommit
    let targetName: String
    let hasLocalChanges: Bool
    private(set) var range: RebaseRange
    private(set) var baseCommit: RebaseCommit
    private(set) var original: [RebaseCommit]
    /// Commits of the range that are already in the upstream.
    private(set) var published: Int
    private(set) var plan: RebasePlan
    var onChange: (() -> Void)?
    /// The range was replaced: the rows are new.
    var onReload: (() -> Void)?

    init(branch: String, range: RebaseRange, base: RebaseCommit, target: RebaseCommit, targetName: String, branches: [String: [String]], published: Int, hasLocalChanges: Bool) {
        self.branch = branch
        self.targetCommit = target
        self.targetName = targetName
        self.hasLocalChanges = hasLocalChanges
        self.range = range
        self.baseCommit = base
        self.original = range.commits
        self.published = published
        var plan = RebasePlan(range: range, branches: branches)
        plan.autostash = hasLocalChanges
        self.plan = plan
    }

    /// Starts over from another old base; the options stay as chosen.
    func replace(range: RebaseRange, base: RebaseCommit, branches: [String: [String]], published: Int) {
        var plan = RebasePlan(range: range, branches: branches)
        plan.autostash = self.plan.autostash
        if !branches.isEmpty, !self.plan.branches.isEmpty { plan.updateRefs = self.plan.updateRefs }
        self.range = range
        self.baseCommit = base
        self.original = range.commits
        self.published = published
        self.plan = plan
        onReload?()
        changed()
    }

    /// The steps stay on their base and only the list is edited, as `git rebase -i <base>` does.
    var isInPlace: Bool { range.isInPlace }

    func isAlreadyOnTarget(_ index: Int) -> Bool {
        plan.steps[index].commit.map { range.alreadyOnTarget.contains($0.id) } ?? false
    }

    /// A rebase onto another commit rewrites the branch even with an unchanged list.
    var canStart: Bool { plan.problem == nil && (plan.movesBase || !isUnchanged) }

    var steps: [RebaseStep] { plan.steps }
    var hasStackedBranches: Bool { !plan.branches.isEmpty }

    // MARK: Editing

    func setAction(_ action: RebaseAction, at index: Int) {
        guard plan.steps.indices.contains(index), plan.steps[index].action != action else { return }
        plan.steps[index].action = action
        changed()
    }

    /// Moves the step at `index` so it lands before the step now at `destination`; `destination == steps.count` puts it last. Returns the new index.
    @discardableResult
    func move(from index: Int, to destination: Int) -> Int {
        guard plan.steps.indices.contains(index), (0...plan.steps.count).contains(destination) else { return index }
        let target = destination > index ? destination - 1 : destination
        guard target != index else { return index }
        let step = plan.steps.remove(at: index)
        plan.steps.insert(step, at: target)
        changed()
        return target
    }

    /// The message of the commit the step at `index` ends up in; a message equal to git's own proposal is not stored.
    func setMessage(_ message: String, forGroupOf index: Int) {
        guard let head = groupHead(of: index)?.commit else { return }
        let group = plan.groups.first { $0.first?.commit?.id == head.id } ?? []
        let proposal = RebasePlan.defaultMessage(of: group)
        let stored = message == proposal ? nil : message
        guard plan.messages[head.id] != stored else { return }
        plan.messages[head.id] = stored
        changed()
    }

    /// Replaces the first line of the group's message, as the subject field of a reword row does.
    func setSubject(_ subject: String, at index: Int) {
        let current = message(forGroupOf: index) ?? ""
        let rest = current.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map { "\n" + $0 } ?? ""
        setMessage(subject + rest, forGroupOf: index)
    }

    func setUpdateRefs(_ on: Bool) {
        plan.updateRefs = on
        changed()
    }

    func setAutostash(_ on: Bool) {
        plan.autostash = on
        changed()
    }

    private func changed() { onChange?() }

    // MARK: Reading

    /// The step that keeps its place for the step at `index`: itself, or the commit a squash or fixup melts into. Nil for a dropped step and a fold with nothing before it.
    func groupHead(of index: Int) -> RebaseStep? {
        guard plan.steps.indices.contains(index), plan.steps[index].action != .drop else { return nil }
        var position = index
        while position >= 0 {
            let step = plan.steps[position]
            if step.commit != nil, step.action != .drop, !step.action.foldsIntoPrevious { return step }
            position -= 1
        }
        return nil
    }

    /// Whether the step at `index` melts into a commit above it.
    func isFolded(_ index: Int) -> Bool {
        plan.steps.indices.contains(index) && plan.steps[index].action.foldsIntoPrevious
    }

    /// The message of the group the step at `index` belongs to, or nil for a dropped step.
    func message(forGroupOf index: Int) -> String? {
        guard let head = groupHead(of: index)?.commit, let group = plan.groups.first(where: { $0.first?.commit?.id == head.id }) else { return nil }
        return plan.message(of: group)
    }

    /// Whether the message of that group can be edited: a reword, or a squash that has to join messages.
    func isMessageEditable(forGroupOf index: Int) -> Bool {
        guard let head = groupHead(of: index)?.commit, let group = plan.groups.first(where: { $0.first?.commit?.id == head.id }) else { return false }
        return RebasePlan.hasEditableMessage(group)
    }

    /// The subject a row shows: for a reword the one it will get.
    func subject(at index: Int) -> String {
        let step = plan.steps[index]
        if step.action == .reword, let message = message(forGroupOf: index) {
            return message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        }
        return step.commit?.subject ?? step.command ?? ""
    }

    /// Branches other than the current one at the step's commit, without `refs/heads/`.
    func branches(at index: Int) -> [String] {
        guard let id = plan.steps[index].commit?.id else { return [] }
        return (plan.branches[id] ?? []).map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
    }

    var isUnchanged: Bool { plan.isUnchanged(from: original) }

    /// Why the plan cannot start, in the sheet's words.
    var problemText: String? {
        switch plan.problem {
        case let .nothingToFoldInto(commit)?: "\(commit.shortID) kann nicht in den Commit darüber aufgehen: Über ihm bleibt keiner stehen."
        case let .emptyMessage(commit)?: "Der Commit aus \(commit.shortID) braucht eine Nachricht."
        case nil: nil
        }
    }

    /// "3 Commits danach, 1 verworfen"; for an unchanged list onto another commit, how many move there.
    var summary: String {
        if isUnchanged, plan.movesBase { return original.count == 1 ? "1 Commit wandert auf \(targetName)" : "\(original.count) Commits wandern auf \(targetName)" }
        let dropped = plan.steps.filter { $0.action == .drop }.count
        let resulting = plan.result.count
        var parts = [resulting == 1 ? "1 Commit danach" : "\(resulting) Commits danach"]
        if dropped > 0 { parts.append(dropped == 1 ? "1 verworfen" : "\(dropped) verworfen") }
        let folded = plan.steps.filter { $0.action.foldsIntoPrevious }.count
        if folded > 0 { parts.append(folded == 1 ? "1 zusammengeführt" : "\(folded) zusammengeführt") }
        return parts.joined(separator: ", ")
    }
}
