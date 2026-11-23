import Foundation

/// One side of an unmerged path in the index: stage 1 (base), 2 (ours) or 3 (theirs).
public struct ConflictBlob: Sendable, Hashable {
    public let mode: String
    public let oid: String

    public init(mode: String, oid: String) {
        self.mode = mode
        self.oid = oid
    }
}

/// The index stages of one unmerged path, as `git ls-files -u` lists them. A missing stage is a side that has no such file.
public struct ConflictStages: Sendable, Hashable {
    public var base: ConflictBlob?
    public var ours: ConflictBlob?
    public var theirs: ConflictBlob?

    public init(base: ConflictBlob? = nil, ours: ConflictBlob? = nil, theirs: ConflictBlob? = nil) {
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }

    /// What happened on each side, in the terms of `git status`.
    public var kind: ConflictKind {
        switch (base != nil, ours != nil, theirs != nil) {
        case (_, true, true): base == nil ? .bothAdded : .bothModified
        case (true, true, false): .deletedByThem
        case (true, false, true): .deletedByUs
        case (false, true, false): .addedByUs
        case (false, false, true): .addedByThem
        default: .bothDeleted
        }
    }
}

/// A place where ours or theirs differ from the base, with the lines of all three. Lines keep a trailing carriage return.
public struct MergeChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Only ours changed here; the merge takes ours.
        case ours
        /// Only theirs changed here; the merge takes theirs.
        case theirs
        /// Both changed it the same way.
        case both
        /// Both changed it differently: the user decides.
        case conflict
    }

    public let base: [String]
    public let ours: [String]
    public let theirs: [String]
    public let kind: Kind

    public init(base: [String], ours: [String], theirs: [String], kind: Kind) {
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.kind = kind
    }

    public func lines(of side: ConflictSide) -> [String] {
        side == .ours ? ours : theirs
    }

    /// What the merge takes without the user: the changed side, or nil for a conflict.
    public var automatic: [String]? {
        switch kind {
        case .ours, .both: ours
        case .theirs: theirs
        case .conflict: nil
        }
    }
}

/// A text file as the three-way merge of its stages: runs of lines all three agree on, and the changes between them.
public struct MergeDocument: Sendable, Hashable {
    public enum Region: Sendable, Hashable {
        case same([String])
        case change(MergeChange)
    }

    /// The encoding the file is read and written in: UTF-8 when every stage is valid UTF-8, otherwise ISO Latin 1, which keeps every byte as it is.
    public enum Encoding: Sendable, Hashable {
        case utf8
        case latin1

        var foundation: String.Encoding { self == .utf8 ? .utf8 : .isoLatin1 }

        public func decode(_ data: Data) -> String {
            String(data: data, encoding: foundation) ?? String(decoding: data, as: UTF8.self)
        }

        public func encode(_ text: String) -> Data? {
            text.data(using: foundation)
        }
    }

    public let regions: [Region]
    public let encoding: Encoding
    /// Whether the merged file ends with a newline; it follows ours, or theirs when ours has no file.
    public let endsWithNewline: Bool

    public init(regions: [Region], encoding: Encoding, endsWithNewline: Bool) {
        self.regions = regions
        self.encoding = encoding
        self.endsWithNewline = endsWithNewline
    }

    public var changes: [MergeChange] {
        regions.compactMap { if case .change(let change) = $0 { change } else { nil } }
    }

    /// The file with each change replaced by its result, in change order. Nil while a change has none.
    public func text(with results: [[String]?]) -> String? {
        var lines: [String] = []
        var index = 0
        for region in regions {
            switch region {
            case .same(let same):
                lines += same
            case .change:
                guard results.indices.contains(index), let result = results[index] else { return nil }
                lines += result
                index += 1
            }
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }
}

/// An unmerged path with everything needed to resolve it.
public struct Conflict: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// Both sides have the file as text: the three-way merge with its changes and conflicts.
        case text(MergeDocument)
        /// At least one side is binary; only a whole side can be taken.
        case binary
        /// One side deleted or renamed the file away. The remaining side's text, when it is text, to show what keeping it means.
        case oneSided(remaining: String?)
        /// Both sides deleted or renamed the file away.
        case none
    }

    public let path: String
    public let stages: ConflictStages
    public let content: Content

    public init(path: String, stages: ConflictStages, content: Content) {
        self.path = path
        self.stages = stages
        self.content = content
    }

    public var kind: ConflictKind { stages.kind }
}

/// A whole side a conflict can be resolved with, in `git checkout --ours/--theirs` terms.
public enum ConflictSide: Sendable, Hashable {
    case ours
    case theirs
}
