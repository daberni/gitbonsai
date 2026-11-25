import Foundation

/// One entry of `git stash list`. `commitID` is the stash commit whose first parent is the commit the stash was taken on.
public struct Stash: Sendable, Hashable, Identifiable {
    public var id: String { commitID }
    /// `stash@{0}`, `stash@{1}`, …; shifts whenever a newer stash is pushed or dropped.
    public let selector: String
    public let commitID: String
    /// The reflog subject as git writes it: `On main: message` or `WIP on main: abc1234 subject`.
    public let message: String
    /// When the stash was made.
    public let date: Date

    public init(selector: String, commitID: String, message: String, date: Date) {
        self.selector = selector
        self.commitID = commitID
        self.message = message
        self.date = date
    }

    /// The branch the stash was made on, nil for a detached HEAD (`(no branch)`) or a subject git did not write.
    public var branch: String? {
        guard let prefix = parsedSubject?.prefix else { return nil }
        let name = prefix.hasPrefix("WIP on ") ? prefix.dropFirst(7) : prefix.dropFirst(3)
        return name == "(no branch)" ? nil : String(name)
    }

    /// The message without git's `On <branch>:` prefix.
    public var text: String { parsedSubject?.text ?? message }

    /// Ref names cannot contain a colon, so the first `: ` ends the prefix.
    private var parsedSubject: (prefix: Substring, text: String)? {
        guard message.hasPrefix("On ") || message.hasPrefix("WIP on "), let separator = message.range(of: ": ") else { return nil }
        return (message[..<separator.lowerBound], String(message[separator.upperBound...]))
    }
}

/// The changes one stash holds, in the areas of the working directory it was taken from.
public struct StashChanges: Sendable, Equatable {
    /// The index against the commit the stash was made on.
    public let staged: [ChangedFile]
    /// The working tree against the index.
    public let unstaged: [ChangedFile]
    /// Files git did not track, kept by `git stash -u` or `-a` in a commit of their own.
    public let untracked: [ChangedFile]
    /// That commit, nil for a stash made without untracked files.
    public let untrackedCommit: String?

    public init(staged: [ChangedFile], unstaged: [ChangedFile], untracked: [ChangedFile], untrackedCommit: String?) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.untrackedCommit = untrackedCommit
    }
}
