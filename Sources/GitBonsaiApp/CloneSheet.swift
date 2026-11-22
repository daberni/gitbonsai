import AppKit
import GitEngine

/// The form of "Clone Repository": source, destination, options, and while git runs its progress. `CloneController` fills and reads it.
@MainActor
final class CloneSheet: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    let urlField = NSTextField()
    let destinationField = NSTextField()
    let branchField = NSTextField()
    let submodules = NSButton(checkboxWithTitle: String(localized: "clone.sheet.submodules", defaultValue: "Clone submodules too", bundle: .module), target: nil, action: nil)
    let shallow = NSButton(checkboxWithTitle: String(localized: "clone.sheet.shallow", defaultValue: "Latest snapshot only (--depth 1)", bundle: .module), target: nil, action: nil)
    let cloneButton = NSButton(title: String(localized: "clone.sheet.clone", defaultValue: "Clone", bundle: .module, comment: "The clone sheet's confirm button."), target: nil, action: nil)
    let cancelButton = NSButton(title: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module), target: nil, action: nil)
    let chooseButton = NSButton(title: String(localized: "common.chooseEllipsis", defaultValue: "Choose …", bundle: .module), target: nil, action: nil)
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
        let title = NSTextField(labelWithString: String(localized: "clone.sheet.title", defaultValue: "Clone Repository", bundle: .module))
        title.font = Theme.title
        let info = NSTextField(wrappingLabelWithString: String(localized: "clone.sheet.info", defaultValue: "git clone downloads the repository. Sign-in goes through the credential helper or the SSH agent.", bundle: .module))
        info.font = Theme.caption
        info.textColor = Theme.inkMuted
        urlField.placeholderString = String(localized: "clone.sheet.urlPlaceholder", defaultValue: "https://… or git@host:path.git", bundle: .module)
        branchField.placeholderString = String(localized: "clone.sheet.branchPlaceholder", defaultValue: "The remote's default branch", bundle: .module)
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
        progressLabel.textColor = Theme.inkMuted
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
        stack.addArrangedSubview(row(LocalizedStringResource("clone.sheet.url", defaultValue: "URL", bundle: .module), urlField))
        stack.addArrangedSubview(row(LocalizedStringResource("clone.sheet.destination", defaultValue: "Destination", bundle: .module, comment: "Label of the clone sheet's folder field."), destinationRow))
        stack.addArrangedSubview(warning)
        stack.addArrangedSubview(row(LocalizedStringResource("clone.sheet.branch", defaultValue: "Branch", bundle: .module, comment: "Label of the clone sheet's branch field."), branchField))
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
        // With an initial first responder AppKit builds no key view loop of its own.
        window.autorecalculatesKeyViewLoop = true
        window.initialFirstResponder = urlField
    }

    private var progressRow: NSView?

    private func row(_ label: LocalizedStringResource, _ control: NSView) -> NSView {
        SheetSupport.captionRow(label, control: control, width: M.width - 2 * M.padding)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?()
    }

    // MARK: States

    /// While git runs the form is locked; only Cancel stays, and it stops git.
    func showRunning(_ running: Bool) {
        for control in [urlField, destinationField, branchField, submodules, shallow, chooseButton, cloneButton] as [NSControl] { control.isEnabled = !running }
        progressRow?.isHidden = !running
        if running {
            failure.isHidden = true
            progressBar.fraction = 0
            progressLabel.stringValue = String(localized: "clone.progress.connecting", defaultValue: "Connecting…", bundle: .module)
        }
        fitWindow()
    }

    func show(_ progress: CloneProgress) {
        progressBar.fraction = progress.fraction
        let completed = progress.completed.formatted(.number.locale(AppLanguage.locale))
        let total = progress.total.formatted(.number.locale(AppLanguage.locale))
        progressLabel.stringValue = String(localized: "clone.progress.phase", defaultValue: "\(Self.title(of: progress.phase)): \(completed) of \(total)", bundle: .module, comment: "Clone progress: the phase, then objects done and all objects.")
    }

    func showWarning(_ text: String?) {
        warning.stringValue = text ?? ""
        guard warning.isHidden != (text == nil) else { return }
        warning.isHidden = text == nil
        fitWindow()
    }

    func showFailure(_ error: Error) {
        failure.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let summary = NSTextField(wrappingLabelWithString: "")
        summary.font = Theme.body
        summary.textColor = Theme.persimmon
        summary.setText(GitFailureText.summary(of: error))
        summary.preferredMaxLayoutWidth = M.width - 2 * M.padding
        failure.addArrangedSubview(summary)
        if let details = GitFailureText.details(of: error), details != summary.stringValue {
            let view = FailureDetailsView(details: details, width: M.width - 2 * M.padding)
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
        case .counting: String(localized: "clone.progress.counting", defaultValue: "Counting objects", bundle: .module)
        case .compressing: String(localized: "clone.progress.compressing", defaultValue: "Compressing objects", bundle: .module)
        case .receiving: String(localized: "clone.progress.receiving", defaultValue: "Receiving objects", bundle: .module)
        case .resolving: String(localized: "clone.progress.resolving", defaultValue: "Resolving deltas", bundle: .module)
        case .updatingFiles: String(localized: "clone.progress.checkingOut", defaultValue: "Checking out files", bundle: .module)
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
