import AppKit
import GitEngine

extension OperationBannerController: CommandProvider {
    /// Only while a rebase, cherry-pick, revert or merge waits; outside one these commands have nothing to act on and are not listed.
    func commands(_ state: RepositoryCommandState) -> [Command] {
        guard let kind = state.operation else { return [] }
        let label = kind.label
        return [
            Command(id: "operation.continue", title: "\(label) fortsetzen", keywords: ["continue"], glyph: .symbol("play"), blocker: CommandRules.continueOperation(state)) { [weak self] in self?.perform(.continue) },
            // A merge has no --skip.
            kind == .merge ? nil : Command(id: "operation.skip", title: "\(label) überspringen", keywords: ["skip"], glyph: .symbol("forward"), blocker: CommandRules.abortOperation(state)) { [weak self] in self?.perform(.skip) },
            Command(id: "operation.abort", title: "\(label) abbrechen …", keywords: ["abort"], glyph: .glyph(.xmark), blocker: CommandRules.abortOperation(state)) { [weak self] in self?.perform(.abort) },
        ].compactMap { $0 }
    }
}
