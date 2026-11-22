import Foundation

/// Parses `git worktree list --porcelain -z`.
public enum WorktreeParser {
    public static func parse(_ data: Data) throws -> [Worktree] {
        // With -z each attribute line ends in NUL and entries are separated by an extra NUL, so an empty item closes an entry.
        let items = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var worktrees: [Worktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var bare = false
        var detached = false
        var locked = false
        var lockReason: String?
        var prunable = false

        func flush() {
            guard let currentPath = path else { return }
            worktrees.append(Worktree(
                path: currentPath,
                headSHA: head,
                branch: branch,
                isMain: worktrees.isEmpty,
                isBare: bare,
                isDetached: detached,
                isLocked: locked,
                lockReason: lockReason,
                isPrunable: prunable
            ))
            path = nil
            head = nil
            branch = nil
            bare = false
            detached = false
            locked = false
            lockReason = nil
            prunable = false
        }

        for item in items {
            if item.isEmpty {
                flush()
                continue
            }
            let parts = item.split(separator: " ", maxSplits: 1).map(String.init)
            let key = parts[0]
            let value = parts.count > 1 ? parts[1] : nil
            switch key {
            case "worktree":
                flush()
                path = value
            case "HEAD": head = value
            case "branch": branch = value
            case "bare": bare = true
            case "detached": detached = true
            case "locked":
                locked = true
                lockReason = value
            case "prunable": prunable = true
            default: break
            }
        }
        flush()
        return worktrees
    }
}
