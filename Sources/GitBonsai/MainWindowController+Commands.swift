import AppKit
import GitEngine

/// The window's commands, offered in every tab, and the entry points of the command bar and of the main menu's command items.
extension MainWindowController: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        let (titles, active) = commandTabs
        let several: LocalizedStringResource? = titles.count > 1 ? nil : LocalizedStringResource("window.tabs.onlyOne", defaultValue: "Only one tab is open", bundle: .module)
        return [
            Command(.newTab) { [weak self] in self?.newTab() },
            Command(.openRepository) { [weak self] in self?.openRepository() },
            Command(.clone) { [weak self] in self?.cloneRepository() },
            Command(.closeTab, context: titles.indices.contains(active) ? titles[active] : nil) { [weak self] in self?.closeTab() },
            Command(.reopenClosedTab, blocker: CommandRules.reopenTab(reopenableCount: closedTabs.reopenableCount())) { [weak self] in self?.reopenClosedTab() },
            Command(.nextTab, disabledReason: several) { [weak self] in self?.selectNextTab() },
            Command(.previousTab, disabledReason: several) { [weak self] in self?.selectPreviousTab() },
            Command(.switchTab, disabledReason: several, action: .choose(placeholder: LocalizedStringResource("window.tabs.searchPlaceholder", defaultValue: "Search tabs", bundle: .module)) { [weak self] in
                titles.enumerated().map { index, title in
                    Command(id: "tab.\(index)", title: .verbatim(title), glyph: .symbol("square"), scope: .app, context: index == active ? String(localized: "window.tabs.active", defaultValue: "Active", bundle: .module, comment: "Marks the current tab in the command bar's tab list.") : nil) { self?.showTab(at: index) }
                }
            }),
            Command(.settings) { [weak self] in self?.openSettings(nil) },
        ]
    }

    /// Repository commands of the active tab first, then the window's own. The empty tab only gets the window's.
    func allCommands() -> [Command] {
        let repository = activeRepository
        let state = repository?.commandState ?? RepositoryCommandState()
        return (repository?.allCommands() ?? []) + commands(state)
    }

    func showCommandBar(_ sender: Any?) {
        guard let window else { return }
        commandBar.toggle(in: window, commands: allCommands())
    }

    /// A main-menu item whose `representedObject` is a command id runs that command of the active tab; one that takes an argument opens the command bar at its second list.
    func runMenuCommand(_ sender: NSMenuItem) {
        let commands = allCommands()
        guard let id = sender.representedObject as? String, let command = commands.first(where: { $0.id == id }), let window else { return }
        guard command.isEnabled else { return NSSound.beep() }
        switch command.action {
        case .run(let perform):
            if commandBar.isOpen { commandBar.close() }
            perform()
        case .choose:
            commandBar.open(in: window, commands: commands, step: command)
        }
    }
}
