import XCTest
@testable import GitEngine

final class DiffTests: XCTestCase {
    /// Twenty numbered lines; the two edits sit far enough apart for git to emit two hunks.
    private func numbered(changing changes: [Int: String] = [:]) -> String {
        (1...20).map { changes[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func testTwoHunksWithLineNumbersAndStat() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "numbers.txt", contents: numbered())
        try fixture.write("numbers.txt", numbered(changing: [2: "line two", 18: "line eighteen"]))

        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "numbers.txt", in: .unstaged))
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.stat, DiffStat(added: 2, removed: 2))
        let second = diff.hunks[1]
        let removed = try XCTUnwrap(second.lines.first { $0.kind == .removed })
        let added = try XCTUnwrap(second.lines.first { $0.kind == .added })
        XCTAssertEqual(removed.oldNumber, 18)
        XCTAssertNil(removed.newNumber)
        XCTAssertEqual(added.newNumber, 18)
        XCTAssertEqual(added.text, "line eighteen")
        XCTAssertEqual(second.lines.last?.oldNumber, 20)
        XCTAssertEqual(second.lines.last?.newNumber, 20)
    }

    func testRenameNewFileAndMissingNewline() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "old name.txt", contents: numbered())
        try fixture.git("mv", "old name.txt", "new name.txt")
        try fixture.write("new name.txt", numbered(changing: [20: "last line"]).dropLast() + "")
        try fixture.write("fresh.txt", "hello\n")
        try fixture.git("add", "-A")
        let commit = try fixture.commit("change", file: "other.txt", contents: "x\n")
        let history = try await fixture.repository.collectLog()
        XCTAssertEqual(history[0].id, commit)

        let renamed = try await XCTUnwrapAsync(await fixture.repository.diff(of: "new name.txt", originalPath: "old name.txt", in: .commit(history[0])))
        XCTAssertEqual(renamed.path, "new name.txt")
        XCTAssertEqual(renamed.oldPath, "old name.txt")
        let last = try XCTUnwrap(renamed.hunks.last?.lines.last)
        XCTAssertEqual(last.text, "last line")
        XCTAssertTrue(last.missingNewline)

        let fresh = try await XCTUnwrapAsync(await fixture.repository.diff(of: "fresh.txt", in: .commit(history[0])))
        XCTAssertTrue(fresh.isNew)
        XCTAssertEqual(fresh.stat, DiffStat(added: 1, removed: 0))

        let files = try await fixture.repository.changedFiles(of: history[0])
        XCTAssertEqual(files.first { $0.path == "new name.txt" }?.stat, DiffStat(added: 1, removed: 1), "numstat of a rename is keyed by the new path")
    }

    func testRenameCarriesSimilarityAndPureRenameHasNoHunks() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "src/äpfel/alt.txt", contents: numbered())
        try fixture.write("keep.txt", numbered())
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "keep")
        try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent("src/birnen"), withIntermediateDirectories: true)
        try fixture.git("mv", "src/äpfel/alt.txt", "src/birnen/neu.txt")
        try fixture.git("mv", "keep.txt", "kept.txt")
        try fixture.write("kept.txt", numbered(changing: [10: "line ten"]))
        try fixture.git("add", "-A")

        let pure = try await XCTUnwrapAsync(await fixture.repository.diff(of: "src/birnen/neu.txt", originalPath: "src/äpfel/alt.txt", in: .staged))
        XCTAssertEqual(pure.change, .renamed)
        XCTAssertEqual(pure.oldPath, "src/äpfel/alt.txt")
        XCTAssertEqual(pure.similarity, 100)
        XCTAssertTrue(pure.hunks.isEmpty)
        XCTAssertTrue(pure.hasNoContentChange)

        let edited = try await XCTUnwrapAsync(await fixture.repository.diff(of: "kept.txt", originalPath: "keep.txt", in: .staged))
        XCTAssertEqual(edited.change, .renamed)
        XCTAssertTrue((80..<100).contains(edited.similarity ?? 0), "similarity \(String(describing: edited.similarity))")
        XCTAssertFalse(edited.hasNoContentChange)
    }

    func testModeOnlyChangeHasBothModesAndNoHunks() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "run.sh", contents: "echo hi\n")
        try fixture.git("update-index", "--chmod=+x", "run.sh")

        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "run.sh", in: .staged))
        XCTAssertEqual(diff.change, .modified)
        XCTAssertEqual(diff.oldMode, "100644")
        XCTAssertEqual(diff.newMode, "100755")
        XCTAssertTrue(diff.modeChanged)
        XCTAssertTrue(diff.hasNoContentChange)
        XCTAssertNil(diff.similarity)
    }

    /// `-M` never reports copies, `-C` does; the parser keeps them apart from renames.
    func testCopyHeaderIsACopyWithSimilarity() {
        let output = """
        diff --git a/a.txt b/b.txt
        similarity index 87%
        copy from a.txt
        copy to b.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -one
        +two

        """
        let diff = try? XCTUnwrap(DiffParser.parse(Data(output.utf8)).first)
        XCTAssertEqual(diff?.change, .copied)
        XCTAssertEqual(diff?.oldPath, "a.txt")
        XCTAssertEqual(diff?.path, "b.txt")
        XCTAssertEqual(diff?.similarity, 87)
    }

    func testStageAndUnstageOneHunk() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "numbers.txt", contents: numbered())
        try fixture.write("numbers.txt", numbered(changing: [2: "line two", 18: "line eighteen"]))
        let repo = fixture.repository

        let unstaged = try await XCTUnwrapAsync(await repo.diff(of: "numbers.txt", in: .unstaged))
        try await repo.stage(unstaged.hunks[1], of: unstaged)

        let staged = try await XCTUnwrapAsync(await repo.diff(of: "numbers.txt", in: .staged))
        XCTAssertEqual(staged.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["line eighteen"])
        let rest = try await XCTUnwrapAsync(await repo.diff(of: "numbers.txt", in: .unstaged))
        XCTAssertEqual(rest.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["line two"])

        try await repo.unstage(staged.hunks[0], of: staged)
        let afterUnstage = try await repo.diff(of: "numbers.txt", in: .staged)
        XCTAssertNil(afterUnstage)
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("numbers.txt"), encoding: .utf8), numbered(changing: [2: "line two", 18: "line eighteen"]), "staging never touches the working tree")
    }

    /// `diff.noprefix` drops the `a/` and `b/` that `git apply -p1` strips; `diff.mnemonicPrefix` replaces them with `i/` and `w/`.
    func testHunkStagingIgnoresTheUsersDiffPrefixes() async throws {
        for setting in [["diff.noprefix", "true"], ["diff.mnemonicPrefix", "true"]] {
            let fixture = try FixtureRepo()
            defer { fixture.remove() }
            try fixture.git(["config"] + setting)
            try fixture.commit("base", file: "numbers.txt", contents: numbered())
            try fixture.write("numbers.txt", numbered(changing: [2: "line two", 18: "line eighteen"]))
            let repo = fixture.repository

            let unstaged = try await XCTUnwrapAsync(await repo.diff(of: "numbers.txt", in: .unstaged))
            XCTAssertEqual(unstaged.path, "numbers.txt", setting[0])
            try await repo.stage(unstaged.hunks[1], of: unstaged)
            XCTAssertEqual(try fixture.git("diff", "--cached", "--numstat"), "1\t1\tnumbers.txt", setting[0])
        }
    }

    /// A Latin-1 file is not UTF-8; the patch must carry its bytes as they are, not their decoded replacement characters.
    func testHunkOfANonUTF8FileStagesItsOwnBytes() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let latin1 = { (text: String) in text.data(using: .isoLatin1)! }
        let base = (1...20).map { "Zeile \($0) \u{e4}\u{f6}\u{fc}" }.joined(separator: "\n") + "\n"
        try latin1(base).write(to: fixture.url.appendingPathComponent("latin1.txt"))
        try fixture.git("add", "latin1.txt")
        try fixture.git("commit", "-q", "-m", "base")
        let changed = base.replacingOccurrences(of: "Zeile 2 ", with: "Zeile zwei ").replacingOccurrences(of: "Zeile 18 ", with: "Zeile achtzehn \u{df} ")
        try latin1(changed).write(to: fixture.url.appendingPathComponent("latin1.txt"))
        let repo = fixture.repository

        let unstaged = try await XCTUnwrapAsync(await repo.diff(of: "latin1.txt", in: .unstaged))
        XCTAssertEqual(unstaged.hunks.count, 2)
        try await repo.stage(unstaged.hunks[1], of: unstaged)
        let staged = try await repo.runner.run(["show", ":latin1.txt"]).stdout
        let expected = latin1(base.replacingOccurrences(of: "Zeile 18 ", with: "Zeile achtzehn \u{df} "))
        XCTAssertEqual(staged, expected)
    }

    func testUntrackedFileCanBeStagedByHunk() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.write("notes/new file.txt", "a\nb\n")
        let repo = fixture.repository

        let diff = try await XCTUnwrapAsync(await repo.diff(of: "notes/new file.txt", in: .untracked))
        XCTAssertTrue(diff.isNew)
        XCTAssertEqual(diff.path, "notes/new file.txt")
        try await repo.stage(diff.hunks[0], of: diff)

        let entry = try await repo.status().entries.first { $0.path == "notes/new file.txt" }
        XCTAssertEqual(entry?.indexState, .added)
        XCTAssertEqual(entry?.isUntracked, false)
        let untrackedAfterwards = try await repo.diff(of: "notes/new file.txt", in: .untracked)
        XCTAssertNil(untrackedAfterwards, "a staged file has no untracked change left")
    }

    func testDiscardingOneHunkKeepsTheOtherAndTheIndex() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "numbers.txt", contents: numbered())
        try fixture.write("numbers.txt", numbered(changing: [10: "line ten"]))
        try fixture.git("add", "numbers.txt")
        try fixture.write("numbers.txt", numbered(changing: [2: "line two", 10: "line ten", 18: "line eighteen"]))
        let repo = fixture.repository
        let stagedBefore = try await repo.diff(of: "numbers.txt", in: .staged)

        let unstaged = try await XCTUnwrapAsync(await repo.diff(of: "numbers.txt", in: .unstaged))
        XCTAssertEqual(unstaged.hunks.count, 2)
        try await repo.discard(unstaged.hunks[0], of: unstaged)

        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("numbers.txt"), encoding: .utf8), numbered(changing: [10: "line ten", 18: "line eighteen"]))
        let stagedAfter = try await repo.diff(of: "numbers.txt", in: .staged)
        XCTAssertEqual(stagedAfter, stagedBefore, "discarding never touches the index")
    }

    func testFullFileShowsEveryLineOnceWithTheChangesInPlace() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "numbers.txt", contents: numbered())
        try fixture.write("numbers.txt", numbered(changing: [2: "line two", 18: "line eighteen"]))

        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "numbers.txt", in: .unstaged, fullFile: true))
        XCTAssertEqual(diff.hunks.count, 1)
        var expected: [DiffLine] = [DiffLine(kind: .context, text: "line 1", oldNumber: 1, newNumber: 1)]
        expected.append(DiffLine(kind: .removed, text: "line 2", oldNumber: 2, newNumber: nil))
        expected.append(DiffLine(kind: .added, text: "line two", oldNumber: nil, newNumber: 2))
        expected += (3...17).map { (number: Int) in DiffLine(kind: .context, text: "line \(number)", oldNumber: number, newNumber: number) }
        expected.append(DiffLine(kind: .removed, text: "line 18", oldNumber: 18, newNumber: nil))
        expected.append(DiffLine(kind: .added, text: "line eighteen", oldNumber: nil, newNumber: 18))
        expected += (19...20).map { (number: Int) in DiffLine(kind: .context, text: "line \(number)", oldNumber: number, newNumber: number) }
        XCTAssertEqual(diff.hunks[0].lines, expected)
    }

    func testFullFileOfADeletedFileShowsItsOldContent() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "numbers.txt", contents: numbered())
        try fixture.git("rm", "-q", "numbers.txt")

        let diff = try await XCTUnwrapAsync(await fixture.repository.diff(of: "numbers.txt", in: .staged, fullFile: true))
        XCTAssertTrue(diff.isDeleted)
        XCTAssertEqual(diff.hunks.flatMap(\.lines), (1...20).map { (number: Int) in DiffLine(kind: .removed, text: "line \(number)", oldNumber: number, newNumber: nil) })
    }

    func testDiscardingAFileKeepsItsStagedChanges() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "numbers.txt", contents: numbered())
        try fixture.write("numbers.txt", numbered(changing: [2: "line two"]))
        try fixture.git("add", "numbers.txt")
        try fixture.write("numbers.txt", numbered(changing: [2: "line two", 18: "line eighteen"]))
        let repo = fixture.repository

        try await repo.discardUnstagedChanges(["numbers.txt"])

        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("numbers.txt"), encoding: .utf8), numbered(changing: [2: "line two"]), "the working tree falls back to the staged content")
        let unstaged = try await repo.diff(of: "numbers.txt", in: .unstaged)
        XCTAssertNil(unstaged)
        let staged = try await XCTUnwrapAsync(await repo.diff(of: "numbers.txt", in: .staged))
        XCTAssertEqual(staged.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text), ["line two"])
    }

    /// Staged and unstaged edits, a staged new file and a rename all go back to HEAD; untracked files and a merge in progress stay.
    func testDiscardingAllChangesRestoresHeadAndKeepsUntrackedFilesAndTheMerge() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base", file: "a.txt", contents: "a\n")
        try fixture.commit("more", file: "sub dir/b.txt", contents: "b\n")
        try fixture.git("switch", "-q", "-c", "other")
        try fixture.commit("theirs", file: "c.txt", contents: "theirs\n")
        try fixture.git("switch", "-q", "-")
        try fixture.commit("ours", file: "c.txt", contents: "ours\n")
        _ = try? fixture.git("merge", "-q", "other")
        try fixture.git("checkout", "--ours", "c.txt")
        try fixture.git("add", "c.txt")
        try fixture.write("a.txt", "staged\n")
        try fixture.git("add", "a.txt")
        try fixture.write("a.txt", "staged and more\n")
        try fixture.git("mv", "sub dir/b.txt", "renamed.txt")
        try fixture.write("added.txt", "new\n")
        try fixture.git("add", "added.txt")
        try fixture.write("untracked.txt", "keep\n")

        try await fixture.repository.discardAllChanges()

        XCTAssertEqual(try fixture.git("status", "--porcelain", "--untracked-files=all"), "?? untracked.txt")
        XCTAssertEqual(try String(contentsOf: fixture.url.appendingPathComponent("a.txt"), encoding: .utf8), "a\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("added.txt").path))
        XCTAssertNoThrow(try fixture.git("rev-parse", "--verify", "-q", "MERGE_HEAD"), "the merge stays in progress")
    }

    func testRemovingAnUntrackedFileLeavesOthersAlone() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.write("notes/new file.txt", "a\n")
        try fixture.write("notes/keep.txt", "b\n")
        try fixture.write("staged.txt", "c\n")
        try fixture.git("add", "staged.txt")
        let repo = fixture.repository

        try await repo.removeUntracked(["notes/new file.txt"])

        let manager = FileManager.default
        XCTAssertFalse(manager.fileExists(atPath: fixture.url.appendingPathComponent("notes/new file.txt").path))
        XCTAssertTrue(manager.fileExists(atPath: fixture.url.appendingPathComponent("notes/keep.txt").path))
        let entries = try await repo.status().entries
        XCTAssertEqual(entries.first { $0.path == "staged.txt" }?.indexState, .added)
        XCTAssertNil(entries.first { $0.path == "notes/new file.txt" })
    }

    func testDiscardingTheHunkOfAnUntrackedFileRemovesIt() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.write("notes/new file.txt", "a\nb\n")
        try fixture.write("notes/keep.txt", "c\n")
        let repo = fixture.repository

        let diff = try await XCTUnwrapAsync(await repo.diff(of: "notes/new file.txt", in: .untracked))
        XCTAssertEqual(diff.hunks.count, 1)
        try await repo.discard(diff.hunks[0], of: diff)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("notes/new file.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("notes/keep.txt").path))
        let entries = try await repo.status().entries
        XCTAssertNil(entries.first { $0.path == "notes/new file.txt" }, "the file is neither in the working tree nor in the index")
    }
}

/// `XCTUnwrap` for values produced by an async call.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
