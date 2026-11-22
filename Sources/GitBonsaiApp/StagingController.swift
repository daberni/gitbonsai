import AppKit
import GitEngine

/// Moves changes between working tree and index, shows git's message when that fails, and refreshes the tab afterwards.
@MainActor
final class StagingController {
    /// The index changed; open diffs need to read it again.
    var onChange: (() -> Void)?
    var window: (() -> NSWindow?)?
    private let viewModel: GraphViewModel

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    func stage(_ paths: [String]) {
        run { try await $0.stage(paths) }
    }

    func unstage(_ paths: [String]) {
        run { try await $0.unstage(paths) }
    }

    func stage(_ hunk: DiffHunk, of file: FileDiff) {
        run { try await $0.stage(hunk, of: file) }
    }

    func unstage(_ hunk: DiffHunk, of file: FileDiff) {
        run { try await $0.unstage(hunk, of: file) }
    }

    private func run(_ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        Task { [weak self] in
            do {
                try await operation(repository)
            } catch {
                self?.report(error)
            }
            await self?.viewModel.refresh(note: nil)
            self?.onChange?()
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Index nicht geändert"
        alert.informativeText = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(error)"
        guard ScreenshotHarness.outputPath == nil, let window = window?() else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.beginSheetModal(for: window)
    }
}
