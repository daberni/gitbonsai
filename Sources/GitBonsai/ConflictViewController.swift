import AppKit
import GitEngine

/// The conflict view of one unmerged file, shown in the history pane in place of the graph like a diff.
/// A text conflict shows the file unified: changes of one side are in it already, each open conflict shows ours above theirs with links to take ours, theirs, both or the word merge.
/// "Resolve…" opens the three columns in their own window, on the same decisions, or the merge tool chosen in the settings; "Mark resolved" in the pane or the window writes the result and stages it.
/// Other conflicts offer whole sides or deleting the file, which act at once. Decisions not yet marked resolved survive closing the view while the file's stages stay the same.
@MainActor
final class ConflictViewController: NSObject {
    let view = NSView()
    let header = ConflictHeaderView(mode: .pane)
    var onClose: (() -> Void)?
    /// The path no longer has a conflict, resolved here, in a merge window or in the merge tool; the status is read again already.
    var onResolved: ((String) -> Void)?

    private let repository: () -> Repository
    private let sides: () -> ConflictSides
    private let refresh: () async -> Void
    let prompter: any Prompting
    private let settings: AppSettings
    private let scroll = NSScrollView()
    private let content = FlippedStack()
    let unified = UnifiedConflictView()
    private(set) var conflict: Conflict?
    private(set) var session: ConflictSession?
    private(set) var choiceView: ConflictChoiceView?
    private var observation: UUID?
    /// The tool `git mergetool --gui` opens in this repository; nil when git names none.
    private(set) var mergeTool: String?
    private let observers = NotificationObservers()
    private var loadTask: Task<Void, Never>?
    private var isWriting = false
    /// Sessions with decisions not yet marked resolved, per path and stages; a merge window shares the one of its file.
    private var sessions: [String: ConflictSession] = [:]
    private(set) var windows: [String: MergeWindowController] = [:]

    var path: String? { conflict?.path }

    init(context: RepositoryContext, sides: @escaping () -> ConflictSides) {
        let viewModel = context.model
        repository = { viewModel.repository }
        self.sides = sides
        refresh = { await viewModel.refresh(note: nil) }
        prompter = context.prompter
        settings = context.settings
        super.init()
        header.onBack = { [weak self] in self?.close(); self?.onClose?() }
        header.onPrevious = { [weak self] in self?.go(by: -1) }
        header.onNext = { [weak self] in self?.go(by: 1) }
        header.onResolve = { [weak self] in self?.resolve() }
        header.onMarkResolved = { [weak self] in
            guard let self, let session else { return }
            markResolved(session)
        }
        unified.onLink = { [weak self] link in self?.follow(link) }
        layout()
        observers.observe(AppSettings.didChange) { [weak self] in self?.header.showResolveTool(self?.resolvingTool) }
    }

    /// The merge tool "Resolve…" opens: only when the settings choose one over the merge window and git names one here.
    var resolvingTool: String? {
        settings.conflictResolver == .mergeTool ? mergeTool : nil
    }

    private func layout() {
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface0
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Theme.Conflict.cardGap
        content.edgeInsets = NSEdgeInsets(top: Theme.Conflict.padding, left: Theme.Conflict.padding, bottom: Theme.Conflict.padding, right: Theme.Conflict.padding)
        content.translatesAutoresizingMaskIntoConstraints = false
        for subview in [header, scroll, unified] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Conflict.headerHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            unified.topAnchor.constraint(equalTo: header.bottomAnchor),
            unified.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            unified.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            unified.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    // MARK: Loading

    /// Reads the conflict and only then replaces what is shown; `ready` runs once it is in place. A path that is no longer unmerged counts as resolved; any other failure is reported with Retry and keeps what is shown.
    func show(path: String, ready: (() -> Void)? = nil) {
        loadTask?.cancel()
        let repository = self.repository()
        loadTask = Task { [weak self] in
            let loaded: Result<Conflict, Error>
            do { loaded = .success(try await repository.conflict(at: path)) } catch { loaded = .failure(error) }
            let mergeTool = await repository.mergeToolName()
            guard let self, !Task.isCancelled else { return }
            switch loaded {
            case .success(let conflict):
                self.mergeTool = mergeTool
                build(conflict)
                ready?()
            case .failure(let error as NoConflict):
                onResolved?(error.path)
            case .failure(let error):
                let retry = FailureAction(title: LocalizedStringResource("failure.action.retry", defaultValue: "Retry", bundle: .module)) { [weak self] in self?.show(path: path, ready: ready) }
                prompter.report(error, title: LocalizedStringResource("failure.conflict.notRead", defaultValue: "Conflict could not be read", bundle: .module), actions: [retry])
            }
        }
    }

    /// The history moved on or the view closed: a conflict still loading must not appear. Decisions stay with their session; a merge window stays open.
    func close() {
        loadTask?.cancel()
        detach()
        conflict = nil
    }

    /// After the working tree or index changed elsewhere: once the path has no conflict left, the view gives way; otherwise it stays as it is, decisions included.
    func reload() {
        guard let path, !isWriting else { return }
        let repository = self.repository()
        Task { [weak self] in
            let stages = try? await repository.conflictStages()
            guard let self, self.path == path, let stages else { return }
            if stages[path] == nil { resolved(path) }
        }
    }

    private func build(_ conflict: Conflict) {
        detach()
        self.conflict = conflict
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        choiceView = nil
        switch conflict.content {
        case .text(let document):
            let key = Self.key(for: conflict)
            let session = sessions[key] ?? ConflictSession(conflict: conflict, document: document, sides: sides(), states: [])
            if sessions[key] == nil {
                sessions[key] = session
                let repository = self.repository()
                Task { await session.findWordMerges(in: repository) }
            }
            self.session = session
            observation = session.observe { [weak self] in self?.showSession() }
            scroll.isHidden = true
            unified.isHidden = false
            header.show(path: conflict.path, kind: conflict.kind, changes: session.resolution.changes.count, mergeTool: resolvingTool)
            showSession()
        case .binary, .oneSided, .none:
            let card = ConflictChoiceView(conflict: conflict, sides: sides())
            card.onAction = { [weak self] action in self?.perform(action) }
            choiceView = card
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * Theme.Conflict.padding).isActive = true
            scroll.isHidden = false
            unified.isHidden = true
            header.show(path: conflict.path, kind: conflict.kind, changes: nil, mergeTool: resolvingTool)
        }
        scrollToTop()
    }

    private func detach() {
        if let observation { session?.stopObserving(observation) }
        observation = nil
        session = nil
    }

    private func showSession() {
        guard let session else { return }
        unified.show(session)
        header.showProgress(open: session.resolution.openConflicts)
    }

    private static func key(for conflict: Conflict) -> String {
        [conflict.path, conflict.stages.ours?.oid, conflict.stages.theirs?.oid].map { $0 ?? "-" }.joined(separator: "\0")
    }

    /// A file opens at its top left, whatever the previous one was scrolled to.
    func scrollToTop() {
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        unified.scrollToTop()
    }

    // MARK: Navigation and links

    private func go(by step: Int) {
        guard let session else { return }
        let target = session.current + step
        guard session.resolution.changes.indices.contains(target) else { NSSound.beep(); return }
        session.current = target
        unified.reveal(target)
    }

    /// `take/<change>/ours|theirs|both`, `merge/<change>` or `reopen/<change>` from an action row.
    func follow(_ link: String) {
        guard let session else { return }
        let parts = link.split(separator: "/").map(String.init)
        guard parts.count >= 2, let change = Int(parts[1]) else { return }
        session.current = change
        switch (parts[0], parts.count > 2 ? parts[2] : "") {
        case ("take", "ours"): session.take(.ours, at: change)
        case ("take", "theirs"): session.take(.theirs, at: change)
        case ("take", "both"): session.update { $0.take(.ours, at: change); $0.take(.theirs, at: change) }
        case ("merge", _): if !session.mergeWords(at: change) { NSSound.beep() }
        case ("reopen", _): session.reopen(change)
        default: break
        }
    }

    // MARK: Merge window and merge tool

    /// "Resolve…": the merge tool when the settings choose one, otherwise the merge window.
    func resolve() {
        if resolvingTool != nil { openMergeTool() } else { openWindow() }
    }

    func openWindow() {
        guard let session else { return }
        if let existing = windows[session.path] {
            existing.showWindow(nil)
            return
        }
        let controller = MergeWindowController(session: session, parent: view.window)
        controller.onMarkResolved = { [weak self, weak session] in
            guard let self, let session else { return }
            markResolved(session)
        }
        let path = session.path
        controller.onClosed = { [weak self] in self?.windows[path] = nil }
        windows[path] = controller
        controller.showWindow(nil)
    }

    // MARK: Resolving

    /// Writes the result and stages it.
    func markResolved(_ session: ConflictSession) {
        guard let result = session.resolution.text else { return }
        let encoding = session.resolution.document.encoding
        let path = session.path
        run(path) { try await $0.resolveConflict(path, with: result, encoding: encoding) }
    }

    func perform(_ action: ConflictFileAction) {
        guard let path else { return }
        switch action {
        case .take(let side): run(path) { try await $0.resolveConflicts([path], taking: side) }
        case .delete: run(path) { try await $0.resolveConflictsByDeleting([path]) }
        }
    }

    private func run(_ path: String, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        guard !isWriting else { return }
        isWriting = true
        let repository = self.repository()
        Task { [weak self] in
            do {
                try await operation(repository)
            } catch {
                self?.prompter.report(error, title: LocalizedStringResource("failure.conflict.notResolved", defaultValue: "Conflict not resolved", bundle: .module))
            }
            await self?.refresh()
            self?.isWriting = false
            // Stages that could not be read say nothing about the file; its session and the decisions in it stay.
            guard let stages = try? await repository.conflictStages() else { return }
            if stages[path] == nil { self?.resolved(path) }
        }
    }

    /// The file has no conflict any more: its session ends, its merge window closes, and the tab moves on if the pane shows it.
    private func resolved(_ path: String) {
        sessions = sessions.filter { $0.value.path != path }
        windows[path]?.close()
        windows[path] = nil
        if self.path == path || conflict == nil { onResolved?(path) }
    }

    /// Waits for the merge tool. Resolved there, the view gives way; otherwise the conflict is read again, as the tool may have changed the file.
    func openMergeTool() {
        guard let path else { return }
        let repository = self.repository()
        header.resolve.isEnabled = false
        Task { [weak self] in
            do {
                _ = try await repository.openMergeTool(for: path)
            } catch {
                self?.prompter.report(error, title: LocalizedStringResource("failure.conflict.mergeToolFailed", defaultValue: "Merge tool failed", bundle: .module))
            }
            self?.header.resolve.isEnabled = true
            await self?.refresh()
            // The user may have moved on to another file while the tool was open.
            guard self?.path == path else { return }
            self?.show(path: path)
        }
    }
}

/// A vertical stack whose origin is at the top, so it grows downwards inside a scroll view.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}
