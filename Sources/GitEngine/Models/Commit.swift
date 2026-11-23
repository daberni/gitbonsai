import Foundation

/// One commit as read from `git log`. `id` and `parents` are full SHAs: 40 hex characters, 64 in a SHA-256 repository.
public struct Commit: Sendable, Hashable, Identifiable {
    public let id: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let committerName: String
    public let committerEmail: String
    public let committerDate: Date
    public let subject: String
    public let body: String
    /// The trailers of the message, such as co-authors and sign-offs; they are still part of `body`.
    public let trailers: [CommitTrailer]

    public init(
        id: String,
        parents: [String],
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        committerName: String,
        committerEmail: String,
        committerDate: Date,
        subject: String,
        body: String,
        trailers: [CommitTrailer] = []
    ) {
        self.id = id
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committerDate = committerDate
        self.subject = subject
        self.body = body
        self.trailers = trailers
    }

    public var coAuthors: [CommitTrailer] { trailers.filter(\.isCoAuthor) }

    public var isMerge: Bool { parents.count > 1 }
    public var shortID: String { String(id.prefix(7)) }
}
