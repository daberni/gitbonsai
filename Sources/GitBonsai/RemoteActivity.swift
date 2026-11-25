import Foundation

/// The fetch, pull or push running in a tab, whichever part of the app started it, so the toolbar can show it and cancel it.
@MainActor
final class RemoteActivity {
    enum Kind: Sendable, Equatable {
        case fetch, pull, push
    }

    /// What the toolbar shows: the operation and whether it runs in the background, as the automatic fetch does.
    struct Running: Equatable {
        let kind: Kind
        let isBackground: Bool
    }

    private struct Entry {
        let id: Int
        let running: Running
        let cancel: () -> Void
    }

    /// Operations can overlap, such as a push started during an automatic fetch or the fetch after a rejected force push; the latest one started by the user is shown.
    private var entries: [Entry] = []
    private var nextID = 0
    var onChange: (() -> Void)?

    var running: Running? { (entries.last { !$0.running.isBackground } ?? entries.first)?.running }

    /// Runs `body` as the tab's remote operation. It runs in a task of its own so that `cancel` stops it, and with it git, whoever awaits the result.
    func run<T: Sendable>(_ kind: Kind, background: Bool = false, _ body: @escaping @MainActor () async -> T) async -> T {
        let task = Task { @MainActor in await body() }
        nextID += 1
        let id = nextID
        let before = running
        entries.append(Entry(id: id, running: Running(kind: kind, isBackground: background), cancel: { task.cancel() }))
        if running != before { onChange?() }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        let shown = running
        entries.removeAll { $0.id == id }
        if running != shown { onChange?() }
        return result
    }

    /// Cancels the operation the toolbar shows.
    func cancel() {
        (entries.last { !$0.running.isBackground } ?? entries.first)?.cancel()
    }
}
