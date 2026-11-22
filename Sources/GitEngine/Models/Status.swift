import Foundation

/// One side (index or worktree) of a `git status --porcelain=v2` entry.
public enum FileState: Character, Sendable, Hashable {
    case unmodified = "."
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
}

public enum ConflictKind: Sendable, Hashable {
    case bothModified
    case bothAdded
    case bothDeleted
    case addedByUs
    case addedByThem
    case deletedByUs
    case deletedByThem
}

public struct StatusEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Set for renames and copies: the path before the rename.
    public let originalPath: String?
    public let indexState: FileState
    public let worktreeState: FileState
    public let isUntracked: Bool
    public let isIgnored: Bool
    public let conflict: ConflictKind?
    public let isSubmodule: Bool

    public init(path: String, originalPath: String?, indexState: FileState, worktreeState: FileState, isUntracked: Bool, isIgnored: Bool, conflict: ConflictKind?, isSubmodule: Bool) {
        self.path = path
        self.originalPath = originalPath
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.isUntracked = isUntracked
        self.isIgnored = isIgnored
        self.conflict = conflict
        self.isSubmodule = isSubmodule
    }

    public var isStaged: Bool { indexState != .unmodified && conflict == nil && !isUntracked }
    public var hasWorktreeChanges: Bool { worktreeState != .unmodified || isUntracked }
}

public struct BranchStatus: Sendable, Hashable {
    /// Nil on an unborn branch (fresh repository).
    public let headSHA: String?
    /// Nil when HEAD is detached.
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public init(headSHA: String?, branch: String?, upstream: String?, ahead: Int, behind: Int) {
        self.headSHA = headSHA
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

public struct RepositoryStatus: Sendable, Hashable {
    public let branch: BranchStatus
    public let entries: [StatusEntry]

    public init(branch: BranchStatus, entries: [StatusEntry]) {
        self.branch = branch
        self.entries = entries
    }

    public var staged: [StatusEntry] { entries.filter(\.isStaged) }
    public var unstaged: [StatusEntry] { entries.filter { $0.hasWorktreeChanges && $0.conflict == nil } }
    public var conflicted: [StatusEntry] { entries.filter { $0.conflict != nil } }
    public var hasConflicts: Bool { !conflicted.isEmpty }
}
