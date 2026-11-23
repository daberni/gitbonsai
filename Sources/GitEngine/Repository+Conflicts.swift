import Foundation

extension Repository {
    /// Files larger than this are offered as whole sides only, like binaries; the merge of their text is not read.
    static let conflictTextLimit = 8 << 20

    // MARK: Reading

    /// The stages of every unmerged path, keyed by path.
    public func conflictStages() async throws -> [String: ConflictStages] {
        let result = try await runner.run(["ls-files", "-u", "-z"])
        return ConflictParser.parseStages(result.stdout)
    }

    /// One unmerged path with its stages and its content: for text on both sides the three-way merge of the stages, aligned from `git diff` of each side against the base, independent of what the working tree holds now.
    /// Throws when the path is not unmerged.
    public func conflict(at path: String) async throws -> Conflict {
        let listed = try await runner.run(["ls-files", "-u", "-z", "--", path])
        guard let stages = ConflictParser.parseStages(listed.stdout)[path] else {
            throw GitError(arguments: ["ls-files", "-u", "--", path], exitCode: 1, stderr: "\(path) has no unresolved conflict.")
        }
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

    /// Takes one whole side into the working tree and stages it.
    public func resolveConflict(_ path: String, taking side: ConflictSide) async throws {
        _ = try await runner.runWrite(["checkout", side == .ours ? "--ours" : "--theirs", "--", path])
        _ = try await runner.runWrite(["add", "--", path])
    }

    /// Resolves the conflict by removing the file from the index and the working tree, as for a file one side deleted.
    public func resolveConflictByDeleting(_ path: String) async throws {
        _ = try await runner.runWrite(["rm", "-q", "-f", "--", path])
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
