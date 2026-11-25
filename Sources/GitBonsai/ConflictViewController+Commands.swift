import AppKit
import GitEngine

extension ConflictViewController: CommandProvider {
    /// Only while the conflict view shows a file. Both ways to resolve it stay at hand here, whichever one "Resolve…" opens.
    func commands(_ state: RepositoryCommandState) -> [Command] {
        guard let conflict else { return [] }
        let keywords = Command.searchWords(LocalizedStringResource("conflict.command.keywords", defaultValue: "conflict, merge, resolve, mergetool", bundle: .module))
        var commands: [Command] = []
        if case .text = conflict.content {
            commands.append(Command(id: "conflict.window", title: LocalizedStringResource("conflict.command.window", defaultValue: "Resolve in merge window", bundle: .module, comment: "Command that opens the conflicted file in the app's merge window"), keywords: keywords, glyph: .symbol("rectangle.split.3x1")) { [weak self] in self?.openWindow() })
        }
        if let mergeTool {
            commands.append(Command(id: "conflict.mergeTool", title: LocalizedStringResource("conflict.command.mergeTool", defaultValue: "Open in \(mergeTool)", bundle: .module, comment: "Command that opens the conflicted file in git's merge tool; the argument is git's name of the tool"), keywords: keywords, glyph: .symbol("arrow.up.forward.app")) { [weak self] in self?.openMergeTool() })
        }
        return commands
    }
}
