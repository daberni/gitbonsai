import Foundation

/// One entry of `git stash list`. `commitID` is the stash commit whose first parent is the commit the stash was taken on.
public struct Stash: Sendable, Hashable, Identifiable {
    public var id: String { commitID }
    /// `stash@{0}`, `stash@{1}`, …
    public let selector: String
    public let commitID: String
    public let message: String

    public init(selector: String, commitID: String, message: String) {
        self.selector = selector
        self.commitID = commitID
        self.message = message
    }
}
