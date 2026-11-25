import XCTest
@testable import GitBonsai

/// The menu bar as data: its sections place each command once, take what the tab offers, and keep the shortcuts `docs/screens.md` lists.
@MainActor
final class MainMenuTests: XCTestCase {
    private func section(_ title: String) throws -> MainMenu.Section {
        try XCTUnwrap(MainMenu.sections.first { $0.title.text == title })
    }

    private func command(_ id: String, _ title: String, disabledBecause reason: LocalizedStringResource? = nil) -> Command {
        Command(id: id, title: .verbatim(title), glyph: .symbol("circle"), disabledReason: reason) {}
    }

    /// Every shortcut is taken once across the menu bar; two items with the same key equivalent would leave one unreachable.
    func testNoShortcutIsTakenTwice() {
        let shortcuts = MainMenu.sections.flatMap { MainMenu.groups(for: $0, commands: [:], order: []).joined() }.compactMap(\.shortcut).map(\.display)
        XCTAssertEqual(shortcuts.count, Set(shortcuts).count, "duplicates: \(Dictionary(grouping: shortcuts, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
    }

    /// The shortcuts of `docs/screens.md` §6 belong to these menu bar items.
    func testShortcutsOfTheDocumentedCommands() {
        let byShortcut = Dictionary(MainMenu.sections.flatMap { MainMenu.groups(for: $0, commands: [:], order: []).joined() }.compactMap { entry in entry.shortcut.map { ($0.display, entry.plainTitle) } }, uniquingKeysWith: { first, _ in first })
        let documented = [
            "⌘,": "Settings…",
            "⇧⌘P": "Command bar…",
            "⇧⌘F": "Fetch all Remotes",
            "⇧⌘L": "Pull",
            "⇧⌘U": "Push",
            "⌘E": "Edit Commit Message",
            "⌘B": "New Branch…",
        ]
        for (shortcut, title) in documented {
            XCTAssertEqual(byShortcut[shortcut], title, shortcut)
        }
    }

    /// Without a tab the commands keep their specs' titles; families and optional entries leave no empty group.
    func testRepositoryMenuWithoutATab() throws {
        let groups = MainMenu.groups(for: try section("Repository"), commands: [:], order: [])
        XCTAssertEqual(groups.first?.map(\.plainTitle), ["Fetch all Remotes", "Fetch Tags from all Remotes"])
        XCTAssertEqual(groups[1].map(\.plainTitle), ["Pull"])
        XCTAssertTrue(groups.allSatisfy { !$0.isEmpty })
    }

    /// A family lists the tab's commands of its prefix that have no place of their own, in the tab's order; an optional entry shows only while offered, with the reason the command gives.
    func testFamiliesAndOptionalEntriesFollowTheTab() throws {
        let offered = [
            command("fetch", "Fetch all Remotes"),
            command("fetch.origin", "Fetch origin"),
            command("pull", "Pull"),
            command("pull.rebase", "Pull with rebase"),
            command(CommandSpec.setUpstreamAndPull.id, "Set Upstream and Pull…", disabledBecause: .verbatim("No remote branches")),
        ]
        let groups = MainMenu.groups(for: try section("Repository"), commands: Dictionary(uniqueKeysWithValues: offered.map { ($0.id, $0) }), order: offered.map(\.id))
        XCTAssertEqual(groups[0].map(\.plainTitle), ["Fetch all Remotes", "Fetch origin", "Fetch Tags from all Remotes"])
        XCTAssertEqual(groups[1].map(\.plainTitle), ["Pull", "Pull with rebase", "Set Upstream and Pull…"])
        XCTAssertEqual(groups[1].last?.disabledReason, "No remote branches")
    }
}
