import AppKit
import GitEngine

/// What the file list's menu of conflicted files and the Conflicts section's "Resolve all" menu run: take a side, keep or delete the file, mark it resolved or bring its markers back, open it, compare it and list the commits behind it.
/// The sides are named by the branch or commit they come from, never "ours" and "theirs". Binary files are offered whole sides and deletion only.
@MainActor
final class ConflictActions {
    private let viewModel: GraphViewModel
    private let prompter: any Prompting
    /// The names of the two sides for the operation that stopped.
    var sides: () -> ConflictSides = { ConflictSides(ours: "HEAD", theirs: "MERGE_HEAD") }
    /// Opens a conflicted file in the conflict view.
    var onOpen: ((String) -> Void)?
    /// The files changed outside the tab's status read; open diffs read them again.
    var onChange: (() -> Void)?
    /// The conflicts whose sides git takes for binary, read again with every status that has conflicts.
    private var binary: Set<String> = []
    private var mergeTool: String?
    private var generation = 0

    init(context: RepositoryContext) {
        viewModel = context.model
        prompter = context.prompter
    }

    /// Reads which conflicts are binary and the merge tool's name; called whenever the status changed.
    func update() {
        generation += 1
        let current = generation
        guard viewModel.status?.hasConflicts == true else {
            binary = []
            return
        }
        let repository = viewModel.repository
        Task {
            let binary = (try? await repository.binaryConflictPaths()) ?? []
            let tool = await repository.mergeToolName()
            guard current == generation else { return }
            self.binary = binary
            mergeTool = tool
        }
    }

    // MARK: Menus

    /// The menu of conflicted files in the file list: resolving, then opening and comparing; the file list adds its own copy, open and Trash entries.
    func groups(for paths: [String]) -> [[MenuEntry]] {
        guard !paths.isEmpty else { return [] }
        return [resolveItems(paths), inspectItems(paths)]
    }

    /// The menu of the Conflicts section's "Resolve all": every open conflict at once.
    func resolveAllGroups() -> [[MenuEntry]] {
        let paths = viewModel.status?.conflicted.map(\.path) ?? []
        guard !paths.isEmpty else { return [] }
        return [resolveItems(paths), [logEntry(paths)]]
    }

    private func resolveItems(_ paths: [String]) -> [MenuEntry] {
        let sides = sides()
        let kinds = paths.compactMap { path in viewModel.status?.conflicted.first { $0.path == path }?.conflict }
        let oneSided = !kinds.isEmpty && kinds.allSatisfy { [.deletedByUs, .deletedByThem, .addedByUs, .addedByThem].contains($0) }
        let hasBinary = paths.contains(where: binary.contains)
        var items = [
            entry(LocalizedStringResource("conflict.menu.accept", defaultValue: "Accept \(sides.theirs)", bundle: .module, comment: "Takes one side's whole file; the argument is the branch or commit it comes from."), note: "git checkout --theirs") { try await $0.resolveConflicts(paths, taking: .theirs) },
            entry(LocalizedStringResource("conflict.menu.accept", defaultValue: "Accept \(sides.ours)", bundle: .module, comment: "Takes one side's whole file; the argument is the branch or commit it comes from."), note: "git checkout --ours") { try await $0.resolveConflicts(paths, taking: .ours) },
        ]
        if oneSided {
            items.append(entry(LocalizedStringResource("conflict.menu.keepFile", defaultValue: "Keep File", bundle: .module, comment: "Resolves a conflict where one side deleted the file by keeping the other side's file."), note: "git add") { try await $0.keepConflictedFiles(paths) })
        }
        items.append(entry(LocalizedStringResource("conflict.menu.deleteFile", defaultValue: "Delete File", bundle: .module, comment: "Resolves a conflict by deleting the file."), note: "git rm") { try await $0.resolveConflictsByDeleting(paths) })
        let textOnly: String? = hasBinary ? String(localized: "conflict.menu.binaryReason", defaultValue: "Binary files can only take one side or be deleted", bundle: .module) : nil
        var mark = entry(LocalizedStringResource("conflict.menu.markResolved", defaultValue: "Mark as resolved", bundle: .module), note: "git add") { try await $0.markConflictsResolved(paths) }
        mark.disabledReason = textOnly
        var markers = entry(LocalizedStringResource("conflict.menu.restoreMarkers", defaultValue: "Restore Conflict Markers", bundle: .module), note: "git checkout -m") { try await $0.restoreConflictMarkers(paths) }
        markers.disabledReason = textOnly
        return items + [mark, markers]
    }

    /// Opening and comparing work on one file; for several they stay visible, disabled, with the reason.
    private func inspectItems(_ paths: [String]) -> [MenuEntry] {
        let sides = sides()
        let single = paths.count == 1 ? paths[0] : nil
        let isBinary = single.map(binary.contains) ?? false
        let reason: String? = single == nil ? String(localized: "conflict.menu.oneAtATime", defaultValue: "Opens one file at a time", bundle: .module) : isBinary ? String(localized: "conflict.menu.binaryReason", defaultValue: "Binary files can only take one side or be deleted", bundle: .module) : nil
        var open = MenuEntry(LocalizedStringResource("conflict.menu.openConflictView", defaultValue: "Open in Conflict View", bundle: .module)) { [weak self] in if let single { self?.onOpen?(single) } }
        open.disabledReason = single == nil ? reason : nil
        let toolTitle: LocalizedStringResource = mergeTool.map { tool -> LocalizedStringResource in LocalizedStringResource("conflict.menu.openMergeTool", defaultValue: "Open in \(tool)", bundle: .module, comment: "Opens the conflicted file in git's merge tool; the argument is git's name of the tool") } ?? LocalizedStringResource("conflict.menu.openMergeToolDefault", defaultValue: "Open in Merge Tool", bundle: .module)
        var tool = MenuEntry(toolTitle) { [weak self] in if let single { self?.openMergeTool(single) } }
        tool.disabledReason = reason
        tool.toolTip = "git mergetool --gui"
        let compares: [(LocalizedStringResource, ConflictStage)] = [
            (LocalizedStringResource("conflict.menu.compareBase", defaultValue: "with the common Base", bundle: .module, comment: "Entry of the Compare submenu: the working file against the merge base."), .base),
            (LocalizedStringResource("conflict.menu.compareSide", defaultValue: "with \(sides.ours)", bundle: .module, comment: "Entry of the Compare submenu; the argument is the branch or commit of one side."), .ours),
            (LocalizedStringResource("conflict.menu.compareSide", defaultValue: "with \(sides.theirs)", bundle: .module, comment: "Entry of the Compare submenu; the argument is the branch or commit of one side."), .theirs),
        ]
        var compare = MenuEntry(LocalizedStringResource("conflict.menu.compare", defaultValue: "Compare in Diff Tool", bundle: .module), submenu: [compares.map { title, stage in
            var item = MenuEntry(title) { [weak self] in if let single { self?.compare(single, against: stage) } }
            item.toolTip = "git difftool --\(stage.rawValue)"
            return item
        }])
        compare.disabledReason = reason
        return [open, tool, compare, logEntry(paths)]
    }

    private func logEntry(_ paths: [String]) -> MenuEntry {
        var log = MenuEntry(LocalizedStringResource("conflict.menu.log", defaultValue: "Show Commits behind the Conflict", bundle: .module)) { [weak self] in self?.showCommits(paths) }
        log.toolTip = "git log --merge"
        return log
    }

    /// A resolving entry: runs on the repository, refreshes the tab and reports git's message on failure.
    private func entry(_ title: LocalizedStringResource, note: String, _ operation: @escaping @Sendable (Repository) async throws -> Void) -> MenuEntry {
        var item = MenuEntry(title) { [weak self] in self?.run(note: note, operation) }
        item.toolTip = note
        return item
    }

    // MARK: Running

    private func run(note: String, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        Task {
            do {
                try await operation(repository)
                await viewModel.refresh(note: note)
            } catch {
                await viewModel.refresh(note: nil)
                prompter.report(error, title: LocalizedStringResource("failure.conflict.notResolved", defaultValue: "Conflict not resolved", bundle: .module))
            }
            onChange?()
        }
    }

    private func openMergeTool(_ path: String) {
        let repository = viewModel.repository
        Task {
            do {
                _ = try await repository.openMergeTool(for: path)
                await viewModel.refresh(note: "git mergetool --gui")
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.conflict.mergeToolNotStarted", defaultValue: "Couldn’t Start Merge Tool", bundle: .module))
            }
            onChange?()
        }
    }

    private func compare(_ path: String, against stage: ConflictStage) {
        let repository = viewModel.repository
        Task {
            do {
                try await repository.openDiffTool(forConflict: path, against: stage)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.file.diffToolNotStarted", defaultValue: "Couldn’t Start Diff Tool", bundle: .module))
            }
        }
    }

    /// `git log --merge` in a sheet: the commits of both sides that touch the files, which explain how the conflict came about.
    private func showCommits(_ paths: [String]) {
        let repository = viewModel.repository
        Task {
            do {
                let commits = try await repository.conflictCommits(touching: paths)
                let details = commits.map { "\($0.id.prefix(RefString.shortSHA))  \($0.subject)  (\($0.author))" }.joined(separator: "\n")
                prompter.showSheet(title: LocalizedStringResource("conflict.log.title", defaultValue: "Commits behind the Conflict", bundle: .module), summary: LocalizedStringResource("conflict.log.summary", defaultValue: "\(commits.count) commits of both sides touch the conflicted files (git log --merge).", bundle: .module), details: details.isEmpty ? nil : details, actions: [])
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.conflict.logFailed", defaultValue: "Commits not listed", bundle: .module))
            }
        }
    }
}
