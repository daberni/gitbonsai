import Foundation

/// What a tag ref points at: its own object, and the commit behind it. For a lightweight tag both are the commit; an annotated tag points at a tag object.
public struct TagTarget: Sendable, Hashable {
    public let objectID: String
    public let commitID: String

    public init(objectID: String, commitID: String) {
        self.objectID = objectID
        self.commitID = commitID
    }
}

/// How one tag name compares between this repository and one remote.
public enum TagSyncState: Sendable, Hashable {
    /// Both point at the same object.
    case same
    case localOnly
    /// Same name, other object: a moved tag, or one recreated as annotated or lightweight. A push without force is rejected.
    case differs(local: TagTarget, remote: TagTarget)
    /// Not fetched yet, or deleted here.
    case remoteOnly(TagTarget)
}
