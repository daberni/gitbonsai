import Foundation
import XCTest
@testable import GitEngine

final class BranchTreeTests: XCTestCase {
    private func names(_ entries: [BranchTree.Entry<Int>]) -> [String] {
        entries.map {
            switch $0 {
            case .folder(let name, let children): name + "[" + children.map(\.name).joined(separator: ",") + "]"
            case .branch(let name, _): name
            }
        }
    }

    /// Folders used to come first; now they sit among the plain branches where their name puts them.
    func testFoldersAndBranchesSortTogetherByName() {
        let input = ["main", "codex/b", "alpha", "bugfix/z", "bugfix/a", "develop", "Zeta", "codex/a"].enumerated().map { (name: $0.element, item: $0.offset) }
        XCTAssertEqual(names(BranchTree.entries(input)), ["alpha", "bugfix/[a,z]", "codex/[a,b]", "develop", "main", "Zeta"])
    }

    func testFolderSortsByItsNameWithoutSlash() {
        let input = [(name: "release-2", item: 0), (name: "release/1.0", item: 1), (name: "rel", item: 2)]
        XCTAssertEqual(names(BranchTree.entries(input)), ["rel", "release/[1.0]", "release-2"])
    }

    func testNumbersSortByValue() {
        let input = [(name: "v10", item: 0), (name: "v9", item: 1)]
        XCTAssertEqual(names(BranchTree.entries(input)), ["v9", "v10"])
    }
}

final class OutlineStateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "OutlineStateStoreTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testStateSurvivesANewStore() {
        let state = OutlineState(collapsed: ["remote:origin", "local/bugfix/"], known: ["local", "remote:origin"])
        OutlineStateStore(defaults: defaults, key: "outline").save(state, for: "/repo", keepingOnly: ["/repo"])
        XCTAssertEqual(OutlineStateStore(defaults: defaults, key: "outline").state(for: "/repo"), state)
        XCTAssertNil(OutlineStateStore(defaults: defaults, key: "outline").state(for: "/other"))
    }

    func testSavingPrunesRepositoriesNoLongerKnown() {
        let store = OutlineStateStore(defaults: defaults, key: "outline")
        store.save(OutlineState(collapsed: ["a"]), for: "/gone", keepingOnly: [])
        store.save(OutlineState(collapsed: ["b"]), for: "/kept", keepingOnly: ["/gone"])
        store.save(OutlineState(collapsed: ["c"]), for: "/current", keepingOnly: ["/kept"])
        XCTAssertNil(store.state(for: "/gone"))
        XCTAssertEqual(store.state(for: "/kept")?.collapsed, ["b"])
        XCTAssertEqual(store.state(for: "/current")?.collapsed, ["c"], "the saved repository stays even when it is not in the known list")
    }
}
