import Foundation

/// One file touched by a commit, as reported by `git diff --name-status`.
public struct ChangedFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Set for renames and copies: the path before the change.
    public let originalPath: String?
    public let state: FileState

    public init(path: String, originalPath: String?, state: FileState) {
        self.path = path
        self.originalPath = originalPath
        self.state = state
    }
}
