import Foundation

/// A tag as the Tags list shows it.
public struct Tag: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// Short name without `refs/tags/`.
    public let name: String
    /// The commit the tag points to, peeled through an annotated tag object.
    public let commitID: String
    /// Annotated tags are objects of their own with tagger, date and message; lightweight tags are only a ref.
    public let isAnnotated: Bool
    /// Tagger date of an annotated tag, committer date of the commit for a lightweight one.
    public let date: Date
    /// First line of the tag message, or of the commit message for a lightweight tag.
    public let subject: String

    public init(name: String, commitID: String, isAnnotated: Bool, date: Date, subject: String) {
        self.name = name
        self.commitID = commitID
        self.isAnnotated = isAnnotated
        self.date = date
        self.subject = subject
    }
}
