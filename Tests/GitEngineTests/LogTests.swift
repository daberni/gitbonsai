import Foundation
import XCTest
@testable import GitEngine

final class LogTests: XCTestCase {
    func testLinearHistoryWithUnicodeSubjectAndMultilineBody() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("Initial")
        try fixture.write("file.txt", "second\n")
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "Füge Ünïcode hinzu 🌳", "-m", "First paragraph.\n\nSecond paragraph after a blank line.\nThird line.")
        let second = try fixture.git("rev-parse", "HEAD")

        let commits = try await fixture.repository.collectLog()

        XCTAssertEqual(commits.map(\.id), [second, first])
        XCTAssertEqual(commits[0].subject, "Füge Ünïcode hinzu 🌳")
        XCTAssertEqual(commits[0].body, "First paragraph.\n\nSecond paragraph after a blank line.\nThird line.")
        XCTAssertEqual(commits[0].parents, [first])
        XCTAssertEqual(commits[1].parents, [])
        XCTAssertEqual(commits[1].body, "")
        XCTAssertEqual(commits[0].authorName, "Fixture")
        XCTAssertEqual(commits[0].authorEmail, "fixture@example.com")
        XCTAssertEqual(commits[0].authorDate, Date(timeIntervalSince1970: 1704110400))
    }

    func testMergeAndOctopusParents() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("base")
        try fixture.git("checkout", "-q", "-b", "a")
        let a = try fixture.commit("a", file: "a.txt")
        try fixture.git("checkout", "-q", "main")
        try fixture.git("checkout", "-q", "-b", "b")
        let b = try fixture.commit("b", file: "b.txt")
        try fixture.git("checkout", "-q", "main")
        try fixture.git("checkout", "-q", "-b", "c")
        let c = try fixture.commit("c", file: "c.txt")
        try fixture.git("checkout", "-q", "main")
        try fixture.git("merge", "-q", "--no-ff", "-m", "merge a", "a")
        let merge = try fixture.git("rev-parse", "HEAD")
        try fixture.git("merge", "-q", "--no-ff", "-m", "octopus", "b", "c")
        let octopus = try fixture.git("rev-parse", "HEAD")

        let commits = try await fixture.repository.collectLog()
        let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })

        XCTAssertEqual(commits.first?.id, octopus)
        XCTAssertEqual(byID[merge]?.parents, [base, a])
        XCTAssertEqual(byID[octopus]?.parents, [merge, b, c])
        XCTAssertTrue(byID[octopus]?.isMerge ?? false)
        XCTAssertEqual(commits.count, 6)
        // Topological order: every parent appears after its child.
        let position = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.id, $0) })
        for commit in commits {
            for parent in commit.parents {
                XCTAssertGreaterThan(position[parent]!, position[commit.id]!)
            }
        }
    }

    func testOnlyBranchesTagsAndOwnHeadMakeTheHistory() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let base = try fixture.commit("Base")
        let worktree = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-wt-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        try fixture.git("worktree", "add", "-q", "--detach", worktree)
        try fixture.git("-C", worktree, "commit", "-q", "--allow-empty", "-m", "Only in the worktree")
        let detached = try fixture.git("-C", worktree, "rev-parse", "HEAD")
        try fixture.git("commit", "-q", "--allow-empty", "-m", "Tool snapshot")
        try fixture.git("update-ref", "refs/codex/snapshots/one", "HEAD")
        try fixture.git("reset", "-q", "--hard", base)

        let commits = try await fixture.repository.collectLog()
        XCTAssertEqual(commits.map(\.id), [base])

        // From inside that worktree its own HEAD belongs to the history.
        let fromWorktree = try await Repository(path: worktree).collectLog()
        XCTAssertEqual(fromWorktree.map(\.id), [detached, base])
    }

    func testEmptyRepositoryYieldsNoCommits() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }

        let commits = try await fixture.repository.collectLog()

        XCTAssertEqual(commits, [])
    }

    func testOptionsLimit() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one", file: "a.txt")
        try fixture.commit("two", file: "b.txt")
        try fixture.commit("three", file: "a.txt")

        var limited = LogOptions()
        limited.limit = 2
        let twoNewest = try await fixture.repository.collectLog(limited)
        XCTAssertEqual(twoNewest.map(\.subject), ["three", "two"])
    }

    func testChunkedFeedingProducesIdenticalCommits() throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("Initial")
        try fixture.git("commit", "-q", "--allow-empty", "-m", "Zweiter Commit", "-m", "Body with\n\nblank lines and ünïcode")
        try fixture.git("commit", "-q", "--allow-empty", "-m", "Third")
        let raw = try runRaw(["log", "--all", LogFormat.formatArgument], in: fixture)

        var whole = LogParser()
        let expected = whole.feed(raw) + whole.finish()
        XCTAssertEqual(expected.count, 3)
        XCTAssertEqual(expected[1].body, "Body with\n\nblank lines and ünïcode")

        for chunkSize in [1, 7, 64] {
            var parser = LogParser()
            var commits: [Commit] = []
            var offset = 0
            while offset < raw.count {
                let end = min(offset + chunkSize, raw.count)
                commits += parser.feed(raw.subdata(in: offset..<end))
                offset = end
            }
            commits += parser.finish()
            XCTAssertEqual(commits, expected, "chunk size \(chunkSize)")
        }
    }

    private func runRaw(_ arguments: [String], in fixture: FixtureRepo) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitRunner.defaultGitPath())
        process.arguments = arguments
        process.currentDirectoryURL = fixture.url
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
