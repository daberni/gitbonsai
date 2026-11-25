import Foundation
import GitEngine

/// What a context menu is about.
enum MenuSubject {
    /// A local or remote branch.
    case branch(Ref)
    case tag(String)
    case worktree(WorktreeInfo, isCurrent: Bool)
    case stash(String)
    case remote(String)
    /// A commit of the history, by its row.
    case commit(row: Int)
}

/// The toolbar's split buttons that open a menu.
enum ToolbarMenu {
    case fetch, pull, push, stash
}

/// Assembles every context menu of the sidebar, its Tags and Stashes lists, the history and the file lists, and the menus of the toolbar's split buttons, as data from what each subject's actions offer.
/// A history menu zips a ref section with the commit section, so a combined menu orders its entries by meaning: go there, sync, integrate with the current branch, remove, create, change, copy.
/// A pill's menu zips its ref section with the commit section. A row's menu does the same when the commit has a single branch pill; with several pills each pill becomes a submenu at the top, and the commit section follows.
/// The commit section alone offers Copy SHA; ref sections add only Copy name.
@MainActor
final class MenuBuilder {
    private let viewModel: GraphViewModel
    private let pasteboard: Pasteboard
    private let checkout: CheckoutUseCase
    private let commitActions: CommitActions
    private let branches: BranchActions
    private let tags: TagActions
    private let fastForward: FastForwardUseCase
    private let stashes: StashActions
    private let worktrees: WorktreeActions
    private let remotes: RemoteActions
    private let fetch: FetchUseCase
    private let pull: PullUseCase
    private let push: PushUseCase
    private let files: FileActions

    init(context: RepositoryContext, checkout: CheckoutUseCase, commitActions: CommitActions, branches: BranchActions, tags: TagActions, fastForward: FastForwardUseCase, stashes: StashActions, worktrees: WorktreeActions, remotes: RemoteActions, fetch: FetchUseCase, pull: PullUseCase, push: PushUseCase, files: FileActions) {
        viewModel = context.model
        pasteboard = context.app.pasteboard
        self.checkout = checkout
        self.commitActions = commitActions
        self.branches = branches
        self.tags = tags
        self.fastForward = fastForward
        self.stashes = stashes
        self.worktrees = worktrees
        self.remotes = remotes
        self.fetch = fetch
        self.pull = pull
        self.push = push
        self.files = files
    }

    // MARK: Menus

    /// The menu of a subject where it is shown, as groups of entries; empty groups are left out when the menu is made.
    func menu(for subject: MenuSubject, in context: MenuContext) -> [[MenuEntry]] {
        switch subject {
        case .branch(let ref): branches.sections(for: ref, in: context).groups
        case .tag(let name): context == .sidebar ? tags.groups(for: name) : []
        case .worktree(let info, let isCurrent): worktrees.groups(for: info, isCurrent: isCurrent)
        case .remote(let name): remotes.groups(for: name)
        case .stash(let id): stashMenu(id, in: context)
        case .commit(let row): context == .sidebar ? [] : historyMenu(row: row)
        }
    }

    /// The menu of a history row: a stash row gets the stash menu, a commit row its refs and the commit section.
    func rowMenu(forRow index: Int) -> [[MenuEntry]] {
        if let stash = stashID(at: index) { return menu(for: .stash(stash), in: .historyRow(refs: [])) }
        guard let commit = commit(at: index) else { return [] }
        return menu(for: .commit(row: index), in: .historyRow(refs: pills(of: commit).map(\.ref)))
    }

    /// The menu of one ref pill of a history row: the pill's ref section zipped with the commit section.
    func pillMenu(forRow index: Int, ref: PillRef) -> [[MenuEntry]] {
        guard let commit = commit(at: index) else { return [] }
        return combined(refSections(ref, commit: commit), commit: commit, index: index, pills: pills(of: commit).map(\.ref), subject: ref)
    }

    private func historyMenu(row index: Int) -> [[MenuEntry]] {
        guard let commit = commit(at: index) else { return [] }
        let all = pills(of: commit).map(\.ref)
        let subjects = all.filter { !refSections($0, commit: commit).isEmpty }
        if subjects.count == 1, case .branch = subjects[0] {
            return combined(refSections(subjects[0], commit: commit), commit: commit, index: index, pills: all, subject: subjects[0])
        }
        let leading = MenuSections(refs: subjects.map { MenuEntry(Self.title(of: $0), submenu: refSections($0, commit: commit).groups) })
        return (leading + commitSections(commit, index: index, pills: all, subject: nil)).groups
    }

    /// The branch's own "Rebase main onto X" joins the commit section's rebase variants, which offer it as one entry with a submenu.
    private func combined(_ ref: MenuSections, commit: Commit, index: Int, pills: [PillRef], subject: PillRef) -> [[MenuEntry]] {
        var ref = ref
        let allCommits = ref.integrate.first { $0.role == .rebaseAllCommits }
        ref.integrate.removeAll { $0.role == .rebaseAllCommits }
        return (ref + commitSections(commit, index: index, pills: pills, subject: subject, rebaseAllCommits: allCommits)).groups
    }

    /// The Stashes list's menu; the history's stash row adds Copy SHA at the end, in the copy group.
    private func stashMenu(_ id: String, in context: MenuContext) -> [[MenuEntry]] {
        let groups = stashes.groups(for: id)
        let copy = context.isHistory ? [MenuEntry.copySHA(id, to: pasteboard)] : []
        return [groups.show, groups.takeBack, groups.drop, groups.create, copy]
    }

    /// The menu of a toolbar split button; its first enabled entry is what a click on the button's main part runs.
    func toolbarMenu(_ menu: ToolbarMenu) -> [[MenuEntry]] {
        switch menu {
        case .fetch: fetch.groups()
        case .pull: pull.groups()
        case .push: push.groups()
        case .stash: stashes.toolbarGroups()
        }
    }

    /// The menu of the files selected in a file list: index operations, external apps, copying, and what rewrites the files.
    func fileMenu(for selected: [FileRowView.Model]) -> [[MenuEntry]] {
        files.groups(for: selected)
    }

    /// The diff's options with their current states; `change` edits the options when an entry is chosen.
    /// Ignoring all whitespace and only its amount exclude each other.
    static func diffOptions(_ options: DiffOptions, change: @escaping @MainActor (_ edit: (inout DiffOptions) -> Void) -> Void) -> [[MenuEntry]] {
        func option(_ title: String, isOn: Bool, toolTip: String?, _ edit: @escaping (inout DiffOptions) -> Void) -> MenuEntry {
            var entry = MenuEntry(RefString(verbatim: title)) { change(edit) }
            entry.isChecked = isOn
            entry.toolTip = toolTip
            return entry
        }
        let invisibles = option(String(localized: "diff.options.invisibles", defaultValue: "Show invisible characters", bundle: .module, comment: "Diff option: mark tabs, trailing spaces, line endings and characters without a glyph"), isOn: options.showsInvisibles, toolTip: nil) { $0.showsInvisibles.toggle() }
        let words = option(String(localized: "diff.options.wordDiff", defaultValue: "Word Diff", bundle: .module, comment: "Diff option: mark changed words within a line instead of whole lines"), isOn: options.wordDiff, toolTip: "git diff --word-diff") { $0.wordDiff.toggle() }
        let ignoreAll = option(String(localized: "diff.options.ignoreWhitespace", defaultValue: "Ignore Whitespace", bundle: .module, comment: "Diff option: leave out every whitespace difference, git diff -w"), isOn: options.whitespace.ignoring == .all, toolTip: "git diff -w --ignore-cr-at-eol") { $0.whitespace.ignoring = $0.whitespace.ignoring == .all ? .nothing : .all }
        let ignoreAmount = option(String(localized: "diff.options.ignoreWhitespaceAmount", defaultValue: "Ignore Whitespace amount", bundle: .module, comment: "Diff option: leave out changes in the amount of whitespace but not whitespace where there was none, git diff -b"), isOn: options.whitespace.ignoring == .changes, toolTip: "git diff -b --ignore-cr-at-eol") { $0.whitespace.ignoring = $0.whitespace.ignoring == .changes ? .nothing : .changes }
        let blankLines = option(String(localized: "diff.options.ignoreBlankLines", defaultValue: "Ignore blank Lines", bundle: .module, comment: "Diff option: leave out added or removed empty lines, git diff --ignore-blank-lines"), isOn: options.whitespace.ignoresBlankLines, toolTip: "git diff --ignore-blank-lines") { $0.whitespace.ignoresBlankLines.toggle() }
        return [[invisibles], [words], [ignoreAll, ignoreAmount, blankLines]]
    }

    // MARK: Sections

    /// A branch pill joins a local branch and its same-named remote branches: the local branch's entries fill the groups, each remote branch leads as a submenu titled with its pill.
    /// A pill with a single remote branch and no local one fills the groups with that remote branch's entries.
    private func refSections(_ ref: PillRef, commit: Commit) -> MenuSections {
        switch ref {
        case .branch(let name):
            let refs = viewModel.refsByCommit[commit.id] ?? []
            let local = refs.first { $0.kind == .localBranch && $0.name == name }
            let remotes = refs.filter { ref in
                guard case .remoteBranch(let remote) = ref.kind else { return false }
                return ref.name == "\(remote)/\(name)"
            }
            if local == nil, remotes.count == 1, let remote = remotes.first { return branches.sections(for: remote, in: .historyPill) }
            let submenus = remotes.compactMap { remote -> MenuEntry? in
                let sections = branches.sections(for: remote, in: .historyPill)
                guard !sections.isEmpty else { return nil }
                return MenuEntry(RefString(marked: RefName.remoteBranch(remote.name)), submenu: sections.groups)
            }
            return MenuSections(refs: submenus) + (local.map { branches.sections(for: $0, in: .historyPill) } ?? MenuSections())
        case .tag(let name):
            return tags.localTagSections(name, commit: commit.id, checkout: false)
        case .detachedHead:
            // HEAD is the commit itself; the commit section has everything it offers.
            return MenuSections()
        case .other(let name):
            return MenuSections(copy: [MenuEntry(LocalizedStringResource("common.copyName", defaultValue: "Copy name", bundle: .module)) { [pasteboard] in pasteboard.copy(name) }])
        }
    }

    /// The fast-forward to the commit itself only shows where no branch pill already offers it by name.
    /// Create Worktree… preselects the menu's local branch (`subject`) when it can have a worktree; otherwise it starts from the commit.
    private func commitSections(_ commit: Commit, index: Int, pills: [PillRef], subject: PillRef?, rebaseAllCommits: MenuEntry? = nil) -> MenuSections {
        let named = pills.contains { if case .branch = $0 { true } else { false } }
        let moveHere = named ? nil : fastForward.entry(to: .commit(commit.id))
        var worktreeForBranch: (() -> Void)?
        if case .branch(let name) = subject, let local = viewModel.refsByCommit[commit.id]?.first(where: { $0.kind == .localBranch && $0.name == name }), branches.canCreateWorktree(for: local) {
            worktreeForBranch = { [weak branches] in branches?.createWorktree(for: name) }
        }
        var sections = commitActions.sections(for: commit, moveHere: moveHere, worktreeForBranch: worktreeForBranch, rebaseAllCommits: rebaseAllCommits)
        if let detached = checkout.detachedEntry(forRow: index) { sections.goThere.append(detached) }
        if let squash = commitActions.squash.entry(for: commit) { sections.change.append(squash) }
        return sections
    }

    // MARK: Parts

    private func commit(at index: Int) -> Commit? {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return nil }
        return viewModel.commits[index]
    }

    private func stashID(at index: Int) -> String? {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .stash else { return nil }
        return viewModel.commits[index].id
    }

    private func pills(of commit: Commit) -> [PillModel] {
        HistoryRowModel.pills(for: viewModel.refsByCommit[commit.id] ?? [], branchesElsewhere: viewModel.branchesInOtherWorktrees, detachedHead: viewModel.currentBranch == nil && viewModel.headSHA == commit.id)
    }

    private static func title(of ref: PillRef) -> RefString {
        switch ref {
        case .branch(let name): RefString(marked: RefName.branch(name))
        case .tag(let name): RefString(marked: RefName.tag(name))
        case .detachedHead: RefString(verbatim: "HEAD")
        case .other(let name): RefString(verbatim: name)
        }
    }
}

enum RefMenus {
    /// The ref as a pill inside a menu title.
    static func pillName(of ref: Ref) -> String {
        switch ref.kind {
        case .localBranch: RefName.branch(ref.name)
        case .remoteBranch: RefName.remoteBranch(ref.name)
        case .tag: RefName.tag(ref.name)
        default: RefName.commit(ref.target)
        }
    }
}
