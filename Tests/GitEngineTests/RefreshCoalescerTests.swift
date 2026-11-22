import XCTest
@testable import GitEngine

final class RefreshCoalescerTests: XCTestCase {
    func testTriggersBeforeTheRunStartsJoinIt() {
        var coalescer = RefreshCoalescer()
        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertFalse(coalescer.request())
        coalescer.begin()
        XCTAssertFalse(coalescer.finish())
        XCTAssertEqual(coalescer.state, .idle)
    }

    func testTriggersDuringARunCauseExactlyOneMore() {
        var coalescer = RefreshCoalescer()
        XCTAssertTrue(coalescer.request())
        coalescer.begin()
        XCTAssertFalse(coalescer.request())
        XCTAssertFalse(coalescer.request())
        XCTAssertTrue(coalescer.finish())
        XCTAssertEqual(coalescer.state, .scheduled)
        coalescer.begin()
        XCTAssertFalse(coalescer.finish())
        XCTAssertTrue(coalescer.request())
    }

    func testFinishWithoutARunChangesNothing() {
        var coalescer = RefreshCoalescer()
        XCTAssertFalse(coalescer.finish())
        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.finish())
        XCTAssertEqual(coalescer.state, .scheduled)
    }
}
