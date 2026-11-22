import XCTest
@testable import GitEngine

final class ChangedFilesTests: XCTestCase {
    private func commits(_ repo: Repository) async throws -> [Commit] {
        var result: [Commit] = []
        for try await commit in repo.log() { result.append(commit) }
        return result
    }

    func testAddModifyRenameAndRootCommit() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.write("keep.txt", "one\n")
        try fixture.write("old name.txt", String(repeating: "same line\n", count: 20))
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "root")
        try fixture.write("keep.txt", "two\n")
        try fixture.write("new.txt", "fresh\n")
        try fixture.git("mv", "old name.txt", "neuer name ü.txt")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "change")

        let repo = Repository(path: fixture.path)
        let history = try await commits(repo)
        let changed = try await repo.changedFiles(of: history[0])
        let byPath = Dictionary(uniqueKeysWithValues: changed.map { ($0.path, $0) })
        XCTAssertEqual(byPath["keep.txt"]?.state, .modified)
        XCTAssertEqual(byPath["new.txt"]?.state, .added)
        XCTAssertEqual(byPath["neuer name ü.txt"]?.state, .renamed)
        XCTAssertEqual(byPath["neuer name ü.txt"]?.originalPath, "old name.txt")
        XCTAssertEqual(changed.count, 3)

        let root = try await repo.changedFiles(of: history[1])
        XCTAssertEqual(Set(root.map(\.path)), ["keep.txt", "old name.txt"])
        XCTAssertTrue(root.allSatisfy { $0.state == .added })
    }
}
