import Foundation
import GitEngine

/// The rows of the empty tab: the recently used repositories, then one group per repository folder, filtered by the search text.
struct WelcomeList {
    struct Entry: Equatable {
        let path: String
        let name: String
        /// The folder of a recent repository, or the path relative to the repository folder.
        let detail: String
        let branch: String?
        let isOpen: Bool
        /// A linked worktree under its main repository.
        let isWorktree: Bool
    }

    struct Section: Equatable {
        let title: String
        let entries: [Entry]
        let isRecents: Bool
    }

    let sections: [Section]
    let isFiltered: Bool
    /// Every entry in display order, which is the order the arrow keys walk.
    var entries: [Entry] { sections.flatMap(\.entries) }

    init(recents: [String], folders: [RepositoryDiscoveryStore.Folder], openPaths: Set<String>, filter: String, recentLimit: Int) {
        let query = filter.trimmingCharacters(in: .whitespaces)
        func matches(_ entry: Entry) -> Bool {
            query.isEmpty || entry.name.localizedStandardContains(query) || entry.detail.localizedStandardContains(query) || (entry.branch?.localizedStandardContains(query) ?? false)
        }
        var sections: [Section] = []
        let recentEntries = recents.map { path in
            Entry(path: path, name: Self.name(path), detail: Self.abbreviated((path as NSString).deletingLastPathComponent), branch: RepositoryDiscovery.branch(ofWorkingTree: path), isOpen: openPaths.contains(path), isWorktree: false)
        }
        let shownRecents = Array(recentEntries.filter(matches).prefix(recentLimit))
        sections.append(Section(title: String(localized: "Recent", bundle: .module, comment: "Welcome page section of recently opened repositories."), entries: shownRecents, isRecents: true))
        for folder in folders {
            let root = RealPath.of(folder.path)
            var entries: [Entry] = []
            for repository in folder.repositories {
                let main = Entry(path: repository.path, name: Self.name(repository.path), detail: Self.relative(repository.path, to: root), branch: repository.branch, isOpen: openPaths.contains(repository.path), isWorktree: false)
                let worktrees = repository.worktrees.map { worktree in
                    Entry(path: worktree.path, name: Self.name(worktree.path), detail: Self.relative(worktree.path, to: root), branch: worktree.branch, isOpen: openPaths.contains(worktree.path), isWorktree: true)
                }
                // A repository stays when it or one of its worktrees matches; its worktrees stay when the repository itself matches.
                let mainMatches = matches(main)
                let shownWorktrees = mainMatches ? worktrees : worktrees.filter(matches)
                guard mainMatches || !shownWorktrees.isEmpty else { continue }
                entries.append(main)
                entries.append(contentsOf: shownWorktrees)
            }
            if !entries.isEmpty || query.isEmpty { sections.append(Section(title: String(localized: "In \(Self.abbreviated(folder.path))", bundle: .module, comment: "Welcome page section of the repositories found in a folder."), entries: entries, isRecents: false)) }
        }
        // While filtering, an empty recents group only stays when nothing else matched, to say so.
        if !query.isEmpty, shownRecents.isEmpty, sections.count > 1 { sections.removeFirst() }
        self.sections = sections
        isFiltered = !query.isEmpty
    }

    private static func name(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Worktrees often live outside the repository folder; those keep their full path.
    private static func relative(_ path: String, to folder: String) -> String {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : abbreviated(path)
    }
}
