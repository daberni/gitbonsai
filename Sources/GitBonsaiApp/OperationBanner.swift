import AppKit
import GitEngine

/// The banner above the history while git is in the middle of a rebase, cherry-pick or revert, and its three actions.
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

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
        view.isHidden = true
        view.onContinue = { [weak self] in self?.perform(.continue) }
        view.onSkip = { [weak self] in self?.perform(.skip) }
        view.onAbort = { [weak self] in self?.perform(.abort) }
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
        self.progress = progress
        guard let progress else {
            view.isHidden = true
            return
        }
        let conflicts = viewModel.status?.conflicted.count ?? 0
        view.show(text: Self.describe(progress, conflicts: conflicts, ontoName: progress.onto.map(name(of:))), conflicts: conflicts, canContinue: conflicts == 0 && !isRunning, isEnabled: !isRunning)
        view.isHidden = false
    }

    /// "Rebase auf main: Schritt 3 von 7, 2 Konflikte"
    static func describe(_ progress: OperationProgress, conflicts: Int, ontoName: String?) -> String {
        var head: String
        switch progress.kind {
        case .rebase:
            head = "Rebase" + (progress.branch.map { " von „\($0)“" } ?? "") + (ontoName.map { " auf \($0)" } ?? "")
        case .cherryPick:
            head = "Cherry-pick" + (progress.commit.map { " von \($0.prefix(7))" } ?? "")
        case .revert:
            head = "Revert" + (progress.commit.map { " von \($0.prefix(7))" } ?? "")
        }
        var parts: [String] = []
        if let step = progress.step, let total = progress.total { parts.append("Schritt \(step) von \(total)") }
        switch conflicts {
        case 0: parts.append("keine Konflikte offen")
        case 1: parts.append("1 Konflikt")
        default: parts.append("\(conflicts) Konflikte")
        }
        return head + ": " + parts.joined(separator: ", ")
    }

    /// The branch, remote branch or tag at a commit, or its short SHA.
    private func name(of sha: String) -> String {
        let refs = viewModel.refs.filter { $0.target == sha }
        let order: (Ref) -> Int = { ref in
            switch ref.kind {
            case .localBranch: 0
            case .remoteBranch: 1
            case .tag: 2
            default: 3
            }
        }
        return refs.filter { order($0) < 3 }.min { order($0) < order($1) }?.name ?? String(sha.prefix(7))
    }

    enum Action { case `continue`, skip, abort }

    private func perform(_ action: Action) {
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
                switch action {
                case .continue: try await repository.continueOperation(kind)
                case .skip: try await repository.skipOperation(kind)
                case .abort: try await repository.abortOperation(kind)
                }
                isRunning = false
                await viewModel.refresh(note: command)
            } catch {
                isRunning = false
                await viewModel.refresh(note: nil)
                let stopped = (error as? GitError)?.stoppedOnConflict == true
                prompter.report(error, title: stopped ? "\(label) mit Konflikten angehalten" : "\(command) fehlgeschlagen")
            }
            update()
        }
    }

    private static func label(of kind: OperationProgress.Kind) -> String {
        switch kind {
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }
}

/// A rounded, matte strip: clay-soft while git waits, persimmon-soft while conflicts are open. Text on the left, the actions on the right.
final class OperationBannerView: NSView {
    var onContinue: (() -> Void)?
    var onSkip: (() -> Void)?
    var onAbort: (() -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) lazy var continueButton = button("Fortsetzen", #selector(continueOperation))
    private(set) lazy var skipButton = button("Überspringen", #selector(skipOperation))
    private(set) lazy var abortButton = button("Abbrechen", #selector(abortOperation))
    private var hasConflicts = false

    var text: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        label.font = Theme.bodyMedium
        label.textColor = Theme.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The label takes the free width, so the actions sit at the right end.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.regular, weight: .medium)
        let buttons = NSStackView(views: [continueButton, skipButton, abortButton])
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

    func show(text: String, conflicts: Int, canContinue: Bool, isEnabled: Bool) {
        label.stringValue = text
        label.toolTip = text
        hasConflicts = conflicts > 0
        glyph.image = NSImage(systemSymbolName: hasConflicts ? "exclamationmark.triangle.fill" : "arrow.triangle.branch", accessibilityDescription: nil)
        glyph.contentTintColor = hasConflicts ? Theme.persimmon : Theme.clay
        continueButton.isEnabled = canContinue
        skipButton.isEnabled = isEnabled
        abortButton.isEnabled = isEnabled
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
}
