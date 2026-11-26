import GitEngine
import XCTest
@testable import GitBonsai

final class ClosedTabsTests: XCTestCase {
    func testRepeatedPopsGoFurtherBack() {
        var stack = ClosedTabs()
        stack.push(path: "/a", index: 0)
        stack.push(path: "/b", index: 2)
        XCTAssertEqual(stack.pop { _ in true }, ClosedTabs.Entry(path: "/b", index: 2))
        XCTAssertEqual(stack.pop { _ in true }, ClosedTabs.Entry(path: "/a", index: 0))
        XCTAssertNil(stack.pop { _ in true })
    }

    func testMissingFoldersAreSkippedAndNotCounted() {
        var stack = ClosedTabs()
        stack.push(path: "/kept", index: 1)
        stack.push(path: "/gone", index: 0)
        let exists: (String) -> Bool = { $0 != "/gone" }
        XCTAssertEqual(stack.reopenableCount(exists: exists), 1)
        XCTAssertEqual(stack.pop(exists: exists)?.path, "/kept")
        XCTAssertEqual(stack.reopenableCount(exists: exists), 0)
    }

    func testClosingAPathAgainMovesItToTheTopOnce() {
        var stack = ClosedTabs()
        stack.push(path: "/a", index: 0)
        stack.push(path: "/b", index: 1)
        stack.push(path: "/a", index: 3)
        XCTAssertEqual(stack.entries, [ClosedTabs.Entry(path: "/b", index: 1), ClosedTabs.Entry(path: "/a", index: 3)])
    }

    func testTheStackKeepsOnlyTheMostRecentEntries() {
        var stack = ClosedTabs()
        for n in 0..<(ClosedTabs.limit + 5) { stack.push(path: "/\(n)", index: 0) }
        XCTAssertEqual(stack.entries.count, ClosedTabs.limit)
        XCTAssertEqual(stack.entries.first?.path, "/5")
    }

    func testTheRuleBlocksWithoutAReopenableTab() {
        XCTAssertEqual(CommandRules.reopenTab(reopenableCount: 0), .noClosedTab)
        XCTAssertNil(CommandRules.reopenTab(reopenableCount: 1))
    }
}
