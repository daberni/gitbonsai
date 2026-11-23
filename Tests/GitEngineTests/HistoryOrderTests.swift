import XCTest
@testable import GitEngine
import GraphLayout

/// The history's order across branches whose commits interleave in time.
final class HistoryOrderTests: XCTestCase {
    private var repo: FixtureRepo!

    override func setUpWithError() throws {
        repo = try FixtureRepo(name: "order")
        // main: base(1) M1(2) M2(4); feature: F1(3) F2(5) off base; rebased: R committed last (6) but authored first (1.5), off base.
        let base = try repo.commit("base", date: "2024-01-01T12:00:00+0000")
        try repo.commit("M1", date: "2024-01-02T12:00:00+0000")
        try repo.git("switch", "-q", "-c", "feature", base)
        try repo.commit("F1", date: "2024-01-03T12:00:00+0000")
        try repo.git("switch", "-q", "main")
        try repo.commit("M2", date: "2024-01-04T12:00:00+0000")
        try repo.git("switch", "-q", "feature")
        try repo.commit("F2", date: "2024-01-05T12:00:00+0000")
        try repo.git("switch", "-q", "-c", "rebased", base)
        try repo.write("file.txt", "R\n")
        try repo.git("add", "-A")
        try repo.git(["commit", "-q", "-m", "R", "--date=2024-01-01T18:00:00+0000"], date: "2024-01-06T12:00:00+0000")
        try repo.git("switch", "-q", "main")
    }

    override func tearDown() {
        repo.remove()
    }

    private func history(_ order: HistoryOrder) async throws -> [Commit] {
        var options = LogOptions()
        options.order = order
        return try await repo.repository.collectLog(options)
    }

    func testDateOrderListsNewestCommitsFirstAcrossBranches() async throws {
        let commits = try await history(.date)
        XCTAssertEqual(commits.map(\.subject), ["R", "F2", "M2", "F1", "M1", "base"])
        XCTAssertEqual(commits.map(\.committerDate), commits.map(\.committerDate).sorted(by: >))
    }

    func testAuthorDateOrderFollowsTheDateTheRowsShow() async throws {
        let commits = try await history(.authorDate)
        XCTAssertEqual(commits.map(\.subject), ["F2", "M2", "F1", "M1", "R", "base"])
        XCTAssertEqual(commits.map(\.authorDate), commits.map(\.authorDate).sorted(by: >))
    }

    func testBranchesTogetherKeepsEachLineInOneRun() async throws {
        let subjects = try await history(.branchesTogether).map(\.subject)
        XCTAssertEqual(subjects.firstIndex(of: "F1"), subjects.firstIndex(of: "F2")! + 1)
        XCTAssertEqual(subjects.firstIndex(of: "M1"), subjects.firstIndex(of: "M2")! + 1)
    }

    func testEveryOrderListsChildrenBeforeParentsAndLaysOut() async throws {
        for order in HistoryOrder.allCases {
            let commits = try await history(order)
            let position = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.id, $0) })
            for commit in commits {
                for parent in commit.parents {
                    XCTAssertGreaterThan(position[parent]!, position[commit.id]!, "\(order)")
                }
            }
            var layout = GraphLayout(pinned: commits.first { $0.subject == "M2" }?.id)
            let rows = commits.map { layout.append($0) }
            XCTAssertEqual(rows.count, commits.count, "\(order)")
            XCTAssertEqual(rows.first { $0.commitID == commits.first { $0.subject == "M2" }?.id }?.lane, 0, "\(order)")
        }
    }

    func testRevListNamesTheSameOrderAsTheLog() async throws {
        for order in HistoryOrder.allCases {
            let log = try await history(order).map(\.id)
            let revList = try await repo.repository.historyOrder(order, stashCommits: [])
            XCTAssertEqual(revList, log, "\(order)")
        }
    }
}
