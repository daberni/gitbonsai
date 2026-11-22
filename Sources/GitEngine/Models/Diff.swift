import Foundation

/// Lines added and removed in one file.
public struct DiffStat: Sendable, Hashable {
    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case context, added, removed }

    public let kind: Kind
    public let text: String
    /// Line number in the old and the new version; nil on the side the line does not exist.
    public let oldNumber: Int?
    public let newNumber: Int?
    /// Followed by git's "\ No newline at end of file".
    public let missingNewline: Bool

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, missingNewline: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.missingNewline = missingNewline
    }
}

public struct DiffHunk: Sendable, Hashable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// The function or section git prints after the `@@` range, may be empty.
    public let section: String
    public let lines: [DiffLine]
    /// The hunk exactly as git printed it, header line included; patches are built from these.
    let rawLines: [String]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine], rawLines: [String]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
        self.rawLines = rawLines
    }

    public var header: String { rawLines.first ?? "" }
}

/// The unified diff of one file.
public struct FileDiff: Sendable, Hashable {
    public let path: String
    /// Set when the file was renamed or copied.
    public let oldPath: String?
    public let isNew: Bool
    public let isDeleted: Bool
    public let isBinary: Bool
    public let hunks: [DiffHunk]
    /// Everything before the first hunk (`diff --git`, modes, `---`, `+++`), needed to apply a single hunk.
    let headerLines: [String]

    public init(path: String, oldPath: String?, isNew: Bool, isDeleted: Bool, isBinary: Bool, hunks: [DiffHunk], headerLines: [String]) {
        self.path = path
        self.oldPath = oldPath
        self.isNew = isNew
        self.isDeleted = isDeleted
        self.isBinary = isBinary
        self.hunks = hunks
        self.headerLines = headerLines
    }

    public var stat: DiffStat {
        let lines = hunks.flatMap(\.lines)
        return DiffStat(added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count)
    }

    /// A patch that contains only `hunk`, ready for `git apply`.
    func patch(for hunk: DiffHunk) -> Data {
        Data((headerLines + hunk.rawLines).map { $0 + "\n" }.joined().utf8)
    }
}
