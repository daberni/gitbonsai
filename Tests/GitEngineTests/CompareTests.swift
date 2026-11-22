import XCTest
@testable import GitEngine

final class CompareTests: XCTestCase {
    /// main: root → a → b → c → merge(feature); feature branches off at a with f1 → f2.
    private func makeRepository() throws -> (FixtureRepo, [String: String]) {
        let fixture = try FixtureRepo()
        var ids: [String: String] = [:]
        ids["root"] = try fixture.commit("root", file: "base.txt")
        ids["a"] = try fixture.commit("a", file: "a.txt")
        try fixture.git("switch", "-q", "-c", "feature")
        ids["f1"] = try fixture.commit("f1", file: "feature.txt", contents: "one\n")
        ids["f2"] = try fixture.commit("f2", file: "feature.txt", contents: "two\n")
        try fixture.git("switch", "-q", "main")
        ids["b"] = try fixture.commit("b", file: "b.txt")
        ids["c"] = try fixture.commit("c", file: "a.txt", contents: "changed a\n")
        try fixture.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        ids["merge"] = try fixture.git("rev-parse", "HEAD")
        return (fixture, ids)
    }

    private func commits(_ repo: Repository, _ ids: [String: String], _ names: [String]) async throws -> [Commit] {
        let all = try await repo.collectLog()
        return try names.map { name in try XCTUnwrap(all.first { $0.id == ids[name] }, name) }
    }

    func testPairOnOneLineHasNoMergeBaseSwitch() async throws {
        let (fixture, ids) = try makeRepository()
        defer { fixture.remove() }
        let repo = Repository(path: fixture.path)
        let comparison = await repo.comparison(of: try await commits(repo, ids, ["c", "a"]))
        guard case .pair(let older, let newer, let base) = comparison else { return XCTFail("\(comparison)") }
        XCTAssertEqual(older.id, ids["a"])
        XCTAssertEqual(newer.id, ids["c"])
        XCTAssertNil(base, "a is an ancestor of c")
        let files = try await repo.changedFiles(from: older.id, to: newer.id)
        XCTAssertEqual(Set(files.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertEqual(files.first { $0.path == "a.txt" }?.stat, DiffStat(added: 1, removed: 1))
    }

    func testPairOnDifferentBranchesComparesFromTheMergeBase() async throws {
        let (fixture, ids) = try makeRepository()
        defer { fixture.remove() }
        let repo = Repository(path: fixture.path)
        let comparison = await repo.comparison(of: try await commits(repo, ids, ["c", "f2"]))
        guard case .pair(let older, let newer, let base) = comparison else { return XCTFail("\(comparison)") }
        XCTAssertEqual(base, ids["a"])
        // Directly, the feature file disappears and main's changes appear; from the merge base only main's changes count.
        let direct = try await repo.changedFiles(from: older.id, to: newer.id)
        XCTAssertEqual(Set(direct.map(\.path)), ["a.txt", "b.txt", "feature.txt"])
        XCTAssertEqual(direct.first { $0.path == "feature.txt" }?.state, .deleted)
        let sinceBase = try await repo.changedFiles(from: try XCTUnwrap(base), to: newer.id)
        XCTAssertEqual(Set(sinceBase.map(\.path)), ["a.txt", "b.txt"])
        let diff = try await repo.diff(of: "a.txt", in: .revisions(base: try XCTUnwrap(base), target: newer.id))
        XCTAssertEqual(diff?.stat, DiffStat(added: 1, removed: 1))
    }

    func testRunOnOneFirstParentLineIsCombinedWhateverTheOrder() async throws {
        let (fixture, ids) = try makeRepository()
        defer { fixture.remove() }
        let repo = Repository(path: fixture.path)
        // The merge's first parent is c, so the run crosses it; the history may interleave the run with the feature commits.
        let comparison = await repo.comparison(of: try await commits(repo, ids, ["merge", "b", "c"]))
        guard case .run(let run) = comparison else { return XCTFail("\(comparison)") }
        XCTAssertEqual(run.map(\.id), [ids["merge"], ids["c"], ids["b"]])
        let base = try await repo.base(before: try XCTUnwrap(run.last))
        XCTAssertEqual(base, ids["a"])
        let files = try await repo.changedFiles(from: base, to: run[0].id)
        XCTAssertEqual(Set(files.map(\.path)), ["a.txt", "b.txt", "feature.txt"])
    }

    func testRunFromTheRootStartsAtTheEmptyTree() async throws {
        let (fixture, ids) = try makeRepository()
        defer { fixture.remove() }
        let repo = Repository(path: fixture.path)
        let comparison = await repo.comparison(of: try await commits(repo, ids, ["b", "a", "root"]))
        guard case .run(let run) = comparison else { return XCTFail("\(comparison)") }
        let base = try await repo.base(before: try XCTUnwrap(run.last))
        let files = try await repo.changedFiles(from: base, to: run[0].id)
        XCTAssertEqual(Set(files.map(\.path)), ["base.txt", "a.txt", "b.txt"])
        XCTAssertTrue(files.allSatisfy { $0.state == .added })
    }

    func testGapsOrOtherBranchesGiveSeparateCommits() async throws {
        let (fixture, ids) = try makeRepository()
        defer { fixture.remove() }
        let repo = Repository(path: fixture.path)
        // b lies between c and a.
        let gapped = await repo.comparison(of: try await commits(repo, ids, ["c", "a", "root"]))
        guard case .separate(let gappedCommits) = gapped else { return XCTFail("\(gapped)") }
        XCTAssertEqual(gappedCommits.map(\.id), [ids["c"], ids["a"], ids["root"]])
        // f2 → f1 → a is a first-parent line too, but b sits on another branch.
        let mixed = await repo.comparison(of: try await commits(repo, ids, ["f2", "b", "f1"]))
        guard case .separate = mixed else { return XCTFail("\(mixed)") }
        let featureLine = await repo.comparison(of: try await commits(repo, ids, ["f2", "f1", "a"]))
        guard case .run = featureLine else { return XCTFail("\(featureLine)") }
    }
}
