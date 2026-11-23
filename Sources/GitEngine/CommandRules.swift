import Foundation

/// What a repository tab knows when the command bar opens: enough to say for each command whether it can run, without asking git.
public struct RepositoryCommandState: Sendable, Equatable {
    /// Nil when HEAD is detached.
    public var branch: String?
    public var headSHA: String?
    public var upstream: String?
    public var remotes: [String]
    public var stagedCount: Int
    /// Tracked files with changes in the working tree, untracked files included.
    public var unstagedCount: Int
    /// Changes `git restore` can take back: tracked files only.
    public var trackedChangeCount: Int
    public var conflictCount: Int
    public var stashCount: Int
    public var operation: OperationProgress.Kind?

    public init(branch: String? = nil, headSHA: String? = nil, upstream: String? = nil, remotes: [String] = [], stagedCount: Int = 0, unstagedCount: Int = 0, trackedChangeCount: Int = 0, conflictCount: Int = 0, stashCount: Int = 0, operation: OperationProgress.Kind? = nil) {
        self.branch = branch
        self.headSHA = headSHA
        self.upstream = upstream
        self.remotes = remotes
        self.stagedCount = stagedCount
        self.unstagedCount = unstagedCount
        self.trackedChangeCount = trackedChangeCount
        self.conflictCount = conflictCount
        self.stashCount = stashCount
        self.operation = operation
    }

    public init(status: RepositoryStatus?, remotes: [String], stashCount: Int, operation: OperationProgress.Kind?) {
        let entries = status?.entries.filter { !$0.isIgnored } ?? []
        self.init(
            branch: status?.branch.branch,
            headSHA: status?.branch.headSHA,
            upstream: status?.branch.upstream,
            remotes: remotes,
            stagedCount: status?.staged.count ?? 0,
            unstagedCount: status?.unstaged.count ?? 0,
            trackedChangeCount: entries.filter { !$0.isUntracked && $0.worktreeState != .unmodified && $0.conflict == nil }.count,
            conflictCount: status?.conflicted.count ?? 0,
            stashCount: stashCount,
            operation: operation
        )
    }

    public var hasChanges: Bool { stagedCount + unstagedCount + conflictCount > 0 }
}

/// Why a command cannot run right now. The command bar shows it greyed out with this reason instead of hiding it.
public enum CommandBlocker: Sendable, Equatable {
    case detachedHead
    case noCommits
    case noRemote
    case noUpstream
    case nothingStaged
    case nothingToStage
    case nothingToUnstage
    case noTrackedChanges
    case noChanges
    case noStash
    case conflicts
    case operationInProgress(OperationProgress.Kind)
    case noOperation
    /// The branch has commits the target does not have.
    case notFastForward
    /// The branch already contains the target.
    case upToDate
    /// The branch is checked out, or the worktree is the one shown.
    case checkedOut
    /// A stash has no checkout.
    case notCheckoutable
}

/// The enabled rules of the repository commands, one function per command family. Nil means the command can run.
public enum CommandRules {
    public static func fetch(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.remotes.isEmpty ? .noRemote : nil
    }

    public static func pull(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.branch == nil { return .detachedHead }
        if state.remotes.isEmpty { return .noRemote }
        if state.upstream == nil { return .noUpstream }
        if let operation = state.operation { return .operationInProgress(operation) }
        return nil
    }

    /// A branch without upstream can still be pushed: the first push sets it.
    public static func push(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.branch == nil { return .detachedHead }
        if state.headSHA == nil { return .noCommits }
        if state.remotes.isEmpty { return .noRemote }
        return nil
    }

    public static func pushTags(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.remotes.isEmpty ? .noRemote : nil
    }

    public static func commit(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.conflictCount > 0 { return .conflicts }
        return state.stagedCount == 0 ? .nothingStaged : nil
    }

    /// Stages everything first, so any change will do; unresolved conflicts still block, as staging would mark them resolved.
    public static func commitAll(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.conflictCount > 0 { return .conflicts }
        return state.hasChanges ? nil : .noChanges
    }

    public static func amend(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.headSHA == nil { return .noCommits }
        return state.conflictCount > 0 ? .conflicts : nil
    }

    public static func stageAll(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.unstagedCount == 0 ? .nothingToStage : nil
    }

    public static func unstageAll(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.stagedCount == 0 ? .nothingToUnstage : nil
    }

    /// Untracked files are left alone; discarding them would delete work git never saw.
    public static func discardAll(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.trackedChangeCount == 0 ? .noTrackedChanges : nil
    }

    public static func stash(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.headSHA == nil { return .noCommits }
        if state.conflictCount > 0 { return .conflicts }
        return state.hasChanges ? nil : .noChanges
    }

    public static func pop(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.stashCount == 0 ? .noStash : nil
    }

    public static func newBranch(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.headSHA == nil ? .noCommits : nil
    }

    public static func checkout(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.operation.map { .operationInProgress($0) }
    }

    /// Fast-forwarding the current branch to some ref, before a target is chosen.
    public static func fastForward(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.branch == nil { return .detachedHead }
        if let operation = state.operation { return .operationInProgress(operation) }
        return state.headSHA == nil ? .noCommits : nil
    }

    /// Fast-forwarding a branch at `branchHead` to `target` is offered only when the branch is a strict ancestor of the target.
    /// `reachableFromTarget` holds the commits the target's history reaches; a branch outside it has commits of its own, or the history is not loaded that far.
    public static func fastForward(branchHead: String, target: String, reachableFromTarget: Set<String>) -> CommandBlocker? {
        if branchHead == target { return .upToDate }
        return reachableFromTarget.contains(branchHead) ? nil : .notFastForward
    }

    public static func rebaseInteractive(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.branch == nil { return .detachedHead }
        if let operation = state.operation { return .operationInProgress(operation) }
        return state.headSHA == nil ? .noCommits : nil
    }

    /// Continuing needs every conflict resolved; aborting is always possible while something runs.
    public static func continueOperation(_ state: RepositoryCommandState) -> CommandBlocker? {
        if state.operation == nil { return .noOperation }
        return state.conflictCount > 0 ? .conflicts : nil
    }

    public static func abortOperation(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.operation == nil ? .noOperation : nil
    }

    public static func copyBranchName(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.branch == nil ? .detachedHead : nil
    }

    public static func copyHead(_ state: RepositoryCommandState) -> CommandBlocker? {
        state.headSHA == nil ? .noCommits : nil
    }
}
