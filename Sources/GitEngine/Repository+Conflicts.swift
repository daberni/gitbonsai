import Foundation

/// The path is not unmerged (any more): resolved, here or elsewhere. Other failures to read a conflict are `GitError`s.
public struct NoConflict: Error, Sendable, Equatable {
    public let path: String
}

extension Repository {
    /// Files larger than this are offered as whole sides only, like binaries; the merge of their text is not read.
    static let conflictTextLimit = 8 << 20

    // MARK: Reading

    /// The stages of every unmerged path, keyed by path.
    public func conflictStages() async throws -> [String: ConflictStages] {
        let result = try await runner.run(["ls-files", "-u", "-z"])
        return ConflictParser.parseStages(result.stdout)
    }

    /// The unmerged paths whose two sides git takes for binary, so that only whole sides are offered for them: `git diff --numstat` of the two blobs counts no lines.
    public func binaryConflictPaths() async throws -> Set<String> {
        var binary: Set<String> = []
        for (path, stages) in try await conflictStages() {
            guard let ours = stages.ours, let theirs = stages.theirs else { continue }
            let numstat = try await runner.run(["diff", "--numstat", "--no-ext-diff", "--no-textconv", ours.oid, theirs.oid]).stdoutString
            if numstat.hasPrefix("-\t-\t") { binary.insert(path) }
        }
        return binary
    }

    /// One unmerged path with its stages and its content: for text on both sides the three-way merge of the stages, aligned from `git diff` of each side against the base, independent of what the working tree holds now.
    /// Throws `NoConflict` when the path is not unmerged.
    public func conflict(at path: String) async throws -> Conflict {
        let listed = try await runner.run(["ls-files", "-u", "-z", "--", path])
        guard let stages = ConflictParser.parseStages(listed.stdout)[path] else { throw NoConflict(path: path) }
        return Conflict(path: path, stages: stages, content: try await content(of: stages))
    }

    private func content(of stages: ConflictStages) async throws -> Conflict.Content {
        guard let ours = stages.ours, let theirs = stages.theirs else {
            guard let remaining = stages.ours ?? stages.theirs else { return .none }
            let data = try await blob(remaining.oid)
            let text = data.flatMap { ConflictParser.isBinary($0) ? nil : Self.encoding(of: [$0]).decode($0) }
            return .oneSided(remaining: text)
        }
        var base: Data? = Data()
        if let stage = stages.base { base = try await blob(stage.oid) }
        guard let oursData = try await blob(ours.oid), let theirsData = try await blob(theirs.oid), let base else { return .binary }
        let sides = [oursData, base, theirsData]
        guard !sides.contains(where: ConflictParser.isBinary) else { return .binary }
        return .text(try await mergeDocument(base: base, ours: oursData, theirs: theirsData, encoding: Self.encoding(of: sides)))
    }

    /// git's diffs of ours and theirs against the base, through a temporary folder; the alignment of the two is the conflict view's.
    private func mergeDocument(base: Data, ours: Data, theirs: Data, encoding: MergeDocument.Encoding) async throws -> MergeDocument {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let files = try folder.write(["base": base, "ours": ours, "theirs": theirs])
        async let oursDiff = zeroContextDiff(from: files[0], to: files[1])
        async let theirsDiff = zeroContextDiff(from: files[0], to: files[2])
        let baseLines = ConflictParser.lines(of: base, encoding: encoding)
        let oursLines = ConflictParser.lines(of: ours, encoding: encoding)
        let theirsLines = ConflictParser.lines(of: theirs, encoding: encoding)
        let regions = ConflictParser.align(base: baseLines.lines, ours: oursLines.lines, theirs: theirsLines.lines, oursHunks: try await oursDiff, theirsHunks: try await theirsDiff)
        return MergeDocument(regions: regions, encoding: encoding, endsWithNewline: oursLines.endsWithNewline)
    }

    /// `git diff --no-index -U0` exits with 1 when the files differ. Fixed options keep the user's diff configuration out of the alignment.
    private func zeroContextDiff(from base: String, to side: String) async throws -> [ConflictParser.Hunk] {
        let result = try await runner.run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "--diff-algorithm=histogram", "-U0", "--", base, side], accepting: [0, 1])
        return ConflictParser.parseHunks(result.stdout)
    }

    /// The blob's content, or nil when it is too large to merge as text.
    private func blob(_ oid: String) async throws -> Data? {
        let size = try await runner.run(["cat-file", "-s", oid]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bytes = Int(size), bytes <= Self.conflictTextLimit else { return nil }
        return try await runner.run(["cat-file", "blob", oid]).stdout
    }

    private static func encoding(of sides: [Data]) -> MergeDocument.Encoding {
        sides.allSatisfy { String(data: $0, encoding: .utf8) != nil } ? .utf8 : .latin1
    }

    // MARK: Word merge

    /// Merges a conflict word by word, for changes of both sides to different words of the same lines: `git merge-file` over the three sides with one word per line.
    /// Nil when the words still conflict; changes that touch count as conflicting, as in git's line merge.
    public func mergeWords(of change: MergeChange) async throws -> [String]? {
        guard change.kind == .conflict else { return change.automatic }
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let files = try folder.write(["ours": ConflictParser.tokenFile(change.ours), "base": ConflictParser.tokenFile(change.base), "theirs": ConflictParser.tokenFile(change.theirs)])
        let result = try await runner.run(["merge-file", "-p", "-q"] + [files[0], files[1], files[2]], accepting: Set(0...255))
        guard result.exitCode == 0 else { return nil }
        return ConflictParser.lines(fromTokens: result.stdout)
    }

    // MARK: Resolving

    /// Writes `text` into the working tree file and stages it, which marks the conflict resolved.
    public func resolveConflict(_ path: String, with text: String, encoding: MergeDocument.Encoding) async throws {
        guard let data = encoding.encode(text) else {
            throw GitError(arguments: ["add", "--", path], exitCode: 1, stderr: "The result cannot be written in the file's encoding.")
        }
        let file = URL(fileURLWithPath: self.path).appendingPathComponent(path)
        WriteActivity.began(self.path)
        defer { WriteActivity.ended(self.path) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        _ = try await runner.runWrite(["add", "--", path])
    }

    /// Takes one whole side of each path into the working tree and stages it; where that side deleted the file, the file goes.
    public func resolveConflicts(_ paths: [String], taking side: ConflictSide) async throws {
        guard !paths.isEmpty else { return }
        let stages = try await conflictStages()
        let present = paths.filter { stages[$0]?.blob(side) != nil }
        let absent = paths.filter { stages[$0] != nil && stages[$0]?.blob(side) == nil }
        if !present.isEmpty {
            _ = try await runner.runWrite(["checkout", side == .ours ? "--ours" : "--theirs", "--"] + present)
            _ = try await runner.runWrite(["add", "--"] + present)
        }
        try await resolveConflictsByDeleting(absent)
    }

    /// Keeps the file where only one side still has it, as for a file the other side deleted: that side's version is taken and staged.
    public func keepConflictedFiles(_ paths: [String]) async throws {
        let stages = try await conflictStages()
        let ours = paths.filter { stages[$0]?.ours != nil }
        let theirs = paths.filter { stages[$0]?.ours == nil && stages[$0]?.theirs != nil }
        try await resolveConflicts(ours, taking: .ours)
        try await resolveConflicts(theirs, taking: .theirs)
    }

    /// Resolves the conflicts by removing the files from the index and the working tree, as for a file one side deleted.
    public func resolveConflictsByDeleting(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.runWrite(["rm", "-q", "-f", "--"] + paths)
    }

    /// Stages the files as they are in the working tree, which marks their conflicts resolved; a file deleted there is staged as deleted.
    public func markConflictsResolved(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.runWrite(["add", "-A", "--"] + paths)
    }

    /// Writes the files with conflict markers again and makes them unmerged, also after they were marked resolved: git keeps the stages of a resolution until the operation ends.
    public func restoreConflictMarkers(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runner.runWrite(["checkout", "-m", "--"] + paths)
    }

    /// The commits of both sides that touch the conflicted paths, newest first: `git log --merge`. Empty outside a merge-like operation.
    public func conflictCommits(touching paths: [String]) async throws -> [ConflictCommit] {
        let result = try await runner.run(["log", "--merge", "--format=%H%x00%an%x00%s", "--"] + paths)
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            return ConflictCommit(id: parts[0], author: parts[1], subject: parts[2])
        }
    }

    /// Opens the working tree file of an unmerged path in the diff tool against one stage, and returns once the tool has closed.
    public func openDiffTool(forConflict path: String, against stage: ConflictStage) async throws {
        _ = try await runner.run(["difftool", "--no-prompt", "--\(stage.rawValue)", "--", path])
    }

    // MARK: Merge tool

    /// The tool `git mergetool --gui` opens here: `merge.guitool`, else `merge.tool`; nil when neither is set, as git would then guess from its built-in list.
    public func mergeToolName() async -> String? {
        for key in [MergeTools.guiToolKey, "merge.tool"] {
            guard let result = try? await runner.run(["config", "--get", key], accepting: [0, 1]) else { continue }
            let name = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Opens the merge tool for one file and returns once it has closed: true when git took the result as resolved and staged it.
    /// `--gui` prefers `merge.guitool`, the tool for windowed use, as the app has no terminal for a tool like vimdiff.
    /// It runs outside the write queue, since the tool stays open for as long as the user needs; git stages the result itself.
    public func openMergeTool(for path: String) async throws -> Bool {
        let result = try await runner.run(["mergetool", "--gui", "--no-prompt", "--", path], accepting: [0, 1])
        return result.exitCode == 0
    }
}

/// One commit of `git log --merge`.
public struct ConflictCommit: Sendable, Equatable {
    public let id: String
    public let author: String
    public let subject: String
}

/// The stage of an unmerged path that the working tree file is compared with: `git diff --base`, `--ours` or `--theirs`.
public enum ConflictStage: String, Sendable {
    case base, ours, theirs
}

/// A folder for the files a git command compares or merges, removed afterwards.
struct TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-merge-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes each file and returns their paths in the order of the given names.
    func write(_ files: KeyValuePairs<String, Data>) throws -> [String] {
        try files.map { name, data in
            let file = url.appendingPathComponent(name)
            try data.write(to: file)
            return file.path
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
