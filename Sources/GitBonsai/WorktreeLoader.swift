import Foundation
import GitEngine

struct WorktreeInfo: Sendable, Hashable, Identifiable {
    var id: String { worktree.path }
    let worktree: Worktree
    /// Nil when the worktree folder is missing or its status could not be read.
    let status: RepositoryStatus?
}

/// Reads the repository's worktrees and, separately, their working directory statuses.
enum WorktreeLoader {
    /// The list alone is cheap. Counters that are already known are kept until the fresh ones arrive.
    static func list(of repository: Repository, keeping known: [WorktreeInfo]) async -> [WorktreeInfo]? {
        guard let list = try? await repository.worktrees() else { return nil }
        let knownStatuses = Dictionary(known.map { ($0.worktree.path, $0.status) }, uniquingKeysWith: { first, _ in first })
        return list.map { WorktreeInfo(worktree: $0, status: knownStatuses[$0.path] ?? nil) }
    }

    /// Reads every worktree's status in parallel, in the order of `worktrees`.
    static func statuses(of worktrees: [Worktree], gitPath: String) async -> [WorktreeInfo] {
        await withTaskGroup(of: (Int, WorktreeInfo).self) { group in
            for (index, worktree) in worktrees.enumerated() {
                group.addTask {
                    let status = worktree.isBare || worktree.isPrunable ? nil : try? await Repository(path: worktree.path, gitPath: gitPath).status()
                    return (index, WorktreeInfo(worktree: worktree, status: status))
                }
            }
            var collected: [(Int, WorktreeInfo)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
