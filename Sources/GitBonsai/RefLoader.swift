import Foundation
import GitEngine

/// Reads refs, stashes and the time of the last fetch, keyed the way the history looks them up.
enum RefLoader {
    static func refs(of repository: Repository) async throws -> (refs: [Ref], byCommit: [String: [Ref]]) {
        let loaded = try await repository.refs()
        var grouped: [String: [Ref]] = [:]
        for ref in loaded { grouped[ref.target, default: []].append(ref) }
        return (loaded, grouped)
    }

    static func stashes(of repository: Repository) async -> (stashes: [Stash], byCommit: [String: Stash])? {
        guard let loaded = try? await repository.stashes() else { return nil }
        return (loaded, Dictionary(loaded.map { ($0.commitID, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// The modification date of FETCH_HEAD is the time of the last fetch; git offers no command for it.
    /// Nil when the repository was never fetched; throws when git could not name the repository's directory.
    static func lastFetch(of repository: Repository) async throws -> Date? {
        let result = try await repository.runner.run(["rev-parse", "--git-common-dir"])
        var directory = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.hasPrefix("/") { directory = repository.path + "/" + directory }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory + "/FETCH_HEAD")
        return attributes?[.modificationDate] as? Date
    }
}
