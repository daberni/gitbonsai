import AppKit

/// A way forward that a failure sheet offers, such as "Änderungen stashen und erneut versuchen". The first one is the sheet's default button.
struct FailureAction {
    let title: String
    var isDestructive = false
    let run: @MainActor () -> Void
}

/// The sheet of a failed git command: a title, one sentence of what happened, the ways forward as buttons and git's output collapsed below.
/// Without a way forward it has only "OK"; with one, "Abbrechen" closes it and the first action is the default button.
@MainActor
final class FailureSheet {
    private typealias M = Theme.Failure

    let window: SheetWindow
    let title: String
    let summary: String
    let actions: [FailureAction]
    let details: FailureDetailsView?
    /// The buttons in their order on screen: cancel or OK first, the default action last.
    private(set) var buttons: [NSControl] = []
    /// The action each button stands for; nil for cancel and OK.
    private var choices: [ObjectIdentifier: Int?] = [:]
    private var chosen: Int?

    init(title: String, summary: String, details: String?, actions: [FailureAction]) {
        self.title = title
        self.summary = summary
        self.actions = actions
        let contentWidth = M.width - 2 * M.padding
        self.details = details.map { FailureDetailsView(details: $0, width: contentWidth) }
        window = SheetWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: M.width, height: M.width)), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        window.title = title
        window.contentView = layout(contentWidth: contentWidth)
        window.onCancel = { [weak self] in self?.finish(nil) }
        window.onReturn = { [weak self] in self?.finish(self?.actions.isEmpty == false ? 0 : nil) }
        self.details?.onToggle = { [weak self] in self?.fitToContent() }
    }

    private func layout(contentWidth: CGFloat) -> NSView {
        let glyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Fehler") ?? NSImage())
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: M.glyph, weight: .regular)
        glyph.contentTintColor = Theme.ochre
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = Theme.title
        heading.textColor = Theme.ink
        heading.preferredMaxLayoutWidth = contentWidth - M.glyph - Theme.Space.s
        let header = NSStackView(views: [glyph, heading])
        header.alignment = .firstBaseline
        header.spacing = Theme.Space.s

        let sentence = NSTextField(wrappingLabelWithString: summary)
        sentence.font = Theme.body
        sentence.textColor = Theme.ink
        sentence.isSelectable = true
        sentence.preferredMaxLayoutWidth = contentWidth

        var rows: [NSView] = [header, sentence]
        if let details { rows.append(details) }
        rows.append(buttonRow(contentWidth: contentWidth))
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = M.spacing
        stack.setCustomSpacing(Theme.Space.s, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { row.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth).isActive = true }
        rows.last?.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: M.width),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: M.padding),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: M.padding),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -M.padding),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -M.padding),
        ])
        return root
    }

    /// Right-aligned like a macOS alert: cancel, the further actions, the default action last. When they do not fit in one row, they stack at full width with the default action on top, as macOS alerts do.
    private func buttonRow(contentWidth: CGFloat) -> NSView {
        var controls: [NSControl] = []
        if actions.isEmpty {
            controls.append(button(PrimaryButton(title: "OK"), choice: nil))
        } else {
            controls.append(button(SecondaryButton(title: "Abbrechen"), choice: nil))
            for (index, action) in actions.enumerated().dropFirst() {
                let control = SecondaryButton(title: action.title)
                if action.isDestructive { control.tint = Theme.persimmon }
                controls.append(button(control, choice: index))
            }
            controls.append(button(PrimaryButton(title: actions[0].title), choice: 0))
        }
        buttons = controls
        let rowWidth = controls.map(\.intrinsicContentSize.width).reduce(0, +) + CGFloat(controls.count - 1) * M.buttonGap
        guard rowWidth > contentWidth else {
            let group = NSStackView(views: controls)
            group.spacing = M.buttonGap
            return NSStackView(views: [NSView(), group])
        }
        let column = NSStackView(views: controls.reversed())
        column.orientation = .vertical
        column.spacing = M.buttonGap
        for control in controls { control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func button(_ control: NSControl, choice: Int?) -> NSControl {
        control.target = self
        control.action = #selector(pressed(_:))
        choices[ObjectIdentifier(control)] = choice
        return control
    }

    @objc private func pressed(_ sender: NSControl) {
        finish(choices[ObjectIdentifier(sender)] ?? nil)
    }

    /// Shows the sheet on `parent` and waits; the chosen action's index, or nil for cancel or OK.
    func run(on parent: NSWindow) async -> Int? {
        fitToContent()
        _ = await withCheckedContinuation { continuation in
            parent.beginSheet(window) { continuation.resume(returning: $0) }
        }
        return chosen
    }

    private func finish(_ index: Int?) {
        chosen = index
        window.sheetParent?.endSheet(window, returnCode: index == nil ? .cancel : .OK)
    }

    /// The sheet takes the height its content needs; its top edge stays where it is.
    func fitToContent() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
