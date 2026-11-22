import AppKit
import GitEngine

/// The banner above the history while git is in the middle of a rebase, cherry-pick, revert or merge, and its actions.
/// It follows the repository: it appears on every refresh that finds the operation, also right after the app opens, and goes away once git has finished.
@MainActor
final class OperationBannerController {
    let view = OperationBannerView()
    private let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    private(set) var progress: OperationProgress?
    /// Each update starts a new read; only the latest one may change the banner.
    private var generation = 0
    private var isRunning = false
    /// "Commit ändern" at an edit stop: opens the commit form with amend.
    var onAmend: (() -> Void)?
    /// The banner shows another state; the commit form follows whether git waits at an edit stop.
    var onStateChange: (() -> Void)?
    /// Says what continuing or skipping left out, in a toast.
    var onToast: ((RefString) -> Void)?
    /// The operation is over, finished or aborted, however it got there; the tab selects HEAD and leaves the conflict state behind.
    var onEnded: (() -> Void)?

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
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
        view.show(text: Self.describe(progress, conflicts: conflicts, ontoName: target.map(name(of:))), conflicts: conflicts, canContinue: conflicts == 0 && !isRunning, canSkip: progress.kind.canSkip, canAmend: isEditStop, isEnabled: !isRunning)
        view.isHidden = false
    }

    /// True while an interactive rebase waits at an `edit` step for the commit to be amended.
    var isEditStop: Bool {
        if case .edit? = progress?.stop { true } else { false }
    }

    /// "Rebase von feature auf main: Schritt 3 von 7, 2 Konflikte", or at an edit stop "Angehalten zum Bearbeiten von 1a2b3c4 „Subject“ · Schritt 3 von 7 · Rebase von feature auf …"
    static func describe(_ progress: OperationProgress, conflicts: Int, ontoName: RefString?) -> RefString {
        let from: RefString = progress.branch.map { " von \(branch: $0)" } ?? ""
        let onto: RefString = ontoName.map { " auf \($0)" } ?? ""
        let commit: RefString = progress.commit.map { " von \(commit: $0)" } ?? ""
        let head: RefString = switch progress.kind {
        case .rebase: "Rebase\(from)\(onto)"
        case .cherryPick: "Cherry-pick\(commit)"
        case .revert: "Revert\(commit)"
        case .merge: "Merge\(ontoName.map { " von \($0)" } ?? "")"
        }
        let step = progress.step.flatMap { step in progress.total.map { RefString("Schritt \(step) von \($0)") } }
        // A stop that waits for the user leads, so a narrow banner still says why it waits.
        switch (progress.stop, conflicts) {
        case let (.edit(commit, subject)?, 0):
            return RefString.joined(["Angehalten zum Bearbeiten von \(commit: commit) „\(subject)“", step].compactMap { $0 } + [head], separator: " · ")
        case let (.exec(command)?, 0):
            return RefString.joined(["„\(command)“ fehlgeschlagen", step].compactMap { $0 } + [head], separator: " · ")
        default:
            break
        }
        var parts = [step?.plain].compactMap { $0 }
        switch conflicts {
        case 0: parts.append("keine Konflikte offen")
        case 1: parts.append("1 Konflikt")
        default: parts.append("\(conflicts) Konflikte")
        }
        return "\(head): \(parts.joined(separator: ", "))"
    }

    /// The branch, remote branch or tag at a commit, or its short SHA.
    private func name(of sha: String) -> RefString {
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
        guard let ref = refs.filter({ order($0) < 3 }).min(by: { order($0) < order($1) }) else { return "\(commit: sha)" }
        return switch ref.kind {
        case .localBranch: "\(branch: ref.name)"
        case .tag: "\(tag: ref.name)"
        default: "\(remoteBranch: ref.name)"
        }
    }

    enum Action { case `continue`, skip, abort }

    func perform(_ action: Action) {
        guard let progress, !isRunning else { return }
        let kind = progress.kind
        let label = Self.label(of: kind)
        Task {
            if action == .abort {
                let alert = NSAlert()
                alert.messageText = "\(label) abbrechen?"
                alert.informativeText = "Branch, Index und Arbeitsverzeichnis kommen auf den Stand vor dem \(label). Bereits gelöste Konflikte gehen verloren."
                alert.addButton(withTitle: "\(label) abbrechen")
                alert.addButton(withTitle: "Weiter lösen")
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
                await viewModel.refresh(note: report?.skippedEmptyStep == true ? "git \(kind.command) --skip" : command)
                if let toast = GitFailureText.toast(for: report) { onToast?(toast) }
            } catch {
                isRunning = false
                let report = (error as? GitError).map { OperationReport(output: $0.stderr) }
                await viewModel.refresh(note: nil)
                if let toast = GitFailureText.toast(for: report) { onToast?(toast) }
                await prompter.report(error, title: "\(command) fehlgeschlagen", unlessStoppedIn: repository)
            }
            update()
        }
    }

    private static func label(of kind: OperationProgress.Kind) -> String {
        switch kind {
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .merge: "Merge"
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
    private(set) lazy var amendButton = button("Commit ändern …", #selector(amendCommit))
    private(set) lazy var continueButton = button("Fortsetzen", #selector(continueOperation))
    private(set) lazy var skipButton = button("Überspringen", #selector(skipOperation))
    private(set) lazy var abortButton = button("Abbrechen", #selector(abortOperation))
    private var hasConflicts = false

    var text: String { RefText.plain(label.stringValue) }

    init() {
        super.init(frame: .zero)
        label.font = Theme.bodyMedium
        label.textColor = Theme.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The label takes the free width, so the actions sit at the right end.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.regular, weight: .medium)
        let buttons = NSStackView(views: [amendButton, continueButton, skipButton, abortButton])
        buttons.spacing = Theme.OperationBanner.spacing
        let row = NSStackView(views: [glyph, label, buttons])
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

    func show(text: RefString, conflicts: Int, canContinue: Bool, canSkip: Bool, canAmend: Bool, isEnabled: Bool) {
        label.setText(text)
        label.toolTip = text.plain
        hasConflicts = conflicts > 0
        glyph.image = NSImage(systemSymbolName: hasConflicts ? "exclamationmark.triangle.fill" : "arrow.triangle.branch", accessibilityDescription: nil)
        glyph.contentTintColor = hasConflicts ? Theme.persimmon : Theme.clay
        continueButton.isEnabled = canContinue
        skipButton.isEnabled = isEnabled
        skipButton.isHidden = !canSkip
        abortButton.isEnabled = isEnabled
        amendButton.isHidden = !canAmend
        amendButton.isEnabled = isEnabled
        amendButton.toolTip = "Öffnet das Commit-Formular mit Amend; danach Fortsetzen"
        needsDisplay = true
    }

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
