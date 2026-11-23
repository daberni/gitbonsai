import Foundation

/// What a diff compares.
public enum DiffSource: Sendable, Hashable {
    /// A commit against its first parent, or against nothing for a root commit.
    case commit(Commit)
    /// Two revisions, such as two selected commits or a merge base and a commit: `git diff <base> <target>`.
    case revisions(base: String, target: String)
    /// Working tree against the index.
    case unstaged
    /// Index against HEAD.
    case staged
    /// A file git does not track yet, shown as entirely added.
    case untracked
}

extension Repository {
    /// The `a/` and `b/` prefixes the parser and `git apply -p1` expect, whatever `diff.noprefix` or `diff.mnemonicPrefix` configure.
    static let patchPrefixes = ["--src-prefix=a/", "--dst-prefix=b/"]
    private static let diffOptions = ["-p", "--no-color", "--no-ext-diff", "-M"] + patchPrefixes

    /// The diff of one file, or nil when the file has no changes in that source.
    /// For a renamed or copied file pass `originalPath` too; limited to the new path alone git would show it as entirely new.
    /// With `fullFile` the context reaches over the whole file, so its one hunk holds every line of both sides with the changes in place.
    public func diff(of path: String, originalPath: String? = nil, in source: DiffSource, fullFile: Bool = false) async throws -> FileDiff? {
        let paths = [originalPath, path].compactMap { $0 }
        // git takes the context length as a C int.
        let diffOptions = Self.diffOptions + (fullFile ? ["--unified=\(Int32.max)"] : [])
        let result: GitCommandResult
        switch source {
        case .commit(let commit):
            if let parent = commit.parents.first {
                result = try await runner.run(["diff"] + diffOptions + [parent, commit.id, "--"] + paths)
            } else {
                result = try await runner.run(["diff-tree", "-r", "--root", "--no-commit-id"] + diffOptions + [commit.id, "--"] + paths)
            }
        case .revisions(let base, let target):
            result = try await runner.run(["diff"] + diffOptions + [base, target, "--"] + paths)
        case .unstaged:
            result = try await runner.runRefreshingIndex(["diff"] + diffOptions + ["--"] + paths)
        case .staged:
            result = try await runner.run(["diff", "--cached"] + diffOptions + ["--"] + paths)
        case .untracked:
            // Once the file is in the index it is no longer untracked, even though it still differs from nothing.
            let tracked = try await runner.run(["ls-files", "--cached", "-z", "--", path])
            guard tracked.stdout.isEmpty else { return nil }
            // Exits with 1 because the files differ.
            result = try await runner.run(["diff", "--no-index"] + diffOptions + ["--", "/dev/null", path], accepting: [0, 1])
        }
        return DiffParser.parse(result.stdout).first
    }

    /// For a file git shows as binary: the UTF-16 or UTF-32 encoding of its newer side (the older one when it was deleted), or nil when it is no such text.
    public func wideTextEncoding(of diff: FileDiff, in source: DiffSource) async -> WideTextEncoding? {
        let oldPath = diff.oldPath ?? diff.path
        let blob: String?
        switch source {
        case .commit(let commit): blob = diff.isDeleted ? commit.parents.first.map { "\($0):\(oldPath)" } : "\(commit.id):\(diff.path)"
        case .revisions(let base, let target): blob = diff.isDeleted ? "\(base):\(oldPath)" : "\(target):\(diff.path)"
        case .staged: blob = diff.isDeleted ? "HEAD:\(oldPath)" : ":\(diff.path)"
        case .unstaged: blob = diff.isDeleted ? ":\(oldPath)" : nil
        case .untracked: blob = nil
        }
        guard let blob else {
            let handle = FileHandle(forReadingAtPath: URL(fileURLWithPath: path).appendingPathComponent(diff.path).path)
            defer { try? handle?.close() }
            return (try? handle?.read(upToCount: Self.encodingSample)).flatMap { $0.flatMap(WideTextEncoding.detect) }
        }
        // Large binaries are not read whole just to look at their first bytes; text files that size are rare.
        guard let size = try? await runner.run(["cat-file", "-s", blob]), let bytes = Int(size.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)), bytes <= Self.encodingBlobLimit else { return nil }
        guard let content = try? await runner.run(["cat-file", "blob", blob]) else { return nil }
        return WideTextEncoding.detect(content.stdout)
    }

    private static let encodingSample = 4096
    private static let encodingBlobLimit = 16 << 20

    /// Lines added and removed per path for the working tree (`staged: false`) or the index (`staged: true`).
    public func workingStats(staged: Bool) async throws -> [String: DiffStat] {
        let result = staged ? try await runner.run(["diff", "--cached", "--numstat", "-M", "-z"]) : try await runner.runRefreshingIndex(["diff", "--numstat", "-M", "-z"])
        return DiffParser.parseNumstat(result.stdout)
    }

    // MARK: Staging

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.runWrite(["add", "--"] + paths)
    }

    /// Takes the paths out of the index again; in a repository without commits they become untracked.
    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let hasHead = await revisionExists("HEAD")
        _ = try await runner.runWrite(hasHead ? ["restore", "--staged", "--"] + paths : ["rm", "--cached", "-q", "--"] + paths)
    }

    /// Stages one hunk of an unstaged or untracked file.
    public func stage(_ hunk: DiffHunk, of file: FileDiff) async throws {
        _ = try await runner.runWrite(["apply", "--cached", "--whitespace=nowarn", "-"], stdin: file.patch(for: hunk))
    }

    /// Takes one hunk of a staged file out of the index.
    public func unstage(_ hunk: DiffHunk, of file: FileDiff) async throws {
        _ = try await runner.runWrite(["apply", "--cached", "--reverse", "--whitespace=nowarn", "-"], stdin: file.patch(for: hunk))
    }

    // MARK: Discarding

    /// Reverts one hunk of an unstaged file in the working tree; the index stays as it is. The one hunk of an untracked file deletes it.
    public func discard(_ hunk: DiffHunk, of file: FileDiff) async throws {
        _ = try await runner.runWrite(["apply", "--reverse", "--whitespace=nowarn", "-"], stdin: file.patch(for: hunk))
    }

    /// Resets tracked files in the working tree to their staged content, so staged changes survive.
    public func discardUnstagedChanges(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.runWrite(["restore", "--worktree", "--"] + paths)
    }

    /// Deletes untracked files. Ignored files are left alone.
    public func removeUntracked(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.runWrite(["clean", "-f", "-q", "--"] + paths)
    }
}
