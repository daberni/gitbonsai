import Foundation

extension Repository {
    // MARK: Restoring

    /// Writes the file as it is in `commit` into the working tree; the index stays as it is.
    /// A file the commit deleted comes back in the version before the deletion, from the first parent.
    public func restore(_ path: String, of commit: Commit) async throws {
        let revision = try await restoreRevision(for: path, of: commit)
        _ = try await runner.runWrite(["restore", "--source=\(revision)", "--worktree", "--", path])
    }

    /// The commit whose version of `path` a restore writes: the commit itself, or its first parent when the file does not exist in it.
    public func restoreRevision(for path: String, of commit: Commit) async throws -> String {
        if await exists(path, in: commit.id) { return commit.id }
        guard let parent = commit.parents.first, await exists(path, in: parent) else {
            throw GitError(arguments: ["restore", "--source=\(commit.id)", "--", path], exitCode: 1, stderr: "„\(path)“ gibt es weder in \(commit.shortID) noch in seinem Parent.")
        }
        return parent
    }

    /// True when the working tree or the index holds something at `path` that differs from HEAD, untracked and ignored files included; a restore would overwrite it.
    public func hasLocalChanges(at path: String) async throws -> Bool {
        let result = try await runner.run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching", "--", path])
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
        }
        // `--no-index` exits with 1 when the files differ, like `git diff`.
        _ = try await runner.run(arguments, accepting: source == .untracked ? [0, 1] : [0])
    }

    /// The tree of a root commit's missing parent, in the repository's hash format.
    func emptyTree() async throws -> String {
        try await runner.run(["hash-object", "-t", "tree", "/dev/null"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

