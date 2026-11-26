import AppKit

/// The bar above the text for find (⌘F, ⌘G, ⇧⌘G) and go to line (⌘L); Esc or Done closes it.
final class TextViewerFindBar: BarView, NSSearchFieldDelegate, NSTextFieldDelegate {
    enum Mode { case find, goToLine }

    weak var viewer: TextViewer?
    let searchField = NSSearchField()
    let lineField = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let done = NSButton()
    private(set) var mode: Mode = .find

    init() {
        super.init(edge: .bottom)
        searchField.placeholderString = String(localized: "files.viewer.find.placeholder", defaultValue: "Find in File", bundle: .module)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("textViewer.find")
        lineField.placeholderString = String(localized: "files.viewer.goToLine.placeholder", defaultValue: "Line", bundle: .module, comment: "Placeholder of the go to line field")
        lineField.delegate = self
        lineField.target = self
        lineField.action = #selector(lineEntered(_:))
        lineField.setAccessibilityIdentifier("textViewer.goToLine")
        count.font = Theme.captionDigits
        count.textColor = Theme.inkMuted
        configure(previous, symbol: "chevron.up", toolTip: String(localized: "files.viewer.find.previous", defaultValue: "Previous Match (⇧⌘G)", bundle: .module), action: #selector(previousPressed(_:)))
        configure(next, symbol: "chevron.down", toolTip: String(localized: "files.viewer.find.next", defaultValue: "Next Match (⌘G)", bundle: .module), action: #selector(nextPressed(_:)))
        done.title = String(localized: "files.viewer.find.done", defaultValue: "Done", bundle: .module, comment: "Closes the find bar")
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.target = self
        done.action = #selector(donePressed(_:))
        let stack = NSStackView(views: [searchField, lineField, previous, next, count, NSView(), done])
        stack.orientation = .horizontal
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: Theme.TextViewer.findFieldWidth),
            lineField.widthAnchor.constraint(equalToConstant: Theme.TextViewer.lineFieldWidth),
        ])
        searchField.controlSize = .small
        lineField.controlSize = .small
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, symbol: String, toolTip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    var hasFocus: Bool {
        guard let editor = window?.firstResponder as? NSText else { return false }
        return editor.delegate === searchField || editor.delegate === lineField
    }

    func show(_ mode: Mode) {
        self.mode = mode
        let finding = mode == .find
        searchField.isHidden = !finding
        previous.isHidden = !finding
        next.isHidden = !finding
        count.isHidden = !finding
        lineField.isHidden = finding
        lineField.stringValue = ""
        window?.makeFirstResponder(finding ? searchField : lineField)
        if finding, !searchField.stringValue.isEmpty { searchAgain() }
    }

    /// The same search in a new text.
    func searchAgain() {
        guard mode == .find else { return }
        viewer?.search(searchField.stringValue)
    }

    func showCount(_ total: Int, current: Int?) {
        count.stringValue = searchField.stringValue.isEmpty ? "" : String(localized: "files.viewer.find.count", defaultValue: "\(current.map { $0 + 1 } ?? 0) of \(total)", bundle: .module, comment: "Find bar: the current match and how many there are, e.g. 3 of 12")
    }

    @objc private func searchChanged(_ sender: NSSearchField) { viewer?.search(sender.stringValue) }

    @objc private func lineEntered(_ sender: NSTextField) {
        guard let line = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)), line > 0 else {
            NSSound.beep()
            return
        }
        viewer?.hideFindBar()
        viewer?.goToLine(line - 1)
    }

    @objc private func previousPressed(_ sender: Any?) { viewer?.findNext(forward: false) }
    @objc private func nextPressed(_ sender: Any?) { viewer?.findNext(forward: true) }
    @objc private func donePressed(_ sender: Any?) { viewer?.hideFindBar() }

    /// Return finds the next match, ⇧Return the previous one, Esc closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            viewer?.hideFindBar()
            return true
        case #selector(NSResponder.insertNewline(_:)) where control === searchField:
            viewer?.findNext(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        default:
            return false
        }
    }
}
