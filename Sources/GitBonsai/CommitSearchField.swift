import AppKit

/// The toolbar's commit search: reports each change of the text, ⏎ and ⇧⏎ as steps, Esc as clearing, and shows the match counter inside the field in front of its clear button.
final class CommitSearchField: NSSearchField, NSSearchFieldDelegate {
    /// The text changed; empty after Esc or the clear button.
    var onChange: ((String) -> Void)?
    /// ⏎ steps forward, ⇧⏎ backward.
    var onStep: ((_ forward: Bool) -> Void)?

    private let counter = NSTextField(labelWithString: "")

    override class var cellClass: AnyClass? {
        get { CounterCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholderString = String(localized: "history.search.title", defaultValue: "Search Commits", bundle: .module)
        controlSize = .large
        sendsWholeSearchString = true
        delegate = self
        target = self
        action = #selector(committed(_:))
        counter.font = Theme.captionDigits
        counter.textColor = Theme.inkMuted
        counter.isHidden = true
        addSubview(counter)
    }

    required init?(coder: NSCoder) { nil }

    /// The counter text, such as "3 of 42" or "No matches"; nil hides it.
    var counterText: String? {
        get { counter.isHidden ? nil : counter.stringValue }
        set {
            counter.stringValue = newValue ?? ""
            counter.isHidden = newValue == nil
            (cell as? CounterCell)?.reservedWidth = newValue == nil ? 0 : counter.intrinsicContentSize.width + Theme.Search.counterGap
            needsLayout = true
            // The field editor takes its frame from the cell only when editing restarts, so a running edit is resized directly.
            if let editor = currentEditor(), let cell = cell as? NSSearchFieldCell { editor.frame = cell.searchTextRect(forBounds: bounds) }
        }
    }

    override func layout() {
        super.layout()
        guard let cell = cell as? NSSearchFieldCell else { return }
        let size = counter.intrinsicContentSize
        let cancel = cell.cancelButtonRect(forBounds: bounds)
        counter.frame = CGRect(x: cancel.minX - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(!backward)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            stringValue = ""
            onChange?("")
            return true
        default:
            return false
        }
    }

    /// The clear button sends the action with the emptied text.
    @objc private func committed(_ sender: Any?) {
        if stringValue.isEmpty { onChange?("") }
    }

    /// Keeps typed text clear of the counter.
    private final class CounterCell: NSSearchFieldCell {
        var reservedWidth: CGFloat = 0

        override func searchTextRect(forBounds rect: NSRect) -> NSRect {
            var result = super.searchTextRect(forBounds: rect)
            result.size.width = max(result.width - reservedWidth, 0)
            return result
        }
    }
}
