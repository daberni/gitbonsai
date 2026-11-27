import AppKit
import GitEngine

/// The banner above the history while git is in the middle of a rebase, cherry-pick, revert or merge, and its actions.
/// It follows the repository: it appears on every refresh that finds the operation, also right after the app opens, and goes away once git has finished.
@MainActor
final class OperationBannerController {
    let view = OperationBannerView()
    private let viewModel: GraphViewModel
    private let prompter: any Prompting
    private(set) var progress: OperationProgress?
    /// Each update starts a new read; only the latest one may change the banner.
    private var generation = 0
    private var isRunning = false
    /// "Amend Commit" at an edit stop: opens the commit form with amend.
    var onAmend: (() -> Void)?
    /// The banner shows another state; the commit form follows whether git waits at an edit stop.
    var onStateChange: (() -> Void)?
    /// The operation is over, finished or aborted, however it got there; the tab selects HEAD and leaves the conflict state behind.
    var onEnded: (() -> Void)?

    init(context: RepositoryContext) {
        viewModel = context.model
        prompter = context.prompter
        view.isHidden = true
        view.onContinue = { [weak self] in self?.perform(.continue) }
        view.onSkip = { [weak self] in self?.perform(.skip) }
        view.onAbort = { [weak self] in self?.perform(.abort) }
        view.onAmend = { [weak self] in self?.onAmend?() }
    }

    /// Reads git's state again; called whenever the tab's status or refs changed.
    func update() {
        generation += 1
        let current = generation
        let repository = viewModel.repository
        Task {
            let progress = await repository.operationInProgress()
            guard current == generation else { return }
            show(progress)
        }
    }

    /// The status changed, for instance after staging a resolved file: the conflict count follows without asking git about the operation again.
    func statusChanged() {
        guard let progress else { return }
        show(progress)
    }

    private func show(_ progress: OperationProgress?) {
        let wasEditStop = isEditStop
        let wasRunning = self.progress != nil
        self.progress = progress
        defer {
            if wasEditStop != isEditStop { onStateChange?() }
            if wasRunning, progress == nil { onEnded?() }
        }
        guard let progress else {
            view.isHidden = true
            return
        }
        let conflicts = viewModel.status?.conflicted.count ?? 0
        // A merge names what it brings in, a rebase where it replays onto.
        let target = progress.kind == .merge ? progress.commit : progress.onto
        view.show(text: { [weak self] limit in Self.describe(progress, conflicts: conflicts, ontoName: target.map { self?.name(of: $0, limit: limit) ?? RefString(marked: RefName.commit($0)) }, nameLimit: limit) }, conflicts: conflicts, canContinue: conflicts == 0 && !isRunning, canSkip: progress.kind.canSkip, canAmend: isEditStop, isEnabled: !isRunning)
        view.isHidden = false
    }

    /// True while an interactive rebase waits at an `edit` step for the commit to be amended.
    var isEditStop: Bool {
        if case .edit? = progress?.stop { true } else { false }
    }

    /// What the banner says: the operation, which may shorten, and its state, which always shows whole.
    struct Description {
        /// "Rebase of feature onto main"
        let head: RefString
        /// "Step 3 of 7, 2 conflicts", or at an edit stop "Stopped to edit 1a2b3c4 “Subject” · Step 3 of 7"
        let state: RefString
    }

    /// The operation's name is git's own word and stays the same in every language.
    /// `nameLimit` shortens branch names and the subject in their middle, so a narrow banner gives up names before it cuts the operation off; 0 leaves only the operation's name.
    static func describe(_ progress: OperationProgress, conflicts: Int, ontoName: RefString?, nameLimit: Int? = nil) -> Description {
        let label = progress.kind.label
        let from = progress.branch.map { RefName.branch(shortened($0, to: nameLimit)) }
        let onto = ontoName?.marked
        let commit = progress.commit.map(RefName.commit)
        let full: RefString = switch progress.kind {
        case .rebase:
            if let from, let onto { RefString(LocalizedStringResource("operation.banner.fromOnto", defaultValue: "\(label) of \(from) onto \(onto)", bundle: .module)) }
            else if let from { RefString(LocalizedStringResource("operation.banner.of", defaultValue: "\(label) of \(from)", bundle: .module)) }
            else if let onto { RefString(LocalizedStringResource("operation.banner.onto", defaultValue: "\(label) onto \(onto)", bundle: .module)) }
            else { RefString(verbatim: label) }
        case .cherryPick, .revert: commit.map { RefString(LocalizedStringResource("operation.banner.of", defaultValue: "\(label) of \($0)", bundle: .module)) } ?? RefString(verbatim: label)
        case .merge: onto.map { RefString(LocalizedStringResource("operation.banner.of", defaultValue: "\(label) of \($0)", bundle: .module)) } ?? RefString(verbatim: label)
        }
        let head = nameLimit == 0 ? RefString(verbatim: label) : full
        let step = progress.step.flatMap { step in progress.total.map { RefString(LocalizedStringResource("operation.banner.step", defaultValue: "Step \(step) of \($0)", bundle: .module)) } }
        // A stop that waits for the user leads, so a narrow banner still says why it waits. The parts are complete on their own and only listed.
        let stop: RefString? = switch (progress.stop, conflicts) {
        case let (.edit(commit, subject)?, 0): RefString(LocalizedStringResource("operation.banner.stoppedToEdit", defaultValue: "Stopped to edit \(RefName.commit(commit)) “\(shortened(subject, to: nameLimit))”", bundle: .module))
        case let (.exec(command)?, 0): RefString(LocalizedStringResource("operation.banner.execFailed", defaultValue: "“\(command)” failed", bundle: .module))
        default: nil
        }
        if let stop {
            return Description(head: head, state: RefString(marked: [stop, step].compactMap { $0 }.map(\.marked).joined(separator: " · ")))
        }
        let open = conflicts == 0 ? RefString(LocalizedStringResource("operation.banner.noConflicts", defaultValue: "no open conflicts", bundle: .module)) : RefString(LocalizedStringResource("operation.banner.conflicts", defaultValue: "\(conflicts) conflicts", bundle: .module))
        return Description(head: head, state: RefString(marked: ([step].compactMap { $0 } + [open]).map(\.marked).joined(separator: ", ")))
    }

    /// `text` with its middle replaced by "…" when it is longer than `limit` characters.
    static func shortened(_ text: String, to limit: Int?) -> String {
        guard let limit, text.count > limit else { return text }
        let head = (limit + 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(max(limit - head, 1)))
    }

    /// The branch, remote branch or tag at a commit, or its short SHA; `limit` shortens the name as `describe` does.
    func name(of sha: String, limit: Int? = nil) -> RefString {
        // origin/HEAD only repeats the branch it points at.
        let refs = viewModel.refs.filter { $0.target == sha && !$0.name.hasSuffix("/HEAD") }
        let order: (Ref) -> Int = { ref in
            switch ref.kind {
            case .localBranch: 0
            case .remoteBranch: 1
            case .tag: 2
            default: 3
            }
        }
        guard let ref = refs.filter({ order($0) < 3 }).min(by: { order($0) < order($1) }) else { return RefString(marked: RefName.commit(sha)) }
        return switch ref.kind {
        case .localBranch: RefString(marked: RefName.branch(Self.shortened(ref.name, to: limit)))
        case .tag: RefString(marked: RefName.tag(Self.shortened(ref.name, to: limit)))
        default: RefString(marked: RefName.remoteBranch(Self.shortened(ref.name, to: limit)))
        }
    }

    enum Action { case `continue`, skip, abort }

    func perform(_ action: Action) {
        guard let progress, !isRunning else { return }
        let kind = progress.kind
        let label = kind.label
        Task {
            if action == .abort {
                let alert = NSAlert()
                alert.messageText = String(localized: "operation.abort.title", defaultValue: "Abort \(label)?", bundle: .module, comment: "The argument is git's operation: Rebase, Cherry-pick, Revert or Merge.")
                alert.addButton(withTitle: String(localized: "operation.abort.confirm", defaultValue: "Abort \(label)", bundle: .module, comment: "Button; the argument is git's operation: Rebase, Cherry-pick, Revert or Merge."))
                alert.addButton(withTitle: String(localized: "operation.abort.keepResolving", defaultValue: "Keep resolving", bundle: .module))
                alert.buttons.first?.hasDestructiveAction = true
                guard await prompter.confirm(alert) else { return }
            }
            isRunning = true
            show(progress)
            let repository = viewModel.repository
            let command = "git \(kind.command) --\(action == .continue ? "continue" : action == .skip ? "skip" : "abort")"
            do {
                var report: OperationReport?
                switch action {
                case .continue: report = try await repository.continueOperation(kind)
                case .skip: report = try await repository.skipOperation(kind)
                case .abort: try await repository.abortOperation(kind)
                }
                isRunning = false
                // Continuing a step that the resolution left empty skips it; the toast says so.
                await viewModel.refresh(note: report?.skippedEmptyStep == true ? "git \(kind.command) --skip" : command, focus: .followHead)
                if let toast = GitFailureText.toast(for: report) { prompter.toast(toast) }
            } catch {
                isRunning = false
                let report = (error as? GitError).map { OperationReport(output: $0.stderr) }
                await viewModel.refresh(note: nil, focus: .followHead)
                if let toast = GitFailureText.toast(for: report) { prompter.toast(toast) }
                await prompter.reportUnlessStopped(error, title: LocalizedStringResource("failure.operation.failed", defaultValue: "\(command) failed", bundle: .module), stop: .operation(kind), actions: [], in: repository)
            }
            update()
        }
    }
}

/// A rounded, matte strip: clay-soft while git waits, persimmon-soft while conflicts are open. Text on the left, the actions on the right.
final class OperationBannerView: NSView {
    var onContinue: (() -> Void)?
    var onSkip: (() -> Void)?
    var onAbort: (() -> Void)?
    var onAmend: (() -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// Step and conflict count: never shortened, the operation's names give way first.
    private let stateLabel = NSTextField(labelWithString: "")
    /// Takes the free width between the text and the actions.
    private let spacer = NSView()
    private let buttons = NSStackView()
    /// The operation's text gets exactly the width it was fitted to; the label's own measure of name pills runs short.
    private lazy var labelWidth = label.widthAnchor.constraint(equalToConstant: 0)
    private(set) lazy var amendButton = button(String(localized: "operation.banner.amend", defaultValue: "Amend Commit…", bundle: .module), #selector(amendCommit))
    private(set) lazy var continueButton = button(String(localized: "operation.banner.continue", defaultValue: "Continue", bundle: .module, comment: "Continues a rebase, cherry-pick, revert or merge."), #selector(continueOperation))
    private(set) lazy var skipButton = button(String(localized: "operation.banner.skip", defaultValue: "Skip", bundle: .module, comment: "Skips the current step of a rebase, cherry-pick or revert."), #selector(skipOperation))
    private(set) lazy var abortButton = button(String(localized: "operation.banner.abort", defaultValue: "Abort", bundle: .module, comment: "Aborts a rebase, cherry-pick, revert or merge."), #selector(abortOperation))
    private var hasConflicts = false

    var text: String { RefText.plain(label.stringValue) + " · " + RefText.plain(stateLabel.stringValue) }

    init() {
        super.init(frame: .zero)
        label.font = Theme.bodyMedium
        label.textColor = Theme.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = Theme.bodyMedium
        stateLabel.textColor = Theme.ink
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The spacer takes the free width, so the actions sit at the right end, as in the diff header.
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.regular, weight: .medium)
        // The way forward is the rightmost button and Abort stands left of it, as Cancel does in macOS dialogs.
        buttons.setViews([amendButton, skipButton, abortButton, continueButton], in: .leading)
        buttons.spacing = Theme.OperationBanner.spacing
        buttons.setHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [glyph, label, stateLabel, spacer, buttons])
        row.distribution = .fill
        // Name pills make the operation's line taller than the state's; their text shares one baseline.
        row.alignment = .firstBaseline
        row.spacing = Theme.OperationBanner.spacing
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let inset = Theme.OperationBanner.inset
        let padding = Theme.OperationBanner.padding
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.OperationBanner.height + 2 * inset),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inset + padding)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The banner's text for a limit on the length of names, nil for full names.
    private var describe: ((Int?) -> OperationBannerController.Description)?

    func show(text: @escaping (Int?) -> OperationBannerController.Description, conflicts: Int, canContinue: Bool, canSkip: Bool, canAmend: Bool, isEnabled: Bool) {
        describe = text
        let full = text(nil)
        label.toolTip = full.head.plain
        stateLabel.setText(full.state)
        shownHead = nil
        fitText()
        hasConflicts = conflicts > 0
        glyph.image = NSImage(systemSymbolName: hasConflicts ? "exclamationmark.triangle.fill" : "arrow.triangle.branch", accessibilityDescription: nil)
        glyph.contentTintColor = hasConflicts ? Theme.persimmon : Theme.clay
        continueButton.isEnabled = canContinue
        skipButton.isEnabled = isEnabled
        skipButton.isHidden = !canSkip
        abortButton.isEnabled = isEnabled
        amendButton.isHidden = !canAmend
        amendButton.isEnabled = isEnabled
        amendButton.toolTip = String(localized: "operation.banner.amendToolTip", defaultValue: "Opens the commit form with amend; then Continue", bundle: .module)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        fitText()
    }

    /// Full names when they fit the width left of the state; otherwise names shortened step by step before the text is cut off.
    private func fitText() {
        guard let describe, let font = label.font else { return }
        // The width left once the glyph, the state and the visible actions have theirs, worked out from the banner's own width so it does not depend on an earlier pass.
        let visible = [glyph, label, stateLabel, spacer, buttons].filter { !$0.isHidden }
        let inner = bounds.width - 2 * (Theme.OperationBanner.inset + Theme.OperationBanner.padding)
        let width = inner - glyph.fittingSize.width - stateLabel.fittingSize.width - buttons.fittingSize.width - CGFloat(visible.count - 1) * Theme.OperationBanner.spacing
        let heads = Self.nameLimits.lazy.map { describe($0).head }
        let fitting = bounds.width == 0 ? describe(nil).head : heads.first { RefText.attributed($0, font: font).size().width <= width } ?? describe(Self.nameLimits.last ?? nil).head
        let needed = ceil(RefText.attributed(fitting, font: font).size().width) + Theme.Space.xs
        labelWidth.constant = max(min(needed, width), 0)
        labelWidth.isActive = bounds.width > 0
        guard fitting.marked != shownHead?.marked else { return }
        shownHead = fitting
        label.setText(fitting)
        // The shorter or longer text changes what the label needs; the next pass places it.
        needsLayout = true
    }

    private var shownHead: RefString?
    private static let nameLimits: [Int?] = [nil, 32, 24, 16, 10, 6, 0]

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.OperationBanner.inset, dy: Theme.OperationBanner.inset), xRadius: Theme.OperationBanner.radius, yRadius: Theme.OperationBanner.radius)
        (hasConflicts ? Theme.persimmonSoft : Theme.claySoft).setFill()
        shape.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func continueOperation() { onContinue?() }
    @objc private func skipOperation() { onSkip?() }
    @objc private func abortOperation() { onAbort?() }
    @objc private func amendCommit() { onAmend?() }
}
