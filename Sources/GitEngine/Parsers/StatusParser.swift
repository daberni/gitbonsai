import Foundation

/// Parses `git status --porcelain=v2 -z --branch --untracked-files=all`.
public enum StatusParser {
    public struct ParseError: Error, CustomStringConvertible {
        public let line: String
        public var description: String { "unrecognized status line: \(line)" }
    }

    public static func parse(_ data: Data) throws -> RepositoryStatus {
        let items = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var headSHA: String?
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [StatusEntry] = []
        var index = 0
        while index < items.count {
            let line = items[index]
            index += 1
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": headSHA = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head": branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
                continue
            }
            switch line.first {
            case "1":
                entries.append(try ordinary(line))
            case "2":
                guard index < items.count else { throw ParseError(line: line) }
                let originalPath = items[index]
                index += 1
                entries.append(try renamed(line, originalPath: originalPath))
            case "u":
                entries.append(try unmerged(line))
            case "?":
                entries.append(simple(String(line.dropFirst(2)), untracked: true))
            case "!":
                entries.append(simple(String(line.dropFirst(2)), ignored: true))
            default:
                throw ParseError(line: line)
            }
        }
        let branchStatus = BranchStatus(headSHA: headSHA, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
        return RepositoryStatus(branch: branchStatus, entries: entries)
    }

    /// `1 XY sub mH mI mW hH hI path`
    private static func ordinary(_ line: String) throws -> StatusEntry {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { throw ParseError(line: line) }
        return try entry(xy: fields[1], submodule: fields[2], path: String(fields[8]), originalPath: nil, line: line)
    }

    /// `2 XY sub mH mI mW hH hI Xscore path` followed by the original path as its own NUL item.
    private static func renamed(_ line: String, originalPath: String) throws -> StatusEntry {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10 else { throw ParseError(line: line) }
        return try entry(xy: fields[1], submodule: fields[2], path: String(fields[9]), originalPath: originalPath, line: line)
    }

    /// `u XY sub m1 m2 m3 mW h1 h2 h3 path`
    private static func unmerged(_ line: String) throws -> StatusEntry {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { throw ParseError(line: line) }
        let xy = fields[1]
        let conflict: ConflictKind
        switch xy {
        case "DD": conflict = .bothDeleted
        case "AU": conflict = .addedByUs
        case "UD": conflict = .deletedByThem
        case "UA": conflict = .addedByThem
        case "DU": conflict = .deletedByUs
        case "AA": conflict = .bothAdded
        case "UU": conflict = .bothModified
        default: throw ParseError(line: line)
        }
        return StatusEntry(
            path: String(fields[10]),
            originalPath: nil,
            indexState: .unmerged,
            worktreeState: .unmerged,
            isUntracked: false,
            isIgnored: false,
            conflict: conflict,
            isSubmodule: fields[2].first != "N"
        )
    }

    private static func entry(xy: Substring, submodule: Substring, path: String, originalPath: String?, line: String) throws -> StatusEntry {
        guard xy.count == 2, let x = xy.first, let y = xy.last,
              let indexState = FileState(rawValue: x), let worktreeState = FileState(rawValue: y) else {
            throw ParseError(line: line)
        }
        return StatusEntry(
            path: path,
            originalPath: originalPath,
            indexState: indexState,
            worktreeState: worktreeState,
            isUntracked: false,
            isIgnored: false,
            conflict: nil,
            isSubmodule: submodule.first != "N"
        )
    }

    private static func simple(_ path: String, untracked: Bool = false, ignored: Bool = false) -> StatusEntry {
        StatusEntry(
            path: path,
            originalPath: nil,
            indexState: .unmodified,
            worktreeState: .unmodified,
            isUntracked: untracked,
            isIgnored: ignored,
            conflict: nil,
            isSubmodule: false
        )
    }
}
