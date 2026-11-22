import AppKit
import GitEngine

/// The sheet of "Rebase interaktiv ab hier …": the steps oldest first on the left with the message of the selected one below them, the resulting history on the right,
/// hints and options at the bottom. It returns the plan to run, or nil when it was cancelled.
@MainActor
final class InteractiveRebaseSheet: NSObject, NSTextViewDelegate {
    private typealias M = Theme.InteractiveRebase

    let model: InteractiveRebaseModel
    let window: NSWindow
    let list: RebaseStepList
    let preview = RebasePreviewView()
    let messageView: NSTextView
    private let messageScroll: NSScrollView
    private let messageCaption = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    /// Published commits are only mentioned, quietly: the push asks before `--force-with-lease`.
    private let hint: NSTextField?
    private(set) var updateRefsBox: NSButton?
    private(set) var autostashBox: NSButton?
    let startButton = NSButton(title: "Rebase starten", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    /// The step whose message the editor shows.
    private var messageIndex: Int?

    init(model: InteractiveRebaseModel, publishedHint: String?) {
        self.model = model
        list = RebaseStepList(model: model)
        messageScroll = NSTextView.scrollableTextView()
        messageView = messageScroll.documentView as! NSTextView
        hint = publishedHint.map { NSTextField(wrappingLabelWithString: $0) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: M.size), styleMask: [.titled, .resizable, .docModalWindow], backing: .buffered, defer: false)
        super.init()
        window.minSize = M.minimumSize
        window.title = "Interaktives Rebase"
        window.contentView = FillView(color: Theme.surface0)
        build()
        model.onChange = { [weak self] in self?.modelChanged() }
        list.onSelect = { [weak self] index in self?.showMessage(of: index) }
        list.table.reloadData()
        list.select(0)
        modelChanged()
    }

    /// Shows the sheet on `parent` and waits for the answer.
    func run(on parent: NSWindow) async -> RebasePlan? {
        window.initialFirstResponder = list.table
        let response = await withCheckedContinuation { continuation in
            parent.beginSheet(window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? model.plan : nil
    }

    // MARK: Layout

    private func build() {
        let title = NSTextField(labelWithString: "„\(model.branch)“ interaktiv rebasen")
        title.font = Theme.title
        title.textColor = Theme.ink
        let count = model.original.count == 1 ? "1 Commit" : "\(model.original.count) Commits"
        let subtitle = NSTextField(labelWithString: "Ab \(model.baseCommit.shortID) „\(model.baseCommit.subject)“ · \(count), ältester oben · ziehen oder ⌥↑ ⌥↓ verschiebt, p r e s f d wählt die Aktion")
        subtitle.font = Theme.caption
        subtitle.textColor = Theme.inkMuted
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        messageCaption.font = Theme.caption
        messageCaption.textColor = Theme.inkMuted
        messageCaption.lineBreakMode = .byTruncatingTail
        messageScroll.borderType = .bezelBorder
        messageView.font = Theme.body
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.delegate = self
        messageView.setAccessibilityLabel("Commit-Nachricht")

        let left = NSStackView(views: [bordered(list.scrollView), messageCaption, messageScroll])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = Theme.Space.xs
        left.setCustomSpacing(M.spacing, after: left.views[0])

        let resultCaption = NSTextField(labelWithString: "Ergebnis, neuester oben")
        resultCaption.font = Theme.caption
        resultCaption.textColor = Theme.inkMuted
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = Theme.surface2
        preview.translatesAutoresizingMaskIntoConstraints = false
        let right = NSStackView(views: [resultCaption, bordered(previewScroll)])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = Theme.Space.xs

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = M.spacing
        columns.distribution = .fill

        summary.font = Theme.caption
        summary.textColor = Theme.inkMuted
        problem.font = Theme.caption
        problem.textColor = Theme.persimmon
        hint?.font = Theme.caption
        hint?.textColor = Theme.inkMuted
        var options: [NSView] = []
        if model.hasStackedBranches {
            let box = NSButton(checkboxWithTitle: "Abhängige Branches mitziehen (--update-refs)", target: self, action: #selector(updateRefsChanged(_:)))
            box.state = model.plan.updateRefs ? .on : .off
            box.toolTip = "Branches, die auf Commits im Bereich zeigen, wandern mit ihren Commits"
            updateRefsBox = box
            options.append(box)
        }
        if model.hasLocalChanges {
            let box = NSButton(checkboxWithTitle: "Lokale Änderungen vorher stashen und danach zurückholen (--autostash)", target: self, action: #selector(autostashChanged(_:)))
            box.state = model.plan.autostash ? .on : .off
            autostashBox = box
            options.append(box)
        }
        let notes = NSStackView(views: [summary, problem] + [hint].compactMap { $0 } + options)
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = Theme.Space.xs

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.spacing = Theme.Space.s
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [notes, spacer, buttons])
        footer.alignment = .bottom
        footer.spacing = M.spacing

        let content = NSStackView(views: [title, subtitle, columns, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Theme.Space.xs
        content.setCustomSpacing(M.spacing, after: subtitle)
        content.setCustomSpacing(M.spacing, after: columns)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: M.inset),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M.inset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M.inset),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -M.inset),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            columns.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            right.widthAnchor.constraint(equalToConstant: M.previewWidth),
            left.heightAnchor.constraint(equalTo: columns.heightAnchor),
            right.heightAnchor.constraint(equalTo: columns.heightAnchor),
            messageScroll.heightAnchor.constraint(equalToConstant: M.messageHeight),
            messageScroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            list.scrollView.widthAnchor.constraint(equalTo: left.widthAnchor),
            previewScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            messageCaption.widthAnchor.constraint(lessThanOrEqualTo: left.widthAnchor),
            preview.widthAnchor.constraint(equalTo: previewScroll.contentView.widthAnchor),
            preview.topAnchor.constraint(equalTo: previewScroll.contentView.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewScroll.contentView.leadingAnchor),
        ])
        columns.setContentHuggingPriority(.defaultLow, for: .vertical)
        problem.preferredMaxLayoutWidth = M.size.width - M.previewWidth
        hint?.preferredMaxLayoutWidth = M.size.width - M.previewWidth
    }

    /// A scroll view with a hairline frame that takes the free height of its column.
    private func bordered(_ scrollView: NSScrollView) -> NSScrollView {
        scrollView.borderType = .lineBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    // MARK: Updates

    private func modelChanged() {
        list.refresh()
        preview.show(model)
        summary.stringValue = model.isUnchanged ? "Nichts geändert" : model.summary
        let problemText = model.problemText ?? (model.plan.dropsEverything ? "Alle Commits verworfen: „\(model.branch)“ wird auf die Basis \(model.baseCommit.shortID) zurückgesetzt." : nil)
        problem.stringValue = problemText ?? ""
        problem.isHidden = problemText == nil
        problem.textColor = model.plan.problem == nil ? Theme.ochre : Theme.persimmon
        startButton.isEnabled = model.plan.problem == nil && !model.isUnchanged
        // The editor keeps what is being typed; a change elsewhere, such as squash on another row, shows the new group message.
        if window.firstResponder !== messageView { showMessage(of: list.selectedIndex) }
    }

    private func showMessage(of index: Int?) {
        messageIndex = index
        guard let index, model.steps.indices.contains(index), let commit = model.steps[index].commit else {
            messageCaption.stringValue = "Nachricht"
            setMessage("", editable: false)
            return
        }
        let head = model.groupHead(of: index)?.commit
        let editable = model.isMessageEditable(forGroupOf: index)
        let folded = model.plan.groups.first { $0.first?.commit?.id == head?.id }.map { $0.count - 1 } ?? 0
        switch (model.steps[index].action, head) {
        case (.drop, _), (_, nil):
            messageCaption.stringValue = "\(commit.shortID) wird verworfen"
        case let (_, head?) where folded > 0:
            messageCaption.stringValue = "Nachricht von \(head.shortID) mit \(folded == 1 ? "1 zusammengeführten Commit" : "\(folded) zusammengeführten Commits")\(editable ? "" : " (fixup behält sie)")"
        case let (.reword, head?):
            messageCaption.stringValue = "Neue Nachricht für \(head.shortID)"
        case let (_, head?):
            messageCaption.stringValue = "Nachricht von \(head.shortID); zum Ändern reword wählen"
        }
        setMessage(model.message(forGroupOf: index) ?? commit.message, editable: editable)
    }

    private func setMessage(_ text: String, editable: Bool) {
        if messageView.string != text { messageView.string = text }
        messageView.isEditable = editable
        messageView.textColor = editable ? Theme.ink : Theme.inkMuted
        messageView.backgroundColor = editable ? Theme.surface2 : Theme.surface1
    }

    func textDidChange(_ notification: Notification) {
        guard let messageIndex else { return }
        model.setMessage(messageView.string, forGroupOf: messageIndex)
    }

    func textDidEndEditing(_ notification: Notification) {
        showMessage(of: list.selectedIndex)
    }

    @objc private func updateRefsChanged(_ sender: NSButton) { model.setUpdateRefs(sender.state == .on) }
    @objc private func autostashChanged(_ sender: NSButton) { model.setAutostash(sender.state == .on) }

    @objc private func start() {
        guard startButton.isEnabled else { return }
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }

    @objc private func cancel() {
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }
}
