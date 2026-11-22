import AppKit
import GitEngine

/// The app's words for a failed git command: one sentence of what happened, with git's own output kept as details.
enum GitFailureText {
    /// "Commit 11f8174 „Add an ETP tab“ ließ sich nicht anwenden."
    static func summary(of error: Error) -> String {
        guard let gitError = error as? GitError else { return error.localizedDescription }
        switch GitFailure(output: gitError.stderr) {
        case let .couldNotApply(commit, subject): return "Commit \(commit)\(quoted(subject)) ließ sich nicht anwenden."
        case let .couldNotRevert(commit, subject): return "Commit \(commit)\(quoted(subject)) ließ sich nicht zurücknehmen."
        case let .conflicts(paths): return "Konflikte in \(list(paths))."
        case let .localChangesInTheWay(paths) where paths.isEmpty: return "Lokale Änderungen würden überschrieben."
        case let .localChangesInTheWay(paths): return "Lokale Änderungen würden überschrieben: \(list(paths))."
        case .uncommittedChanges: return "Nicht committete Änderungen stehen im Weg; erst committen oder stashen."
        case .emptyStep: return "Der Schritt ist leer, es gibt nichts zu committen."
        case let .message(text) where text.isEmpty: return "git meldet einen Fehler (Exit-Code \(gitError.exitCode))."
        case let .message(text): return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    /// git's output as a terminal would show it, or nil when it says nothing beyond the summary.
    static func details(of error: Error) -> String? {
        guard let gitError = error as? GitError else { return nil }
        let text = GitFailure.visibleText(gitError.stderr)
        return text.isEmpty ? nil : text
    }

    /// The toast for what a rebase, cherry-pick or revert reported besides its result, or nil.
    static func toast(for report: OperationReport?) -> String? {
        guard let report else { return nil }
        var parts: [String] = []
        switch report.alreadyApplied {
        case 0: break
        case 1: parts.append("1 bereits enthaltener Commit übersprungen")
        default: parts.append("\(report.alreadyApplied) bereits enthaltene Commits übersprungen")
        }
        if report.skippedEmptyStep { parts.append(parts.isEmpty ? "Leeren Schritt übersprungen" : "leeren Schritt übersprungen") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func quoted(_ subject: String) -> String { subject.isEmpty ? "" : " „\(subject)“" }

    private static func list(_ paths: [String]) -> String {
        paths.count > 3 ? paths.prefix(3).joined(separator: ", ") + " und \(paths.count - 3) weitere" : paths.joined(separator: ", ")
    }
}

/// "Details" under an error: a disclosure that shows git's output in a small scrolling text view.
@MainActor
final class FailureDetailsView: NSStackView {
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private let scroll = NSTextView.scrollableTextView()
    /// The alert lays itself out again so the window grows or shrinks with the details.
    var onToggle: (() -> Void)?

    init(details: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.ActionSheet.labelSpacing
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.target = self
        disclosure.action = #selector(toggle)
        let caption = NSTextField(labelWithString: "Details")
        caption.font = Theme.caption
        caption.textColor = Theme.inkMuted
        let header = NSStackView(views: [disclosure, caption])
        header.spacing = Theme.Space.xs
        let text = scroll.documentView as! NSTextView
        text.string = details
        text.font = Theme.monoSmall
        text.isEditable = false
        scroll.borderType = .bezelBorder
        scroll.isHidden = true
        addArrangedSubview(header)
        addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalToConstant: Theme.ActionSheet.fieldWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: Theme.FailureDetails.height).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    var isExpanded: Bool {
        get { !scroll.isHidden }
        set {
            disclosure.state = newValue ? .on : .off
            scroll.isHidden = !newValue
            layoutSubtreeIfNeeded()
            frame.size = fittingSize
            onToggle?()
        }
    }

    @objc private func toggle() { isExpanded = disclosure.state == .on }
}
