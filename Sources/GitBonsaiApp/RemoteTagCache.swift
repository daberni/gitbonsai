import Foundation
import GitEngine

/// The tags each remote has, asked once with `git ls-remote --tags` and kept until something may have changed them: a fetch, pull or push through this repository
/// (whatever started it, an automatic fetch or a tag action included), another worktree, or other remotes.
@MainActor
final class RemoteTagCache {
    enum Lookup {
        case loading
        case loaded([String: TagTarget])
        case failed(GitError?)
    }

    /// Called when a lookup finished.
    var onChange: (() -> Void)?
    private(set) var lookups: [String: Lookup] = [:]
    private var repository: Repository?
    private var startedAt: Date?
    /// Answers of lookups started before the last reset are dropped.
    private var generation = 0

    /// Forgets stale answers and asks every remote that has none. Returns at once; answers arrive through `onChange`.
    func refresh(repository: Repository, remotes: [String]) async {
        if await isStale(repository: repository, remotes: remotes) { reset() }
        self.repository = repository
        let missing = remotes.filter { lookups[$0] == nil }
        guard !missing.isEmpty else { return }
        if startedAt == nil { startedAt = Date() }
        let round = generation
        for remote in missing {
            lookups[remote] = .loading
            Task {
                let lookup: Lookup
                do {
                    lookup = .loaded(try await repository.remoteTags(on: remote))
                } catch {
                    lookup = .failed(error as? GitError)
                }
                guard round == generation else { return }
                lookups[remote] = lookup
                onChange?()
            }
        }
    }

    func reset() {
        generation += 1
        lookups = [:]
        startedAt = nil
    }

    /// How each answered remote compares with `local`, in the order of `remotes`.
    func states(for remotes: [String], local: [String: TagTarget]) -> [(remote: String, states: [String: TagSyncState])] {
        remotes.compactMap { remote in
            guard case .loaded(let tags)? = lookups[remote] else { return nil }
            return (remote, Repository.compareTags(local: local, remote: tags))
        }
    }

    /// A quiet line for the list: still asking, or which remotes did not answer. Nil when every remote answered.
    func note(for remotes: [String]) -> String? {
        if remotes.isEmpty { return "Kein Remote, kein Abgleich" }
        if remotes.contains(where: { if case .loading? = lookups[$0] { true } else { false } }) { return "Abgleich mit Remote …" }
        let failed = remotes.compactMap { remote -> (String, GitError?)? in
            guard case .failed(let error)? = lookups[remote] else { return nil }
            return (remote, error)
        }
        guard let (remote, error) = failed.first else { return nil }
        let reason = error?.isTimeout == true ? "antwortet nicht" : "nicht erreichbar"
        return failed.count == 1 ? "„\(remote)“ \(reason)" : "\(failed.count) Remotes nicht erreichbar"
    }

    private func isStale(repository: Repository, remotes: [String]) async -> Bool {
        guard let cached = self.repository, cached === repository else { return true }
        guard Set(lookups.keys).isSubset(of: remotes) else { return true }
        guard let startedAt else { return false }
        let log = await repository.runner.commandLog
        return log.contains { entry in
            entry.startedAt.addingTimeInterval(entry.result.duration) >= startedAt && Self.mayChangeRemoteTags(entry.result.arguments)
        }
    }

    /// `git fetch`, `pull` and `push` in any form, behind leading `-c` options; `git stash push` is not one of them.
    nonisolated static func mayChangeRemoteTags(_ arguments: [String]) -> Bool {
        var rest = arguments[...]
        while rest.first == "-c" { rest = rest.dropFirst(2) }
        return ["fetch", "pull", "push"].contains(rest.first ?? "")
    }
}
