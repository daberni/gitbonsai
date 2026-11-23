import XCTest
@testable import GitEngine

/// A conflicted file in the working tree: git shows its diff as a combined `diff --cc` and lists it twice in `--numstat`.
final class ConflictDiffTests: XCTestCase {
    /// `main` and `feature` both change the middle line of `f.txt`, and `feature` deletes `d.txt` that `main` changed; merging `feature` stops on both.
    static func mergeConflict() throws -> FixtureRepo {
        let fixture = try FixtureRepo()
        try fixture.write("f.txt", "a\nb\nc\n")
        try fixture.write("d.txt", "keep\n")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.write("f.txt", "a\nB feature\nc\n")
        try fixture.git("rm", "-q", "d.txt")
        try fixture.git("commit", "-q", "-am", "feature")
        try fixture.git("switch", "-q", "main")
        try fixture.write("f.txt", "a\nB main\nc\n")
        try fixture.write("d.txt", "changed\n")
        try fixture.git("commit", "-q", "-am", "main")
        XCTAssertThrowsError(try fixture.git("merge", "feature"))
        return fixture
    }

    func testCombinedDiffOfAConflictedFileReadsAgainstOurs() async throws {
        let fixture = try Self.mergeConflict()
        defer { fixture.remove() }

        let diff = try await fixture.repository.diff(of: "f.txt", in: .unstaged)
        let file = try XCTUnwrap(diff, "a conflicted file has a diff: the conflict markers in the working tree")
        XCTAssertEqual(file.path, "f.txt")
        let lines = file.hunks.flatMap(\.lines)
        XCTAssertEqual(lines.filter { $0.kind == .context }.map(\.text), ["a", "B main", "c"], "lines of ours that stay in the working tree")
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["<<<<<<< HEAD", "=======", "B feature", ">>>>>>> feature"], "lines the working tree has beyond ours")
        XCTAssertEqual(lines.first { $0.text == "c" }?.oldNumber, 3)
        XCTAssertEqual(lines.first { $0.text == "c" }?.newNumber, 7)
    }

    func testNumstatOfAConflictedFileKeepsTheCountAgainstOurs() async throws {
        let fixture = try Self.mergeConflict()
        defer { fixture.remove() }

        let stats = try await fixture.repository.workingStats(staged: false)
        XCTAssertEqual(stats["f.txt"], DiffStat(added: 4, removed: 0), "git lists the unmerged path with 0/0 first, then its diff against ours")
        XCTAssertEqual(stats["d.txt"], DiffStat(added: 0, removed: 0), "a path deleted on one side is only listed as unmerged")
    }
}
