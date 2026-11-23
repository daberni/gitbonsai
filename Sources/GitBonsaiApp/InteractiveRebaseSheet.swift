import AppKit
import GitEngine

/// The interactive rebase sheet: "from <old base> to <target>" at the top, the steps newest on top and the resulting history side by side on one grid, the message of the selected step
/// below both, hints and options at the bottom. Sizes come from `Theme.InteractiveRebase` and hold through Auto Layout at any size between the sheet's limits. It returns the plan to run, or nil when cancelled.
@MainActor
final class InteractiveRebaseSheet: NSObject, NSTextViewDelegate {
    private typealias M = Theme.InteractiveRebase

    let model: InteractiveRebaseModel
    let window: NSWindow
    let list: RebaseStepList
    let preview = RebasePreviewView()
    let basePicker: RebaseBasePicker
    let messageView: NSTextView
    private let messageScroll: NSScrollView
    private let messageCaption = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let problem = NSTextField(labelWithString: "")
    /// Published commits are only mentioned, quietly: the push asks before `--force-with-lease`.
    private let hint = NSTextField(labelWithString: "")
    private(set) var updateRefsBox: NSButton?
    private(set) var autostashBox: NSButton?
    let startButton = NSButton(title: String(localized: "rebase.sheet.start", defaultValue: "Start Rebase", bundle: .module), target: nil, action: nil)
    let cancelButton = NSButton(title: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module), target: nil, action: nil)
    /// The step whose message the editor shows.
    private var messageIndex: Int?
    /// Says whether the commits above HEAD would be published, for the current old base.
    var publishedHint: (Int) -> RefString? = { _ in nil }

    init(model: InteractiveRebaseModel, basePicker: RebaseBasePicker) {
        self.model = model
        self.basePicker = basePicker
        list = RebaseStepList(model: model)
        messageScroll = NSTextView.scrollableTextView()
        messageView = messageScroll.documentView as! NSTextView
        window = NSWindow(contentRect: NSRect(origin: .zero, size: M.size), styleMask: [.titled, .resizable, .docModalWindow], backing: .buffered, defer: false)
        super.init()
        window.contentMinSize = M.minimumSize
        window.contentMaxSize = M.maximumSize
        window.title = String(localized: "rebase.sheet.title", defaultValue: "Interactive Rebase", bundle: .module)
        window.contentView = FillView(color: Theme.surface0)
        build()
        model.onChange = { [weak self] in self?.modelChanged() }
        model.onReload = { [weak self] in self?.reload() }
        list.onSelect = { [weak self] index in self?.showMessage(of: index) }
        reload()
    }

    /// Shows the sheet on `parent` and waits for the answer.
    func run(on parent: NSWindow) async -> RebasePlan? {
        window.initialFirstResponder = list.table
        if let base = ScreenshotHarness.ontoBase { Task { await basePicker.type(base) } }
        let response = await withCheckedContinuation { continuation in
            parent.beginSheet(window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? model.plan : nil
    }

    // MARK: Layout

    private func build() {
        let title = NSTextField(labelWithString: "")
        title.font = Theme.title
        title.textColor = Theme.ink
        title.setText(LocalizedStringResource("rebase.sheet.heading", defaultValue: "Rebase \(RefName.branch(model.branch)) interactively", bundle: .module))
        let keys = NSTextField(labelWithString: String(localized: "rebase.sheet.hint", defaultValue: "Newest on top · drag or ⌥↑ ⌥↓ to move, p r e s f d to choose the action · column edges can be dragged", bundle: .module))
        keys.font = Theme.caption
        keys.textColor = Theme.inkMuted
        keys.lineBreakMode = .byTruncatingTail
        keys.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let listFrame = HairlineFrameView(content: list.scrollView)
        let caption = CaptionBarView()
        caption.title = String(localized: "rebase.sheet.resultCaption", defaultValue: "Result, newest on top", bundle: .module, comment: "Caption above the preview of the history after the rebase.")
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = Theme.surface2
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewStack = NSStackView(views: [caption, previewScroll])
        previewStack.orientation = .vertical
        previewStack.spacing = 0
        let previewFrame = HairlineFrameView(content: previewStack)

        messageCaption.font = Theme.caption
        messageCaption.textColor = Theme.inkMuted
        messageCaption.lineBreakMode = .byTruncatingTail
        messageCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageScroll.borderType = .lineBorder
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageView.font = Theme.body
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.textContainerInset = NSSize(width: Theme.Space.xs, height: Theme.Space.xs)
        messageView.delegate = self
        messageView.setAccessibilityLabel(String(localized: "rebase.sheet.messageAccessibility", defaultValue: "Commit message", bundle: .module))

        // Every note keeps one line, so nothing moves when one appears or changes.
        for label in [summary, problem, hint] {
            label.font = Theme.caption
            label.textColor = Theme.inkMuted
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        var options: [NSView] = []
        do {
            // Always there, disabled without stacked branches, so another base never changes the layout.
            let box = NSButton(checkboxWithTitle: String(localized: "rebase.sheet.updateRefs", defaultValue: "Move dependent branches along (--update-refs)", bundle: .module), target: self, action: #selector(updateRefsChanged(_:)))
            box.toolTip = String(localized: "rebase.sheet.updateRefsToolTip", defaultValue: "Branches that point to commits in the range move with their commits", bundle: .module)
            updateRefsBox = box
            options.append(box)
        }
        if model.hasLocalChanges {
            let box = NSButton(checkboxWithTitle: String(localized: "rebase.sheet.autostash", defaultValue: "Stash local changes before and restore them afterwards (--autostash)", bundle: .module), target: self, action: #selector(autostashChanged(_:)))
            autostashBox = box
            options.append(box)
        }
        let notes = NSStackView(views: [summary, problem, hint] + options)
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = Theme.Space.xs
        notes.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.spacing = Theme.Space.s

        let root = window.contentView!
        let parts: [NSView] = [title, basePicker.view, keys, listFrame, previewFrame, messageCaption, messageScroll, notes, buttons]
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(part)
        }
        let previewWidth = previewFrame.widthAnchor.constraint(equalToConstant: M.previewWidth)
        previewWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: M.inset),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M.inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -M.inset),
            basePicker.view.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Theme.Space.s),
            basePicker.view.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            basePicker.view.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -M.inset),
            keys.topAnchor.constraint(equalTo: basePicker.view.bottomAnchor, constant: Theme.Space.s),
            keys.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            keys.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -M.inset),

            // List and preview: the same top and bottom edges.
            listFrame.topAnchor.constraint(equalTo: keys.bottomAnchor, constant: M.spacing),
            listFrame.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            listFrame.widthAnchor.constraint(greaterThanOrEqualToConstant: M.minimumListWidth),
            listFrame.heightAnchor.constraint(greaterThanOrEqualToConstant: M.headerHeight + M.minimumVisibleRows * M.rowHeight + 2 * Theme.Stroke.hairline),
            previewFrame.topAnchor.constraint(equalTo: listFrame.topAnchor),
            previewFrame.bottomAnchor.constraint(equalTo: listFrame.bottomAnchor),
            previewFrame.leadingAnchor.constraint(equalTo: listFrame.trailingAnchor, constant: M.spacing),
            previewFrame.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M.inset),
            previewFrame.widthAnchor.constraint(greaterThanOrEqualToConstant: M.minimumPreviewWidth),
            previewWidth,
            caption.heightAnchor.constraint(equalToConstant: M.headerHeight),
            preview.topAnchor.constraint(equalTo: previewScroll.contentView.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewScroll.contentView.leadingAnchor),
            preview.widthAnchor.constraint(equalTo: previewScroll.contentView.widthAnchor),

            // The editor spans both and keeps its height; long messages scroll inside it.
            messageCaption.topAnchor.constraint(equalTo: listFrame.bottomAnchor, constant: M.spacing),
            messageCaption.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            messageCaption.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -M.inset),
            messageScroll.topAnchor.constraint(equalTo: messageCaption.bottomAnchor, constant: Theme.Space.xs),
            messageScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            messageScroll.heightAnchor.constraint(equalToConstant: M.messageHeight),

            notes.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: M.spacing),
            notes.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            notes.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -M.spacing),
            notes.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -M.inset),
            buttons.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: notes.bottomAnchor),
        ])
        updateRefsBox?.state = model.plan.updateRefs ? .on : .off
        autostashBox?.state = model.plan.autostash ? .on : .off
    }

    // MARK: Updates

    /// A new range: new rows, the first one selected.
    private func reload() {
        list.table.reloadData()
        list.applyColumns()
        list.selectNewest()
        let merges = model.range.flattenedMerges
        let flattened = merges == 0 ? nil : String(localized: "rebase.sheet.mergesFlattened", defaultValue: "\(merges) merges in the range are flattened, as git rebase does without --rebase-merges", bundle: .module)
        // Two independent hints, each a complete sentence.
        let hintText = RefString(marked: [publishedHint(model.published)?.marked, flattened].compactMap { $0 }.joined(separator: " · "))
        hint.setText(hintText)
        hint.toolTip = hintText.plain
        updateRefsBox?.isEnabled = !model.plan.branches.isEmpty
        updateRefsBox?.state = model.plan.updateRefs ? .on : .off
        modelChanged()
    }

    private func modelChanged() {
        list.refresh()
        preview.show(model)
        summary.setText(model.isUnchanged && !model.plan.movesBase ? RefString(LocalizedStringResource("rebase.sheet.nothingChanged", defaultValue: "Nothing changed", bundle: .module)) : model.summary)
        let problemText = model.problemText ?? (model.plan.dropsEverything ? RefString(LocalizedStringResource("rebase.sheet.allDropped", defaultValue: "All commits dropped: \(RefName.branch(model.branch)) will be reset to \(RefName.commit(model.targetCommit.id)).", bundle: .module)) : nil)
        problem.textColor = model.plan.problem == nil ? Theme.ochre : Theme.persimmon
        problem.setText(problemText ?? RefString(verbatim: " "))
        problem.toolTip = problemText?.plain
        startButton.isEnabled = model.canStart
        // The editor keeps what is being typed; a change elsewhere, such as squash on another row, shows the new group message.
        if window.firstResponder !== messageView { showMessage(of: list.selectedIndex) }
    }

    private func showMessage(of index: Int?) {
        messageIndex = index
        guard let index, model.steps.indices.contains(index), let commit = model.steps[index].commit else {
            messageCaption.stringValue = String(localized: "rebase.sheet.message", defaultValue: "Message", bundle: .module, comment: "Caption above the commit message editor; also a column header.")
            setMessage("", editable: false)
            return
        }
        let head = model.groupHead(of: index)?.commit
        let editable = model.isMessageEditable(forGroupOf: index)
        let folded = model.plan.groups.first { $0.first?.commit?.id == head?.id }.map { $0.count - 1 } ?? 0
        switch (model.steps[index].action, head) {
        case (.drop, _), (_, nil):
            messageCaption.setText(LocalizedStringResource("rebase.sheet.messageDropped", defaultValue: "\(RefName.commit(commit.id)) is dropped", bundle: .module))
        case let (_, head?) where folded > 0 && editable:
            messageCaption.setText(LocalizedStringResource("rebase.sheet.messageCombined", defaultValue: "Message of \(RefName.commit(head.id)) with \(folded) combined commits", bundle: .module))
        case let (_, head?) where folded > 0:
            messageCaption.setText(LocalizedStringResource("rebase.sheet.messageCombinedFixup", defaultValue: "Message of \(RefName.commit(head.id)) with \(folded) combined commits (fixup keeps it)", bundle: .module))
        case let (.reword, head?):
            messageCaption.setText(LocalizedStringResource("rebase.sheet.messageNew", defaultValue: "New message for \(RefName.commit(head.id))", bundle: .module))
        case let (_, head?):
            messageCaption.setText(LocalizedStringResource("rebase.sheet.messageKept", defaultValue: "Message of \(RefName.commit(head.id)); choose reword to change it", bundle: .module))
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

/// A hairline frame around one view, drawn outside the view so the content never covers it.
final class HairlineFrameView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let line = Theme.Stroke.hairline
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: line),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -line),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: line),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -line),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2))
        path.lineWidth = Theme.Stroke.hairline
        path.stroke()
    }
}
