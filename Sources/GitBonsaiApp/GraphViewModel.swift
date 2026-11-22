import Foundation
import GitEngine
import GraphLayout

struct WorktreeInfo: Sendable, Identifiable {
    var id: String { worktree.path }
    let worktree: Worktree
    /// Nil when the worktree folder is missing or its status could not be read.
    let status: RepositoryStatus?
}

/// Owns everything one repository window shows: the streamed commit list with its layout, refs, stashes, worktrees and the working directory status.
///
/// Commits are appended in batches so the table inserts rows a few hundred at a time; the first batch is flushed immediately.
@MainActor
final class GraphViewModel {
    enum RowKind { case commit, merge, stash, wip }

    static let wipID = "WIP"

    private(set) var commits: [Commit] = []
    private(set) var rows: [GraphRow] = []
    private(set) var kinds: [RowKind] = []
    private(set) var refs: [Ref] = []
    private(set) var refsByCommit: [String: [Ref]] = [:]
    private(set) var stashes: [Stash] = []
    private(set) var stashesByCommit: [String: Stash] = [:]
    private(set) var worktrees: [WorktreeInfo] = []
    private(set) var status: RepositoryStatus?
    private(set) var lastFetch: Date?
    private(set) var statusText = "Loading…"
    private(set) var isLoading = false
    private(set) var maxLaneCount = 1

    var onRowsAppended: ((_ range: Range<Int>) -> Void)?
    /// Refs, reachability, worktrees or status changed: visible rows and the sidebar need a redraw.
    var onMetadataChanged: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?

    let repository: Repository
    private var layout = GraphLayout()
    private var loadTask: Task<Void, Never>?
    private var reachableFromHead: Set<String> = []
    private var rowIndexByID: [String: Int] = [:]
    /// Index and untracked helper commits of stashes. They follow their stash in topological order and are skipped.
    private var hiddenCommitIDs: Set<String> = []

    init(repositoryPath: String) {
        repository = Repository(path: repositoryPath)
    }

    var headSHA: String? { status?.branch.headSHA }
    var currentBranch: String? { status?.branch.branch }

    /// Full ref names of branches checked out in a worktree other than this window's.
    var branchesInOtherWorktrees: [String: Worktree] {
        var result: [String: Worktree] = [:]
        for info in worktrees {
            guard let branch = info.worktree.branch, info.worktree.branchName != currentBranch else { continue }
            result[branch] = info.worktree
        }
        return result
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            status = try? await repository.status()
            await loadStashes()
            async let refsTask: Void = loadRefs()
            async let worktreesTask: Void = loadWorktrees()
            async let fetchTask: Void = loadLastFetch()
            await streamLog()
            _ = await (refsTask, worktreesTask, fetchTask)
            computeReachability()
            isLoading = false
            onMetadataChanged?()
            setStatus(statusText)
        }
    }

    func rowIndex(of commitID: String) -> Int? { rowIndexByID[commitID] }

    func isReachableFromHead(_ commitID: String) -> Bool {
        reachableFromHead.isEmpty || reachableFromHead.contains(commitID)
    }

    func fetch() async {
        setStatus("git fetch --all --prune …")
        do {
            _ = try await repository.runner.runWrite(["fetch", "--all", "--prune"])
            await loadLastFetch()
            await loadRefs()
            onMetadataChanged?()
            setStatus("Fetch abgeschlossen")
        } catch {
            setStatus("fetch fehlgeschlagen: \(error)")
        }
    }

    private func loadRefs() async {
        do {
            let loaded = try await repository.refs()
            var grouped: [String: [Ref]] = [:]
            for ref in loaded { grouped[ref.target, default: []].append(ref) }
            refs = loaded
            refsByCommit = grouped
            onMetadataChanged?()
        } catch {
            setStatus("refs failed: \(error)")
        }
    }

    private func loadStashes() async {
        guard let loaded = try? await repository.stashes() else { return }
        stashes = loaded
        stashesByCommit = Dictionary(loaded.map { ($0.commitID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func loadWorktrees() async {
        guard let list = try? await repository.worktrees() else { return }
        let gitPath = repository.runner.gitPath
        let infos = await withTaskGroup(of: (Int, WorktreeInfo).self) { group in
            for (index, worktree) in list.enumerated() {
                group.addTask {
                    let status = worktree.isBare || worktree.isPrunable ? nil : try? await Repository(path: worktree.path, gitPath: gitPath).status()
                    return (index, WorktreeInfo(worktree: worktree, status: status))
                }
            }
            var collected: [(Int, WorktreeInfo)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        worktrees = infos
        onMetadataChanged?()
    }

    /// The modification date of FETCH_HEAD is the time of the last fetch; git offers no command for it.
    private func loadLastFetch() async {
        guard let result = try? await repository.runner.run(["rev-parse", "--git-common-dir"]) else { return }
        var directory = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.hasPrefix("/") { directory = repository.path + "/" + directory }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory + "/FETCH_HEAD")
        lastFetch = attributes?[.modificationDate] as? Date
    }

    /// A stash commit keeps only its base parent in the graph: the index and untracked helper commits would otherwise appear as a merge with two invisible strands.
    private func layoutCommit(for commit: Commit) -> Commit {
        guard stashesByCommit[commit.id] != nil, commit.parents.count > 1 else { return commit }
        return Commit(id: commit.id, parents: [commit.parents[0]], authorName: commit.authorName, authorEmail: commit.authorEmail, authorDate: commit.authorDate, committerName: commit.committerName, committerEmail: commit.committerEmail, committerDate: commit.committerDate, subject: commit.subject, body: commit.body)
    }

    private func streamLog() async {
        let start = ContinuousClock.now
        var pending: [Commit] = []
        var pendingRows: [GraphRow] = []
        var pendingKinds: [RowKind] = []
        var lastFlush = ContinuousClock.now
        var flushedFirst = false
        let head = headSHA
        let hasChanges = !(status?.entries.isEmpty ?? true)
        var wipInserted = false

        func add(_ commit: Commit, kind: RowKind) {
            pendingRows.append(layout.append(layoutCommit(for: commit)))
            pending.append(commit)
            pendingKinds.append(kind)
        }
        func flush() {
            guard !pending.isEmpty else { return }
            let range = commits.count..<(commits.count + pending.count)
            for (offset, commit) in pending.enumerated() { rowIndexByID[commit.id] = range.lowerBound + offset }
            commits.append(contentsOf: pending)
            rows.append(contentsOf: pendingRows)
            kinds.append(contentsOf: pendingKinds)
            maxLaneCount = max(maxLaneCount, layout.maxLaneCount)
            pending.removeAll(keepingCapacity: true)
            pendingRows.removeAll(keepingCapacity: true)
            pendingKinds.removeAll(keepingCapacity: true)
            onRowsAppended?(range)
        }
        do {
            var options = LogOptions()
            options.extraArguments = Array(stashesByCommit.keys)
            for try await commit in repository.log(options) {
                if hiddenCommitIDs.contains(commit.id) { continue }
                if stashesByCommit[commit.id] != nil { hiddenCommitIDs.formUnion(commit.parents.dropFirst()) }
                // Uncommitted changes sit directly above HEAD as a synthetic child commit, so the layout gives them a lane of their own.
                if commit.id == head, hasChanges, !wipInserted {
                    wipInserted = true
                    let now = Date()
                    add(Commit(id: Self.wipID, parents: [commit.id], authorName: "", authorEmail: "", authorDate: now, committerName: "", committerEmail: "", committerDate: now, subject: "", body: ""), kind: .wip)
                }
                let kind: RowKind = stashesByCommit[commit.id] != nil ? .stash : commit.isMerge ? .merge : .commit
                add(commit, kind: kind)
                if !flushedFirst || pending.count >= 500 || lastFlush.duration(to: .now) > .milliseconds(100) {
                    flush()
                    flushedFirst = true
                    lastFlush = .now
                    setStatus("\(commits.count) Commits · \(elapsed(since: start))")
                }
            }
            flush()
            setStatus("\(commits.count) Commits · \(layout.maxLaneCount) Lanes · \(stashes.count) Stashes · geladen in \(elapsed(since: start))")
        } catch is CancellationError {
        } catch {
            flush()
            setStatus("git log fehlgeschlagen: \(error)")
        }
    }

    /// Walks parents from HEAD over the loaded commits. Linear in the history size.
    private func computeReachability() {
        guard let head = headSHA else { return }
        var parentsByID: [String: [String]] = [:]
        parentsByID.reserveCapacity(commits.count)
        for commit in commits { parentsByID[commit.id] = commit.parents }
        var seen: Set<String> = [head, Self.wipID]
        var stack = [head]
        while let id = stack.popLast() {
            for parent in parentsByID[id] ?? [] where seen.insert(parent).inserted { stack.append(parent) }
        }
        reachableFromHead = seen
    }

    private func setStatus(_ text: String) {
        statusText = text
        onStatusChanged?(text)
    }

    private func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return milliseconds < 1000 ? String(format: "%.0f ms", milliseconds) : String(format: "%.2f s", milliseconds / 1000)
    }
}
