import Foundation

/// Decides which file events matter to a tab: the files of its working tree, its own git directory (HEAD, index, a rebase or merge in progress)
/// and what the repository's worktrees share (refs, packed refs, the stash, FETCH_HEAD, config, other worktrees' HEADs).
///
/// Object writes, lock files, reflogs other than the stash and dependency or build folders are noise. A fixed list stands in for `.gitignore`, which would cost a `git check-ignore` per burst.
public struct WatchScope: Sendable, Equatable {
    /// Real paths, without a trailing slash.
    public let root: String
    public let gitDirectory: String
    public let commonDirectory: String

    static let skippedFolders: Set<String> = ["node_modules", ".build", "DerivedData", ".gradle", ".swiftpm", "Pods", ".venv", "__pycache__"]
    static let skippedFiles: Set<String> = [".DS_Store"]
    /// Files of a worktree's own git directory that change what the tab shows.
    static let ownFiles: Set<String> = ["HEAD", "index", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
    static let ownFolders: Set<String> = ["rebase-merge", "rebase-apply"]
    static let sharedFiles: Set<String> = ["packed-refs", "FETCH_HEAD", "config"]

    public init(root: String, gitDirectory: String, commonDirectory: String) {
        self.root = Self.trimmed(root)
        self.gitDirectory = Self.trimmed(gitDirectory)
        self.commonDirectory = Self.trimmed(commonDirectory)
    }

    /// Reads the worktree's own git directory; a linked worktree keeps it under the common directory's `worktrees/`.
    public static func of(root: String, commonDirectory: String, gitPath: String = GitRunner.defaultGitPath()) async throws -> WatchScope {
        let result = try await GitRunner(repositoryPath: root, gitPath: gitPath).run(["rev-parse", "--absolute-git-dir"])
        let gitDirectory = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchScope(root: RealPath.of(root), gitDirectory: RealPath.of(gitDirectory), commonDirectory: RealPath.of(commonDirectory))
    }

    /// The folders a stream has to watch: the working tree, and the common directory when it lies outside, as for a linked worktree.
    public var watchedPaths: [String] {
        Self.contains(root, commonDirectory) ? [root] : [root, commonDirectory]
    }

    public func isRelevant(_ path: String) -> Bool {
        let path = Self.trimmed(path)
        if gitDirectory != commonDirectory, let relative = Self.relative(path, to: gitDirectory) {
            return isOwn(relative)
        }
        if let relative = Self.relative(path, to: commonDirectory) {
            return isInCommonDirectory(relative)
        }
        if let relative = Self.relative(path, to: root) {
            return isInWorkingTree(relative)
        }
        return false
    }

    private func isOwn(_ parts: [Substring]) -> Bool {
        guard let first = parts.first else { return true }
        if parts.last?.hasSuffix(".lock") == true { return false }
        if Self.ownFolders.contains(String(first)) { return true }
        return parts.count == 1 && Self.ownFiles.contains(String(first))
    }

    private func isInCommonDirectory(_ parts: [Substring]) -> Bool {
        guard let first = parts.first else { return true }
        if parts.last?.hasSuffix(".lock") == true { return false }
        switch first {
        case "objects", "hooks", "info", "modules", "lfs":
            return false
        case "refs":
            return true
        case "logs":
            // The stash list lives in the stash reflog; every other reflog only follows a ref that changes as well.
            return parts.count == 3 && parts[1] == "refs" && parts[2] == "stash"
        case "worktrees":
            // Another worktree's HEAD moves its row in the sidebar; adding or removing a worktree changes the list.
            return parts.count <= 2 || (parts.count == 3 && parts[2] == "HEAD")
        default:
            if parts.count == 1, Self.sharedFiles.contains(String(first)) { return true }
            // The main worktree's own files sit at the top of the common directory; for a linked worktree its HEAD is another worktree's.
            if gitDirectory == commonDirectory { return isOwn(parts) }
            return parts.count == 1 && first == "HEAD"
        }
    }

    private func isInWorkingTree(_ parts: [Substring]) -> Bool {
        if let last = parts.last, Self.skippedFiles.contains(String(last)) { return false }
        // A nested `.git` belongs to a submodule or another repository; a linked worktree's `.git` file never changes.
        return !parts.contains { $0 == ".git" || Self.skippedFolders.contains(String($0)) }
    }

    private static func relative(_ path: String, to base: String) -> [Substring]? {
        guard contains(base, path) else { return nil }
        return path.dropFirst(base.count).split(separator: "/")
    }

    private static func contains(_ base: String, _ path: String) -> Bool {
        path == base || path.hasPrefix(base + "/")
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
