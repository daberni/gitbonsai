import AppKit
import GitEngine

extension InteractiveRebaseController: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [Command(.rebaseInteractive, context: state.branch, blocker: CommandRules.rebaseInteractive(state), action: .choose(placeholder: LocalizedStringResource("rebase.command.ontoPlaceholder", defaultValue: "Rebase onto branch or tag", bundle: .module)) { [weak self] in self?.targetChoices() ?? [] })]
    }

    /// Branches and tags to rebase the current branch onto, with the base the commit menu would detect.
    /// A target on the branch's own line rebases in place; one that is not loaded in the history yet cannot open the sheet.
    private func targetChoices() -> [Command] {
        guard let branch = viewModel.currentBranch else { return [] }
        return viewModel.refs.compactMap { ref -> Command? in
            let glyph: Glyph
            switch ref.kind {
            case .localBranch where !ref.isHead: glyph = .laptop
            case .remoteBranch where !ref.name.hasSuffix("/HEAD"): glyph = .cloud
            case .tag: glyph = .tag
            default: return nil
            }
            guard let row = viewModel.rowIndex(of: ref.target) else {
                return Command(id: ref.fullName, title: .verbatim(ref.name), glyph: .glyph(glyph), disabledReason: LocalizedStringResource("rebase.command.notLoaded", defaultValue: "Not in the loaded history", bundle: .module)) {}
            }
            let commit = viewModel.commits[row]
            let inPlace = viewModel.isReachableFromHead(commit.id)
            let reason = inPlace ? inPlaceReason(for: commit) : nil
            return Command(id: ref.fullName, title: .verbatim(ref.name), glyph: .glyph(glyph), context: String(commit.id.prefix(RefString.shortSHA)), disabledReason: reason.map { .verbatim($0) }) { [weak self] in
                self?.openSheet(branch: branch, onto: commit, ref: ref, inPlace: inPlace)
            }
        }
    }

    private func openSheet(branch: String, onto commit: Commit, ref: Ref, inPlace: Bool) {
        let name = switch ref.kind {
        case .localBranch: RefName.branch(ref.name)
        case .tag: RefName.tag(ref.name)
        default: RefName.remoteBranch(ref.name)
        }
        let place = RefString(marked: name)
        guard !inPlace else { return openSheet(branch: branch, onto: commit, targetName: place, detection: .plain(moving: 0)) }
        let repository = viewModel.repository
        let targetRef = ref.kind == .tag ? nil : ref.name
        Task {
            let detection = await repository.detectRebaseBase(of: branch, onto: commit.id, targetRef: targetRef)
            openSheet(branch: branch, onto: commit, targetName: place, detection: detection)
        }
    }
}
