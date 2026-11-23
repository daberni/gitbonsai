import Foundation
import GitEngine
import GraphLayout

/// Streams `git log` and lays every commit out as it arrives, handing the rows over in batches so the table inserts a few hundred at a time.
///
/// Reading and laying out run off the main actor; only the batches reach it. The first batch is handed over immediately, later ones after 500 commits or 100 ms.
struct LogLoader: Sendable {
    enum Outcome: Sendable {
        case finished
        case cancelled
        case failed(Error)

        var isFinished: Bool { if case .finished = self { true } else { false } }
    }

    struct Batch: Sendable {
        let commits: [Commit]
        let rows: [GraphRow]
        let kinds: [GraphViewModel.RowKind]
        let maxLaneCount: Int
    }

    private enum Event: Sendable {
        case batch(Batch, isProgress: Bool)
        case end(Outcome)
    }

    let repository: Repository
    let stashesByCommit: [String: Stash]
    /// The commit whose strand keeps the leftmost lane.
    let head: String?

    /// `onBatch` receives every batch; `onProgress` follows the batches handed over while the log is still streaming.
    @MainActor
    func stream(onBatch: (Batch) -> Void, onProgress: () -> Void) async -> Outcome {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let producer = Task.detached { [self] in
            continuation.yield(.end(await produce(into: continuation)))
            continuation.finish()
        }
        return await withTaskCancellationHandler {
            for await event in events {
                if Task.isCancelled { break }
                switch event {
                case .batch(let batch, let isProgress):
                    onBatch(batch)
                    if isProgress { onProgress() }
                case .end(let outcome):
                    return Task.isCancelled ? .cancelled : outcome
                }
            }
            return .cancelled
        } onCancel: {
            producer.cancel()
        }
    }

    private func produce(into continuation: AsyncStream<Event>.Continuation) async -> Outcome {
        var layout = GraphLayout(pinned: head)
        var hiddenCommitIDs: Set<String> = []
        var pending: [Commit] = []
        var pendingRows: [GraphRow] = []
        var pendingKinds: [GraphViewModel.RowKind] = []
        var lastFlush = ContinuousClock.now
        var flushedFirst = false
        func flush(isProgress: Bool) {
            guard !pending.isEmpty else { return }
            let batch = Batch(commits: pending, rows: pendingRows, kinds: pendingKinds, maxLaneCount: max(layout.maxLaneCount, 1))
            pending.removeAll(keepingCapacity: true)
            pendingRows.removeAll(keepingCapacity: true)
            pendingKinds.removeAll(keepingCapacity: true)
            continuation.yield(.batch(batch, isProgress: isProgress))
        }
        do {
            var options = LogOptions()
            options.extraArguments = stashesByCommit.keys.sorted()
            for try await commit in repository.log(options) {
                if Task.isCancelled { return .cancelled }
                // Index and untracked helper commits of stashes follow their stash in topological order and are skipped.
                if hiddenCommitIDs.contains(commit.id) { continue }
                let isStash = stashesByCommit[commit.id] != nil
                if isStash { hiddenCommitIDs.formUnion(commit.parents.dropFirst()) }
                pendingRows.append(layout.append(Self.layoutCommit(for: commit, stashesByCommit: stashesByCommit), isSideStrand: isStash))
                pending.append(commit)
                pendingKinds.append(isStash ? .stash : commit.isMerge ? .merge : .commit)
                if !flushedFirst || pending.count >= 500 || lastFlush.duration(to: .now) > .milliseconds(100) {
                    flush(isProgress: true)
                    flushedFirst = true
                    lastFlush = .now
                }
            }
            if Task.isCancelled { return .cancelled }
            flush(isProgress: false)
            return .finished
        } catch is CancellationError {
            return .cancelled
        } catch {
            flush(isProgress: false)
            return .failed(error)
        }
    }

    /// Lays loaded commits out again around a new HEAD, off the main thread. Nothing is read from git.
    static func relayout(_ commits: [Commit], head: String?, stashesByCommit: [String: Stash]) async -> (rows: [GraphRow], maxLaneCount: Int) {
        let input = commits.map { (commit: layoutCommit(for: $0, stashesByCommit: stashesByCommit), isStash: stashesByCommit[$0.id] != nil) }
        return await Task.detached {
            var layout = GraphLayout(pinned: head)
            let rows = input.map { layout.append($0.commit, isSideStrand: $0.isStash) }
            return (rows, max(layout.maxLaneCount, 1))
        }.value
    }

    /// A stash commit keeps only its base parent in the graph: the index and untracked helper commits would otherwise appear as a merge with two invisible strands.
    private static func layoutCommit(for commit: Commit, stashesByCommit: [String: Stash]) -> Commit {
        guard stashesByCommit[commit.id] != nil, commit.parents.count > 1 else { return commit }
        return Commit(id: commit.id, parents: [commit.parents[0]], authorName: commit.authorName, authorEmail: commit.authorEmail, authorDate: commit.authorDate, committerName: commit.committerName, committerEmail: commit.committerEmail, committerDate: commit.committerDate, subject: commit.subject, body: commit.body, trailers: commit.trailers)
    }
}
