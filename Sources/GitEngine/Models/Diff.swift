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
    /// The line without its line ending; a CR before the LF is in `carriageReturn`, since AppKit would lay it out as a second line.
    public let text: String
    /// Line number in the old and the new version; nil on the side the line does not exist.
    public let oldNumber: Int?
    public let newNumber: Int?
    /// Followed by git's "\ No newline at end of file".
    public let missingNewline: Bool
    /// The line ended with CR LF.
    public let carriageReturn: Bool
    /// In a word diff, the words of a line that kept some and changed others, in order; `text` joins them. Empty for every other line.
    public let segments: [DiffSegment]

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, missingNewline: Bool = false, carriageReturn: Bool = false, segments: [DiffSegment] = []) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.missingNewline = missingNewline
        self.carriageReturn = carriageReturn
        self.segments = segments
    }
}

/// A run of a word-diff line that both sides share, or that only the old or the new side has.
public struct DiffSegment: Sendable, Hashable {
    public let kind: DiffLine.Kind
    public let text: String

    public init(kind: DiffLine.Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Which whitespace differences a diff leaves out: none, changes in the amount of whitespace (`-b`) or all of it (`-w`); optionally also added or removed blank lines.
public struct DiffWhitespace: Sendable, Hashable {
    public enum Ignoring: String, Sendable, Hashable, CaseIterable {
        case nothing
        case changes
        case all
    }

    public var ignoring: Ignoring
    public var ignoresBlankLines: Bool

    public init(ignoring: Ignoring = .nothing, ignoresBlankLines: Bool = false) {
        self.ignoring = ignoring
        self.ignoresBlankLines = ignoresBlankLines
    }

    /// Some difference is left out, so a hunk no longer matches the file and cannot be applied.
    public var isFiltering: Bool { ignoring != .nothing || ignoresBlankLines }

    /// A changed line ending counts as whitespace too.
    var arguments: [String] {
        let ignoring: [String] = switch self.ignoring {
        case .nothing: []
        case .changes: ["-b", "--ignore-cr-at-eol"]
        case .all: ["-w", "--ignore-cr-at-eol"]
        }
        return ignoring + (ignoresBlankLines ? ["--ignore-blank-lines"] : [])
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
    /// The `@@ … @@` line.
    public let header: String
    /// The hunk's bytes exactly as git printed them, header line included; patches are built from these.
    let rawPatch: Data

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine], header: String, rawPatch: Data) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
        self.header = header
        self.rawPatch = rawPatch
    }
}

/// The unified diff of one file.
public struct FileDiff: Sendable, Hashable {
    public let path: String
    /// Set when the file was renamed or copied.
    public let oldPath: String?
    /// The file was copied from `oldPath`, which still exists; otherwise a set `oldPath` means a rename.
    public let isCopy: Bool
    /// git's similarity score of a rename or copy, in percent.
    public let similarity: Int?
    public let isNew: Bool
    public let isDeleted: Bool
    public let isBinary: Bool
    /// Both set when the file mode changed, for instance `100644` and `100755`.
    public let oldMode: String?
    public let newMode: String?
    public let hunks: [DiffHunk]
    /// The bytes before the first hunk (`diff --git`, modes, `---`, `+++`), needed to apply a single hunk.
    let rawHeader: Data

    public init(path: String, oldPath: String?, isCopy: Bool = false, similarity: Int? = nil, isNew: Bool, isDeleted: Bool, isBinary: Bool, oldMode: String? = nil, newMode: String? = nil, hunks: [DiffHunk], rawHeader: Data) {
        self.path = path
        self.oldPath = oldPath
        self.isCopy = isCopy
        self.similarity = similarity
        self.isNew = isNew
        self.isDeleted = isDeleted
        self.isBinary = isBinary
        self.oldMode = oldMode
        self.newMode = newMode
        self.hunks = hunks
        self.rawHeader = rawHeader
    }

    /// What happened to the file, in the terms of `--name-status`.
    public var change: FileState {
        if isNew { return .added }
        if isDeleted { return .deleted }
        if oldPath != nil { return isCopy ? .copied : .renamed }
        return .modified
    }

    /// The content itself did not change: a pure rename or copy, or only the file mode.
    public var hasNoContentChange: Bool { hunks.isEmpty && !isBinary && !isNew && !isDeleted }

    public var modeChanged: Bool { oldMode != nil && newMode != nil && oldMode != newMode }

    public var stat: DiffStat {
        let lines = hunks.flatMap(\.lines)
        return DiffStat(added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count)
    }

    /// A patch that contains only `hunk`, ready for `git apply`.
    func patch(for hunk: DiffHunk) -> Data {
        rawHeader + hunk.rawPatch
    }
}
