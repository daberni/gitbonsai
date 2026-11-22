import Foundation

public enum RefKind: Sendable, Hashable {
    case localBranch
    case remoteBranch(remote: String)
    case tag
    case stash
    case other
}

/// A ref as read from `git for-each-ref`. `name` is the short name (`main`, `origin/main`, `v1.0`), `fullName` the full ref (`refs/heads/main`).
public struct Ref: Sendable, Hashable, Identifiable {
    public var id: String { fullName }
    public let fullName: String
    public let name: String
    public let kind: RefKind
    /// SHA of the commit the ref points to (peeled for annotated tags).
    public let target: String
    public let isHead: Bool
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?

    public init(fullName: String, name: String, kind: RefKind, target: String, isHead: Bool, upstream: String?, ahead: Int?, behind: Int?) {
        self.fullName = fullName
        self.name = name
        self.kind = kind
        self.target = target
        self.isHead = isHead
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}
