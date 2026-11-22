import AppKit
import GitEngine

/// The form of "Repository klonen": source, destination, options, and while git runs its progress. `CloneController` fills and reads it.
@MainActor
final class CloneSheet: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    let urlField = NSTextField()
    let destinationField = NSTextField()
    let branchField = NSTextField()
    let submodules = NSButton(checkboxWithTitle: "Submodule mitklonen", target: nil, action: nil)
    let shallow = NSButton(checkboxWithTitle: "Nur den neuesten Stand (--depth 1)", target: nil, action: nil)
    let cloneButton = NSButton(title: "Klonen", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    let chooseButton = NSButton(title: "Wählen …", target: nil, action: nil)
    /// Under the destination: why the folder cannot take the clone.
    let warning = NSTextField(wrappingLabelWithString: "")
    let progressBar = CloneProgressBar()
    let progressLabel = NSTextField(labelWithString: "")
    /// The failure of the last attempt, with git's output behind "Details".
    let failure = NSStackView()

    var onChange: (() -> Void)?

    private typealias M = Theme.Clone
    private let stack = NSStackView()

    override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: M.width, height: M.minimumHeight)), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "Repository klonen")
        title.font = Theme.title
        let info = NSTextField(wrappingLabelWithString: "git clone lädt das Repository herunter. Anmeldung über den Credential-Helper oder den SSH-Agent.")
        info.font = Theme.caption
        info.textColor = .secondaryLabelColor
        urlField.placeholderString = "https://… oder git@host:pfad.git"
        branchField.placeholderString = "Standard-Branch des Remotes"
        for field in [urlField, destinationField, branchField] {
            field.delegate = self
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
        }
        warning.font = Theme.caption
        warning.textColor = Theme.persimmon
        warning.isHidden = true
        let destinationRow = NSStackView(views: [destinationField, chooseButton])
        destinationRow.spacing = Theme.ActionSheet.labelSpacing
        destinationField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressBar.heightAnchor.constraint(equalToConstant: M.barHeight).isActive = true
        progressLabel.font = Theme.captionDigits
        progressLabel.textColor = .secondaryLabelColor
        let progress = NSStackView(views: [progressBar, progressLabel])
        progress.orientation = .vertical
        progress.alignment = .leading
        progress.spacing = Theme.ActionSheet.labelSpacing
        progress.isHidden = true
        progressRow = progress
        failure.orientation = .vertical
        failure.alignment = .leading
        failure.spacing = Theme.ActionSheet.labelSpacing
        failure.isHidden = true
        cloneButton.keyEquivalent = "\r"
        cloneButton.bezelColor = Theme.moss
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, cloneButton])
        buttons.spacing = Theme.Space.s
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.ActionSheet.rowSpacing
        stack.edgeInsets = NSEdgeInsets(top: M.padding, left: M.padding, bottom: M.padding, right: M.padding)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(info)
        stack.setCustomSpacing(M.sectionGap, after: info)
        stack.addArrangedSubview(row("URL", urlField))
        stack.addArrangedSubview(row("Ziel", destinationRow))
        stack.addArrangedSubview(warning)
        stack.addArrangedSubview(row("Branch", branchField))
        stack.addArrangedSubview(submodules)
        stack.addArrangedSubview(shallow)
        stack.setCustomSpacing(M.sectionGap, after: shallow)
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(failure)
        stack.addArrangedSubview(buttons)
        let fieldWidth = M.width - 2 * M.padding
        for view in [info, warning, progress, progressBar, failure, buttons] as [NSView] {
            view.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        }
        warning.preferredMaxLayoutWidth = fieldWidth
        info.preferredMaxLayoutWidth = fieldWidth
        window.contentView = stack
        window.initialFirstResponder = urlField
    }

    private var progressRow: NSView?

    private func row(_ label: String, _ control: NSView) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = Theme.caption
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [caption, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Theme.ActionSheet.labelSpacing
        control.widthAnchor.constraint(equalToConstant: M.width - 2 * M.padding).isActive = true
        return row
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?()
    }

    // MARK: States

    /// While git runs the form is locked; only Abbrechen stays, and it stops git.
    func showRunning(_ running: Bool) {
        for control in [urlField, destinationField, branchField, submodules, shallow, chooseButton, cloneButton] as [NSControl] { control.isEnabled = !running }
        progressRow?.isHidden = !running
        if running {
            failure.isHidden = true
            progressBar.fraction = 0
            progressLabel.stringValue = "Verbinde …"
        }
        fitWindow()
    }

    func show(_ progress: CloneProgress) {
        progressBar.fraction = progress.fraction
        let counts = "\(progress.completed.formatted()) von \(progress.total.formatted())"
        progressLabel.stringValue = "\(Self.title(of: progress.phase)): \(counts)"
    }

    func showWarning(_ text: String?) {
        warning.stringValue = text ?? ""
        guard warning.isHidden != (text == nil) else { return }
        warning.isHidden = text == nil
        fitWindow()
    }

    func showFailure(_ error: Error) {
        failure.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let summary = NSTextField(wrappingLabelWithString: GitFailureText.summary(of: error))
        summary.font = Theme.body
        summary.textColor = Theme.persimmon
        summary.preferredMaxLayoutWidth = M.width - 2 * M.padding
        failure.addArrangedSubview(summary)
        if let details = GitFailureText.details(of: error), details != summary.stringValue {
            let view = FailureDetailsView(details: details)
            view.onToggle = { [weak self] in self?.fitWindow() }
            failure.addArrangedSubview(view)
        }
        failure.isHidden = false
        fitWindow()
    }

    func fitWindow() {
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: M.width, height: max(stack.fittingSize.height, M.minimumHeight))
        window.setContentSize(size)
    }

    private static func title(of phase: CloneProgress.Phase) -> String {
        switch phase {
        case .counting: "Objekte zählen"
        case .compressing: "Objekte komprimieren"
        case .receiving: "Objekte empfangen"
        case .resolving: "Deltas auflösen"
        case .updatingFiles: "Dateien auschecken"
        }
    }
}

/// A thin bar that shows the share of the current phase at once, without the system bar's easing.
final class CloneProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Theme.hairline.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let filled = CGRect(x: 0, y: 0, width: max(bounds.width * min(max(fraction, 0), 1), bounds.height), height: bounds.height)
        Theme.moss.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
