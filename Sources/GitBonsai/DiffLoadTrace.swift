import Foundation
import GitEngine
import os

/// Which file of which comparison a diff load reads, and in which folder git runs for it.
struct DiffLoadTrace {
    enum Phase {
        case started, cancelled
        /// What git reported: no changes, or how many hunks.
        case finished(String, Duration)
        case failed(String, Duration)
    }

    let path: String
    let source: String
    let repository: String
    /// Begins when the trace records `.started` and ends with the outcome.
    private let interval = Signposts.begin("diff.load")

    init(selection: FileSelection, repository: String) {
        path = selection.path
        self.repository = repository
        switch selection.source {
        case .commit(let commit): source = "\(commit.parents.first.map { String($0.prefix(7)) } ?? "root")..\(commit.id.prefix(7))"
        case .revisions(let base, let target): source = "\(base.prefix(7))..\(target.prefix(7))"
        case .unstaged: source = "unstaged"
        case .staged: source = "staged"
        case .untracked: source = "untracked"
        }
    }

    var line: String { "\(source) \(path) in \(repository)" }

    /// Writes the phase to the unified log, which stores it lazily.
    @MainActor
    func record(_ phase: Phase, to trace: TraceSink) {
        let log = trace.logger("diff")
        switch phase {
        case .started: log.debug("start \(line, privacy: .private)")
        case .cancelled:
            log.debug("cancel \(line, privacy: .private)")
            interval.end("cancelled")
        case .finished(let result, let duration):
            log.debug("finish \(line, privacy: .private): \(result, privacy: .public) in \(duration, privacy: .public)")
            interval.end(result)
        case .failed(let message, let duration):
            log.error("error \(line, privacy: .private): \(message, privacy: .private) after \(duration, privacy: .public)")
            interval.end("failed")
        }
    }
}
