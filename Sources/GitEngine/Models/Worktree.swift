import Foundation

/// One entry of `git worktree list --porcelain`.
public struct Worktree: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let headSHA: String?
    /// Full ref name (`refs/heads/feature`) or nil when detached or bare.
    public let branch: String?
    public let isMain: Bool
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool

    public init(path: String, headSHA: String?, branch: String?, isMain: Bool, isBare: Bool, isDetached: Bool, isLocked: Bool, lockReason: String?, isPrunable: Bool) {
        self.path = path
        self.headSHA = headSHA
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
    }

    public var branchName: String? { branch.map { $0.replacingOccurrences(of: "refs/heads/", with: "") } }
}
