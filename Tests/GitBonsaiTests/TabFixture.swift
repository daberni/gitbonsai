import AppKit
import Avatars
import GitEngine
import XCTest
@testable import GitBonsai

/// Answers a tab's questions in code and records what was asked.
@MainActor
final class FakePrompter: Prompting {
    /// The message of every confirmation, choice and form, in order.
    private(set) var asked: [String] = []
    private(set) var reports: [String] = []
    /// The last form and alert asked, for snapshots of the real sheets.
    private(set) var lastForm: ActionForm?
    private(set) var lastAlert: NSAlert?
    /// Answers for `confirm`, taken in order; a missing answer is no.
    var confirmations: [Bool] = []

    var window: NSWindow? { nil }
    var showConflictsAction: ToastAction { ToastAction(title: LocalizedStringResource("common.cancel", defaultValue: "Cancel"), run: {}) }

    func ask(_ form: ActionForm) async -> ActionForm.Values? {
        lastForm = form
        asked.append(form.alert.messageText)
        return nil
    }

    func confirm(_ alert: NSAlert) async -> Bool {
        lastAlert = alert
        asked.append(alert.messageText)
        return confirmations.isEmpty ? false : confirmations.removeFirst()
    }

    func confirmDiscard(_ alert: NSAlert, then perform: @escaping () -> Void) {
        asked.append(alert.messageText)
        if !confirmations.isEmpty, confirmations.removeFirst() { perform() }
    }

    func choose(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        asked.append(alert.messageText)
        return .cancel
    }

    func saveLocation(title: LocalizedStringResource, suggestedName: String) async -> URL? { nil }
    func reportFailure(_ error: Error, title: LocalizedStringResource, summary: LocalizedStringResource?, actions: [FailureAction]) { reports.append("\(title.text): \(error)") }
    func reportUnlessStopped(_ error: Error, title: LocalizedStringResource, actions: [FailureAction], in repository: Repository) async { reports.append("\(title.text): \(error)") }
    func reportConflictingReturn(of stash: String) { reports.append("conflicting return of \(stash)") }
    func showSheet(title: LocalizedStringResource, summary: LocalizedStringResource, details: String?, actions: [FailureAction]) { reports.append(title.text) }
    func toast(_ text: RefString, action: ToastAction?) {}
}

/// One repository tab without a window: the view model loaded from a fixture repository and the actions and menu builder the tab assembles.
@MainActor
final class TabFixture {
    let repo: FixtureRepo
    let prompter = FakePrompter()
    let context: RepositoryContext
    let checkout: CheckoutUseCase
    let commitActions: CommitActions
    let branches: BranchActions
    let tags: TagActions
    let stashes: StashActions
    let worktrees: WorktreeActions
    let menus: MenuBuilder
    let upstream: UpstreamStatus
    let fetch: FetchUseCase
    let pull: PullUseCase
    let push: PushUseCase
    let files: FileActions
    let conflicts: ConflictActions

    var model: GraphViewModel { context.model }

    init(_ repo: FixtureRepo) {
        self.repo = repo
        let suite = "app.gitbonsai.tests.\(UUID().uuidString)"
        let persistence = Persistence(defaults: UserDefaults(suiteName: suite)!)
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(persistence: persistence)
        let app = AppContext(persistence: persistence, settings: settings, pasteboard: Pasteboard(pasteboard: NSPasteboard(name: NSPasteboard.Name(suite))), avatarCacheDirectory: repo.url.appendingPathComponent(".avatars"), avatarTransport: NoAvatars(), trace: TraceSink(subsystem: "app.gitbonsai.tests"))
        let model = GraphViewModel(location: RepositoryLocation(root: repo.path, commonDirectory: repo.url.appendingPathComponent(".git").path), settings: settings)
        context = RepositoryContext(app: app, model: model, commandBar: CommandBarController(persistence: persistence), prompter: prompter)
        checkout = CheckoutUseCase(context: context)
        commitActions = CommitActions(context: context)
        upstream = UpstreamStatus(model: model)
        pull = PullUseCase(context: context, status: upstream)
        push = PushUseCase(context: context, status: upstream, pull: pull)
        fetch = FetchUseCase(context: context)
        let staging = StagingUseCase(context: context)
        conflicts = ConflictActions(context: context)
        files = FileActions(context: context, staging: staging, conflicts: conflicts)
        let fastForward = FastForwardUseCase(context: context)
        let checkout = checkout
        let pull = pull
        let push = push
        branches = BranchActions(context: context, pull: pull, push: push, fastForward: fastForward) { target, path in checkout.perform(target, worktreePath: path) }
        tags = TagActions(context: context)
        stashes = StashActions(context: context)
        worktrees = WorktreeActions(context: context)
        menus = MenuBuilder(context: context, checkout: checkout, commitActions: commitActions, branches: branches, tags: tags, fastForward: fastForward, stashes: stashes, worktrees: worktrees, remotes: RemoteActions(context: context), fetch: fetch, pull: pull, push: push, files: files, staging: staging)
    }

    /// Loads the tab, the upstream state the branch menus read and the tags with their remotes, as the tab does once it shows.
    func load() async throws {
        model.load()
        try await waitUntil { !self.model.isLoading }
        await upstream.refresh().value
        await tags.reload()
        let remotes = try repo.git("remote").split(separator: "\n").map(String.init)
        fetch.refreshRemotes()
        try await waitUntil { self.fetch.remotes == remotes }
    }

    func row(of sha: String) throws -> Int {
        try XCTUnwrap(model.rowIndex(of: sha), "no row for \(sha)")
    }

    func ref(_ name: String) throws -> Ref {
        try XCTUnwrap(model.refs.first { $0.name == name }, "no ref \(name)")
    }
}

/// Polls `condition` on the main actor until it holds; actions start their git work in tasks of their own.
@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw XCTSkip("condition not reached in time") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Menus as their readers see them: titles per group, a submenu in brackets, a disabled entry with its reason.
extension Array where Element == [MenuEntry] {
    @MainActor var outline: [[String]] {
        filter { !$0.isEmpty }.map { group in group.map(\.outline) }
    }

    @MainActor func entry(_ title: String) -> MenuEntry? {
        for entry in joined() {
            if entry.plainTitle == title { return entry }
            if let found = entry.submenu?.entry(title) { return found }
        }
        return nil
    }
}

extension MenuEntry {
    @MainActor var outline: String {
        if let submenu { return "\(plainTitle) [\(submenu.outline.map { $0.joined(separator: ", ") }.joined(separator: " | "))]" }
        if let disabledReason { return "\(plainTitle) (\(disabledReason))" }
        return plainTitle
    }

    @MainActor func run() {
        guard case .action(let action) = content else { return XCTFail("\(plainTitle) runs nothing") }
        action()
    }
}

/// Avatars are never fetched in these tests.
private struct NoAvatars: AvatarFetching {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
