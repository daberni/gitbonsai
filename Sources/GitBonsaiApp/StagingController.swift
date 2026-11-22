import AppKit
import GitEngine

/// Moves changes between working tree and index, discards unstaged changes after asking, shows git's message when that fails, and refreshes the tab afterwards.
@MainActor
final class StagingController {
    /// The index or the working tree changed; open diffs need to read them again.
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

    // MARK: Discarding

    /// Reverts one hunk of an unstaged file once the user confirmed it; the only hunk of an untracked file deletes the file.
    func discard(_ hunk: DiffHunk, of file: FileDiff, untracked: Bool) {
        if untracked {
            confirmDeletion(of: file.path) { [weak self] in
                self?.run(failure: Self.discardFailure) { try await $0.discard(hunk, of: file) }
            }
            return
        }
        // The changed lines, not the context around them: added lines by their new number, removed ones by their old.
        let changed = hunk.lines.compactMap { line -> Int? in
            switch line.kind {
            case .added: line.newNumber
            case .removed: line.oldNumber
            case .context: nil
            }
        }
        let first = changed.min() ?? hunk.newStart
        let last = changed.max() ?? first
        let range = first == last ? "Zeile \(first)" : "Zeilen \(first)–\(last)"
        confirm(title: "Hunk verwerfen?", text: "Die Änderungen in \(range) von „\(file.path)“ gehen verloren. Das lässt sich nicht rückgängig machen.") { [weak self] in
            self?.run(failure: Self.discardFailure) { try await $0.discard(hunk, of: file) }
        }
    }

    /// Reverts a tracked file to its staged content, or deletes an untracked file, once the user confirmed it. Staged changes stay.
    func discard(_ selection: FileSelection) {
        let path = selection.path
        switch selection.source {
        case .unstaged:
            confirm(title: "Änderungen an „\(selection.name)“ verwerfen?", text: "Alle nicht gestagten Änderungen an „\(path)“ gehen verloren. Gestagte Änderungen bleiben. Das lässt sich nicht rückgängig machen.") { [weak self] in
                self?.run(failure: Self.discardFailure) { try await $0.discardUnstagedChanges([path]) }
            }
        case .untracked:
            confirmDeletion(of: path) { [weak self] in
                self?.run(failure: Self.discardFailure) { try await $0.removeUntracked([path]) }
            }
        case .staged, .commit:
            break
        }
    }

    private static let discardFailure = "Änderungen nicht verworfen"

    /// Git has never seen an untracked file, so the sheet says plainly that it is gone for good.
    private func confirmDeletion(of path: String, then perform: @escaping () -> Void) {
        let name = (path as NSString).lastPathComponent
        confirm(title: "„\(name)“ löschen?", text: "Die ungetrackte Datei „\(path)“ wird gelöscht. Git kennt sie nicht, sie lässt sich nicht wiederherstellen.", then: perform)
    }

    /// The question comes as a sheet on the window; the destructive button is never the default, so Return does not discard, and Esc cancels too.
    private func confirm(title: String, text: String, then perform: @escaping () -> Void) {
        guard let window = window?() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        let discard = alert.addButton(withTitle: "Verwerfen")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Abbrechen")
        cancel.keyEquivalent = "\r"
        if ScreenshotHarness.keysSheets { ScreenshotHarness.pressKey(on: alert) } else { ScreenshotHarness.answerDiscardSheet(alert) }
        Task {
            if await alert.beginSheet(on: window) == .alertFirstButtonReturn { perform() }
        }
    }

    // MARK: Running

    private func run(failure: String = "Index nicht geändert", _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        Task { [weak self] in
            do {
                try await operation(repository)
            } catch {
                self?.report(error, title: failure)
            }
            await self?.viewModel.refresh(note: nil)
            self?.onChange?()
        }
    }

    private func report(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(error)"
        guard ScreenshotHarness.outputPath == nil, let window = window?() else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.beginSheetModal(for: window)
    }
}
