import GitEngine
import XCTest
@testable import GitBonsai

/// What a local tag's menu offers per remote, from what each remote has.
final class TagRowsTests: XCTestCase {
    private let here = TagTarget(objectID: "a1", commitID: "a1")
    private let there = TagTarget(objectID: "b2", commitID: "b2")

    func testEachRemoteGetsOnlyThePushAndDeleteThatApply() {
        let tag = Tag(name: "v1", commitID: "a1", isAnnotated: false, date: Date(), subject: "")
        let rows = TagRows(tags: [tag], remotes: ["lacking", "same", "other", "silent"], states: [
            ("lacking", ["v1": .localOnly]),
            ("same", ["v1": .same]),
            ("other", ["v1": .differs(local: here, remote: there)]),
        ])

        let offers = rows.remoteOffers("v1", remotes: ["lacking", "same", "other", "silent"])

        XCTAssertEqual(offers.map(\.remote), ["lacking", "same", "other", "silent"])
        XCTAssertEqual(offers.map(\.push), [.add, nil, .replace, .add], "push where the tag is missing, replace where it differs; a remote that has not answered is offered the push")
        XCTAssertEqual(offers.map(\.canDelete), [false, true, true, true], "delete only where the remote may have it")
    }
}
