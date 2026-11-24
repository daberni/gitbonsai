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

    private static let log = Logger(subsystem: "app.gitbonsai", category: "diff")

    /// Writes the phase to the unified log (subsystem `app.gitbonsai`, category `diff`), which stores it lazily, and to a harness run's output.
    @MainActor
    func record(_ phase: Phase) {
        switch phase {
        case .started: Self.log.debug("start \(line, privacy: .private)")
        case .cancelled: Self.log.debug("cancel \(line, privacy: .private)")
        case .finished(let result, let duration): Self.log.debug("finish \(line, privacy: .private): \(result, privacy: .public) in \(duration, privacy: .public)")
        case .failed(let message, let duration): Self.log.error("error \(line, privacy: .private): \(message, privacy: .private) after \(duration, privacy: .public)")
        }
        ScreenshotHarness.traceDiffLoad(self, phase)
    }
}
