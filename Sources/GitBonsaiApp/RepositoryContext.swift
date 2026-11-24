import AppKit
import GitEngine

/// What exists once per open repository tab and its controllers share, created once per tab and passed to each of them: the tab's state and repository, the one way to ask and tell the user, the one runner of git writes, and the tab's lifecycle.
@MainActor
final class RepositoryContext {
    let app: AppContext
    /// The tab's state: history, refs, status, worktrees, stashes. Its controllers read it here; it is also what each action runs in, the `ActionContext` of `runner`.
    let model: GraphViewModel
    let lifecycle: TabLifecycle
    let toast: Toast
    let prompter: any Prompting
    private let actionPrompter: ActionPrompter
    let runner: ActionRunner
    /// The window's command bar, for commands of the tab that continue in a second list.
    let commandBar: CommandBarController

    /// The worktree the tab shows now; it changes when the tab moves to another worktree.
    var repository: Repository { model.repository }

    /// Shows the working directory with its conflicts, where a toast about conflicts leads; the tab sets it once its parts exist.
    var onShowConflicts: (() -> Void)? {
        get { actionPrompter.onShowConflicts }
        set { actionPrompter.onShowConflicts = newValue }
    }
    var settings: AppSettings { app.settings }

    init(app: AppContext, model: GraphViewModel, commandBar: CommandBarController) {
        self.app = app
        self.commandBar = commandBar
        self.model = model
        let viewModel = model
        let lifecycle = TabLifecycle(viewModel: viewModel)
        self.lifecycle = lifecycle
        let toast = Toast()
        self.toast = toast
        let prompter = ActionPrompter(lifecycle: lifecycle, toast: toast, pasteboard: app.pasteboard)
        self.prompter = prompter
        actionPrompter = prompter
        runner = ActionRunner(context: model, prompter: prompter)
    }
}

/// Owns whether a repository tab is shown, what keeps it current while it is, and its end: the window it is shown in, questions waiting for it to be shown, file watching and automatic fetches.
/// Once closed, nothing of it runs any more and everything waiting for it is answered with nil.
@MainActor
final class TabLifecycle {
    /// The tab's content; its window is the tab's while the tab is the one its window shows.
    weak var view: NSView?
    private(set) var isClosed = false
    private let viewModel: GraphViewModel
    private var autoFetch: AutoFetchScheduler?
    private var reconciler: TabReconciler?
    /// Questions and reports that arrived while the tab was in the background, waiting for it to be shown.
    private var shownWaiters: [CheckedContinuation<NSWindow?, Never>] = []

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    var window: NSWindow? { view?.window }
    var isVisible: Bool { window != nil }

    /// Starts keeping the tab current; called once the tab's parts exist.
    func start(autoFetch: AutoFetchScheduler, reconciler: TabReconciler) {
        guard !isClosed else { return }
        self.autoFetch = autoFetch
        self.reconciler = reconciler
    }

    /// Watches the working tree at `root`, replacing the watcher of the worktree shown before.
    func watch(root: String) {
        guard !isClosed else { return }
        reconciler?.watch(root: root, commonDirectory: viewModel.commonDirectory, gitPath: viewModel.repository.runner.gitPath)
    }

    /// The first full load finished; reconciling and fetching may start.
    func loaded() {
        autoFetch?.loaded()
        reconciler?.loaded()
    }

    /// The tab became the one its window shows.
    func becameVisible() {
        guard !isClosed else { return }
        reconciler?.request(.visible)
        autoFetch?.becameVisible()
        resumeShownWaiters(with: window)
    }

    /// The tab's window, at once while it is shown, otherwise once the tab is shown again; nil when the tab is or gets closed first.
    func windowWhenShown() async -> NSWindow? {
        if let window { return window }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { shownWaiters.append($0) }
    }

    /// The tab or its window closed: watching, reconciling, fetching and loading stop, and waiting questions get no window.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        resumeShownWaiters(with: nil)
        reconciler?.stop()
        reconciler = nil
        autoFetch?.stop()
        autoFetch = nil
        viewModel.close()
    }

    private func resumeShownWaiters(with window: NSWindow?) {
        let waiters = shownWaiters
        shownWaiters = []
        for waiter in waiters { waiter.resume(returning: window) }
    }
}
