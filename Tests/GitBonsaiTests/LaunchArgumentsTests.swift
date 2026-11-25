import XCTest
@testable import GitBonsai

/// Launch arguments mix folders with `-Key value` preferences for the launch; only the folders open as tabs.
final class LaunchArgumentsTests: XCTestCase {
    func testPreferencePairsAreNotFolders() {
        let arguments = ["/Applications/GitBonsai.app/Contents/MacOS/GitBonsai", "-AppleInterfaceStyle", "Dark", "/repo/one", "-AppleLanguages", "(de)", "relative/two"]
        XCTAssertEqual(AppDelegate.folderArguments(arguments), ["/repo/one", "relative/two"])
    }

    func testOnlyTheExecutableMeansNoFolders() {
        XCTAssertEqual(AppDelegate.folderArguments(["GitBonsai"]), [])
    }
}
