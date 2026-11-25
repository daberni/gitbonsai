import AppKit
import GitEngine

/// Several selected files in the history pane: their diffs one below the other in one scroll view, or for too many files only their count.
/// A bar on top names the count and offers what fits every file: stage, unstage or discard them all, and close (also Esc), which brings the graph back.
/// Each file is an embedded `DiffViewController`, so whatever a single diff can show, a stacked one shows too.
@MainActor
final class StackedDiffController {
    let view = NSView()
    var onClose: (() -> Void)?
    /// Files left the stack because a reload found no changes on their side any more.
    var onFilesGone: (([FileSelection]) -> Void)?
    private(set) var files: [FileSelection] = []
    private(set) var parts: [DiffViewController] = []

    private let staging: StagingUseCase
    private let repository: () -> Repository
    let bar = StackedDiffBar()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let countState = EmptyStateView()

    private let preferences: DiffPreferences
    private let trace: TraceSink

    init(staging: StagingUseCase, repository: @escaping () -> Repository, preferences: DiffPreferences, trace: TraceSink) {
        self.staging = staging
        self.repository = repository
        self.preferences = preferences
        self.trace = trace
        bar.onClose = { [weak self] in self?.onClose?() }
        bar.onAction = { [weak self] action in self?.run(action) }
        layout()
    }

    private func layout() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Diff.stackedGap
        let document = StackDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface1
        for subview in [bar, scroll, countState] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Theme.Diff.headerHeight),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            countState.topAnchor.constraint(equalTo: bar.bottomAnchor),
            countState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            countState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            countState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    // MARK: Showing

    /// Each file reads its own diff; the stack is in place once all of them are in, so it never shows half filled.
    func show(_ selections: [FileSelection], ready: (() -> Void)? = nil) {
        let isSame = selections == files
        files = selections
        bar.show(count: selections.count, actions: Self.sharedActions(of: selections))
        if isSame { return reload() }
        clearParts()
        let stacks = selections.count <= Theme.Diff.maximumStacked
        scroll.isHidden = !stacks
        countState.isHidden = stacks
        guard stacks else {
            countState.show(EmptyStateView.Content(title: String(localized: "diff.stack.count", defaultValue: "\(selections.count) files selected", bundle: .module), detail: [String(localized: "diff.stack.tooMany", defaultValue: "Too many to show their diffs one below the other", bundle: .module)]))
            ready?()
            return
        }
        var waiting = selections.count
        for file in selections {
            let part = DiffViewController(staging: staging, repository: repository, preferences: preferences, trace: trace, embedded: true)
            part.onClose = { [weak self, weak part] in
                guard let self, let part else { return }
                remove(part)
            }
            parts.append(part)
            stack.addArrangedSubview(part.view)
            part.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            part.show(file) {
                waiting -= 1
                if waiting == 0 { ready?() }
            }
        }
        scroll.contentView.scroll(to: .zero)
    }

    /// After the index or the working tree changed: every file is read again, and files without changes left drop out.
    func reload() {
        parts.forEach { $0.reload() }
    }

    func close() {
        parts.forEach { $0.close() }
        clearParts()
        files = []
    }

    private func clearParts() {
        parts.forEach { $0.close(); $0.view.removeFromSuperview() }
        parts = []
    }

    private func remove(_ part: DiffViewController) {
        guard let index = parts.firstIndex(where: { $0 === part }) else { return }
        part.view.removeFromSuperview()
        parts.remove(at: index)
        let gone = files.filter { file in !parts.contains { $0.selection == file } }
        files.removeAll { gone.contains($0) }
        bar.show(count: files.count, actions: Self.sharedActions(of: files))
        if parts.isEmpty { onClose?() } else { onFilesGone?(gone) }
    }

    // MARK: Actions

    /// What fits every file: working directory files that all have unstaged changes, or that are all staged.
    static func sharedActions(of files: [FileSelection]) -> [StackedDiffBar.Action] {
        if !files.isEmpty, files.allSatisfy(\.isStageable) { return [.discard, .stage] }
        if !files.isEmpty, files.allSatisfy(\.isUnstageable) { return [.unstage] }
        return []
    }

    private func run(_ action: StackedDiffBar.Action) {
        let paths = files.map(\.path)
        switch action {
        case .stage: staging.stage(paths)
        case .unstage: staging.unstage(paths)
        case .discard: staging.discard(files)
        }
    }

}

/// The bar above stacked diffs: how many files, the actions they share, and close.
final class StackedDiffBar: BarView {
    enum Action { case stage, unstage, discard }

    var onClose: (() -> Void)?
    var onAction: ((Action) -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    let close = NSButton()
    private var actions: [Action] = []

    init() {
        super.init(edge: .bottom)
        title.font = Theme.bodyStrong
        title.textColor = Theme.ink
        let closeSymbol = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "diff.toolbar.close", defaultValue: "Close", bundle: .module))?.withSymbolConfiguration(closeSymbol)
        close.bezelStyle = .rounded
        close.toolTip = String(localized: "diff.toolbar.closeToolTip", defaultValue: "Close (Esc)", bundle: .module)
        close.target = self
        close.action = #selector(closePressed(_:))
        close.keyEquivalent = "\u{1b}"
        buttons.orientation = .horizontal
        buttons.spacing = Theme.Space.s
        let trailing = NSStackView(views: [buttons, close])
        trailing.orientation = .horizontal
        trailing.spacing = Theme.Space.m
        for view in [title, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Theme.Space.m),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(count: Int, actions: [Action]) {
        title.stringValue = String(localized: "diff.stack.count", defaultValue: "\(count) files selected", bundle: .module)
        self.actions = actions
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: Self.title(of: action), target: self, action: #selector(actionPressed(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            buttons.addArrangedSubview(button)
        }
    }

    private static func title(of action: Action) -> String {
        switch action {
        case .stage: String(localized: "diff.stack.stage", defaultValue: "Stage files", bundle: .module)
        case .unstage: String(localized: "diff.stack.unstage", defaultValue: "Unstage files", bundle: .module)
        case .discard: String(localized: "files.menu.discard", defaultValue: "Discard…", bundle: .module)
        }
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onAction?(actions[sender.tag])
    }

    @objc private func closePressed(_ sender: Any?) { onClose?() }
}

/// Stacks from the top, so a short stack sits under the bar.
private final class StackDocumentView: NSView {
    override var isFlipped: Bool { true }
}
