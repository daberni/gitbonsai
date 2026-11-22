import Foundation

/// A commit as a ref picker shows it: its SHA, when it was committed and its subject.
public struct CommitSummary: Sendable, Hashable {
    public let sha: String
    public let date: Date
    public let subject: String

    public init(sha: String, date: Date, subject: String) {
        self.sha = sha
        self.date = date
        self.subject = subject
    }

    public var shortID: String { String(sha.prefix(7)) }
}

/// A branch or tag with the commit it points to, as read from `git for-each-ref`. Annotated tags are peeled to their commit.
public struct RefTip: Sendable, Hashable, Identifiable {
    public var id: String { fullName }
    public let fullName: String
    /// The short name git accepts as a revision: `main`, `origin/main`, `v1.0`.
    public let name: String
    public let kind: RefKind
    public let commit: CommitSummary

    public init(fullName: String, name: String, kind: RefKind, commit: CommitSummary) {
        self.fullName = fullName
        self.name = name
        self.kind = kind
        self.commit = commit
    }
}
