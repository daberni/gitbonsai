import AppKit
import GitEngine

extension OperationBannerController: CommandProvider {
    /// Only while a rebase, cherry-pick, revert or merge waits; outside one these commands have nothing to act on and are not listed.
    func commands(_ state: RepositoryCommandState) -> [Command] {
        guard let kind = state.operation else { return [] }
        let label = kind.label
        return [
            Command(id: "operation.continue", title: LocalizedStringResource("operation.command.continue", defaultValue: "Continue \(label)", bundle: .module), keywords: Command.searchWords(LocalizedStringResource("operation.command.continueKeywords", defaultValue: "continue, resume", bundle: .module)), glyph: .symbol("play"), blocker: CommandRules.continueOperation(state)) { [weak self] in self?.perform(.continue) },
            // A merge has no --skip.
            kind == .merge ? nil : Command(id: "operation.skip", title: LocalizedStringResource("operation.command.skip", defaultValue: "Skip \(label)", bundle: .module), keywords: Command.searchWords(LocalizedStringResource("operation.command.skipKeywords", defaultValue: "skip", bundle: .module)), glyph: .symbol("forward"), blocker: CommandRules.abortOperation(state)) { [weak self] in self?.perform(.skip) },
            Command(id: "operation.abort", title: LocalizedStringResource("operation.command.abort", defaultValue: "Abort \(label)…", bundle: .module), keywords: Command.searchWords(LocalizedStringResource("operation.command.abortKeywords", defaultValue: "abort, cancel", bundle: .module)), glyph: .glyph(.xmark), blocker: CommandRules.abortOperation(state)) { [weak self] in self?.perform(.abort) },
        ].compactMap { $0 }
    }
}
