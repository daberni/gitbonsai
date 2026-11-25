import Foundation

extension Repository {
    // MARK: Restoring

    /// Writes the files as they are in `commit` into the working tree; the index stays as it is.
    /// A file the commit deleted comes back in the version before the deletion, from the first parent, so the paths go out in one call per source revision.
    public func restore(_ paths: [String], of commit: Commit) async throws {
        var bySource: [(revision: String, paths: [String])] = []
        for path in paths {
            let revision = try await restoreRevision(for: path, of: commit)
            if let index = bySource.firstIndex(where: { $0.revision == revision }) { bySource[index].paths.append(path) } else { bySource.append((revision, [path])) }
        }
        for group in bySource {
            _ = try await runner.runWrite(["restore", "--source=\(group.revision)", "--worktree", "--"] + group.paths)
        }
    }

    /// Undoes what `commit` changed in these files, in the working tree only; the index stays as it is.
    /// Renamed files name their old path too, so the rename itself is undone. Nothing is written when any part of the patch does not apply.
    public func revertChanges(of commit: Commit, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let base: String
        if let parent = commit.parents.first { base = parent } else { base = try await emptyTree() }
        // Fixed options keep the user's diff configuration (prefixes, external tools, textconv, colour) out of a patch that `apply` has to read.
        let patch = try await runner.run(["diff", "--binary", "--no-color", "--no-ext-diff", "--no-textconv", "-M"] + Self.patchPrefixes + [base, commit.id, "--"] + paths).stdout
        guard !patch.isEmpty else { return }
        _ = try await runner.runWrite(["apply", "--reverse", "--whitespace=nowarn", "-"], stdin: patch)
    }

    /// The commit whose version of `path` a restore writes: the commit itself, or its first parent when the file does not exist in it.
    public func restoreRevision(for path: String, of commit: Commit) async throws -> String {
        if await exists(path, in: commit.id) { return commit.id }
        guard let parent = commit.parents.first, await exists(path, in: parent) else {
            throw GitError(arguments: ["restore", "--source=\(commit.id)", "--", path], exitCode: 1, stderr: "\(path) exists neither in \(commit.shortID) nor in its parent.")
        }
        return parent
    }

    /// True when the working tree or the index holds something at any of `paths` that differs from HEAD, untracked and ignored files included; a restore would overwrite it.
    public func hasLocalChanges(at paths: [String]) async throws -> Bool {
        guard !paths.isEmpty else { return false }
        let result = try await runner.run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching", "--"] + paths)
        return !result.stdout.isEmpty
    }

    private func exists(_ path: String, in revision: String) async -> Bool {
        (try? await runner.run(["cat-file", "-e", "\(revision):\(path)"])) != nil
    }

    // MARK: External diff tool

    /// Whether the user set up a tool for `git difftool`; without one git would guess from a built-in list.
    public func hasDiffTool() async -> Bool {
        for key in ["diff.tool", "diff.guitool", "merge.tool"] {
            if let result = try? await runner.run(["config", "--get", key], accepting: [0, 1]), !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }

    /// Opens one file of `source` in the configured diff tool and returns once the tool has closed; git removes its temporary copies then.
    /// A renamed file names its old path too, so both sides are found.
    public func openDiffTool(for path: String, originalPath: String? = nil, in source: DiffSource) async throws {
        let paths = [originalPath, path].compactMap { $0 }
        let arguments: [String]
        switch source {
        case .commit(let commit):
            let base: String
            if let parent = commit.parents.first { base = parent } else { base = try await emptyTree() }
            arguments = ["difftool", "--no-prompt", "-M", base, commit.id, "--"] + paths
        case .revisions(let base, let target):
            arguments = ["difftool", "--no-prompt", "-M", base, target, "--"] + paths
        case .unstaged:
            arguments = ["difftool", "--no-prompt", "--"] + paths
        case .staged:
            arguments = ["difftool", "--no-prompt", "--cached", "-M", "--"] + paths
        case .untracked:
            arguments = ["difftool", "--no-prompt", "--no-index", "--", "/dev/null", path]
        case .added(let commit):
            arguments = ["difftool", "--no-prompt", try await emptyTree(), commit, "--"] + paths
        }
        // `--no-index` exits with 1 when the files differ, like `git diff`.
        _ = try await runner.run(arguments, accepting: source == .untracked ? [0, 1] : [0])
    }

    /// The tree of a root commit's missing parent, in the repository's hash format.
    func emptyTree() async throws -> String {
        try await runner.run(["hash-object", "-t", "tree", "/dev/null"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

