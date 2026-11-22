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
