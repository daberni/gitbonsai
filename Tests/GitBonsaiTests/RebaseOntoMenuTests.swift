import GitEngine
import XCTest
@testable import GitBonsai

/// The one-click "Rebase <branch> onto <commit>": only the branch's own commits when their base is clear, a plain rebase when it is not.
@MainActor
final class RebaseOntoMenuTests: XCTestCase {
    private func subjects(_ fixture: FixtureRepo, _ range: String) throws -> [String] {
        try fixture.git("log", "--format=%s", range).split(separator: "\n").map(String.init)
    }

    /// main: base - m1; parent: base - p1 - p2; stacked: p2 - s1 - s2, checked out.
    private func stackedFixture() throws -> (fixture: FixtureRepo, main: String) {
        let fixture = try FixtureRepo()
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "parent")
        try fixture.commit("p1", file: "p1.txt")
        try fixture.commit("p2", file: "p2.txt")
        try fixture.git("switch", "-q", "-c", "stacked")
        try fixture.commit("s1", file: "s1.txt")
        try fixture.commit("s2", file: "s2.txt")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "stacked")
        return (fixture, main)
    }

    func testClearBaseMovesOnlyTheBranchsOwnCommitsAndSaysWhatStayed() async throws {
        let (fixture, main) = try stackedFixture()
        defer { fixture.remove() }
        let tab = TabFixture(fixture)
        defer { tab.context.lifecycle.close() }
        try await tab.load()

        let menu = tab.menus.rowMenu(forRow: try tab.row(of: main))
        try XCTUnwrap(menu.entry("Rebase stacked onto main")).run()

        try await waitUntil { (try? self.subjects(fixture, "main..stacked")) == ["s2", "s1"] }
        try await waitUntil { !tab.prompter.toasts.isEmpty }
        XCTAssertEqual(tab.prompter.toasts, ["Rebased only stacked's own 2 commits, without parent"])
    }

    /// The sidebar's branch menu runs the same rebase as the history's entry.
    func testSidebarRebaseMovesOnlyTheBranchsOwnCommitsToo() async throws {
        let (fixture, _) = try stackedFixture()
        defer { fixture.remove() }
        let tab = TabFixture(fixture)
        defer { tab.context.lifecycle.close() }
        try await tab.load()

        let menu = tab.menus.menu(for: .branch(try tab.ref("main")), in: .sidebar)
        try XCTUnwrap(menu.entry("Rebase stacked onto main")).run()

        try await waitUntil { (try? self.subjects(fixture, "main..stacked")) == ["s2", "s1"] }
        try await waitUntil { !tab.prompter.toasts.isEmpty }
        XCTAssertEqual(tab.prompter.toasts, ["Rebased only stacked's own 2 commits, without parent"])
    }

    /// Two equally near bases on both sides of a merge: nothing is left out, git rebases every commit.
    func testAmbiguousBaseRunsAPlainRebase() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        try fixture.git("switch", "-q", "-c", "x")
        try fixture.commit("x1", file: "x.txt")
        try fixture.git("switch", "-q", "-c", "y", "main")
        try fixture.commit("y1", file: "y.txt")
        try fixture.git("switch", "-q", "-c", "work", "x")
        try fixture.git("merge", "-q", "--no-edit", "y")
        try fixture.commit("w1", file: "w1.txt")
        try fixture.git("switch", "-q", "main")
        let main = try fixture.commit("m1", file: "m1.txt")
        try fixture.git("switch", "-q", "work")
        let tab = TabFixture(fixture)
        defer { tab.context.lifecycle.close() }
        try await tab.load()

        let menu = tab.menus.rowMenu(forRow: try tab.row(of: main))
        try XCTUnwrap(menu.entry("Rebase work onto main")).run()

        try await waitUntil { (try? self.subjects(fixture, "main..work").sorted()) == ["w1", "x1", "y1"] }
        XCTAssertEqual(tab.prompter.toasts, [], "nothing was left out")
    }
}
