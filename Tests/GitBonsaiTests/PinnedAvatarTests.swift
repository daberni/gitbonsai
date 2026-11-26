import XCTest
@testable import GitBonsai

/// Where a commit's avatar sits when the graph is wider than its column.
@MainActor
final class PinnedAvatarTests: XCTestCase {
    private let lanes: ClosedRange<CGFloat> = 100...250

    private func strips(contentWidth: CGFloat, scrollX: CGFloat = 0) -> HistoryColumns.AvatarStrips? {
        var columns = HistoryColumns.standard
        columns.graph = 160
        columns.graphContentWidth = contentWidth
        columns.graphScrollX = scrollX
        return columns.avatarStrips(lanes: lanes)
    }

    private func centre(_ range: ClosedRange<CGFloat>) -> CGFloat { (range.lowerBound + range.upperBound) / 2 }

    func testGraphThatFitsHasNoStripsAndPinsNothing() {
        XCTAssertNil(strips(contentWidth: 160))
        XCTAssertNil(HistoryColumns.pinnedAvatarX(nodeX: 400, strips: nil))
    }

    func testAvatarBetweenTheStripsStaysOnItsLane() throws {
        let strips = try XCTUnwrap(strips(contentWidth: 400))
        XCTAssertNil(HistoryColumns.pinnedAvatarX(nodeX: strips.left.upperBound + Theme.Graph.nodeRadius, strips: strips))
        XCTAssertNil(HistoryColumns.pinnedAvatarX(nodeX: strips.right.lowerBound - Theme.Graph.nodeRadius, strips: strips))
    }

    func testAvatarSlidesIntoEitherStripAndStopsAtItsCentre() throws {
        let strips = try XCTUnwrap(strips(contentWidth: 400))
        let enteringRight = strips.right.lowerBound - Theme.Graph.nodeRadius + 1
        XCTAssertEqual(HistoryColumns.pinnedAvatarX(nodeX: enteringRight, strips: strips), enteringRight)
        XCTAssertEqual(HistoryColumns.pinnedAvatarX(nodeX: lanes.upperBound + 200, strips: strips), centre(strips.right))
        let enteringLeft = strips.left.upperBound + Theme.Graph.nodeRadius - 1
        XCTAssertEqual(HistoryColumns.pinnedAvatarX(nodeX: enteringLeft, strips: strips), enteringLeft)
        XCTAssertEqual(HistoryColumns.pinnedAvatarX(nodeX: lanes.lowerBound - 200, strips: strips), centre(strips.left))
    }

    func testStripsFadeInTowardsTheEndsOfTheScrollRange() throws {
        let width = Theme.Graph.pinStripWidth
        let start = try XCTUnwrap(strips(contentWidth: 400))
        XCTAssertEqual(start.leftOpacity, 0)
        XCTAssertEqual(start.rightOpacity, 1)
        let partway = try XCTUnwrap(strips(contentWidth: 400, scrollX: width / 2))
        XCTAssertEqual(partway.leftOpacity, 0.5, accuracy: 0.001)
        let end = try XCTUnwrap(strips(contentWidth: 400, scrollX: 240))
        XCTAssertEqual(end.leftOpacity, 1)
        XCTAssertEqual(end.rightOpacity, 0)
    }

    func testPinnedAvatarDimsGraduallyAsItsLaneRunsPast() {
        let width = Theme.Graph.pinStripWidth
        XCTAssertEqual(HistoryColumns.pinnedAvatarAlpha(nodeX: 200, pinnedX: 200), 1)
        XCTAssertEqual(HistoryColumns.pinnedAvatarAlpha(nodeX: 200 + width / 2, pinnedX: 200), (1 + Theme.Graph.pinnedAvatarAlpha) / 2, accuracy: 0.001)
        XCTAssertEqual(HistoryColumns.pinnedAvatarAlpha(nodeX: 200 - 3 * width, pinnedX: 200), Theme.Graph.pinnedAvatarAlpha, accuracy: 0.001)
    }
}
