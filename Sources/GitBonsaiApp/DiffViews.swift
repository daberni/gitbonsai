import AppKit
import GitEngine

/// The bar above a file diff: the way back to the graph, the file, its counts, hunk navigation and the file-wide action.
final class DiffHeaderView: BarView {
    var onBack: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onFileAction: (() -> Void)?

    private let back = NSButton()
    private let title = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private let stat = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let fileAction = NSButton()

    init() {
        super.init(edge: .bottom)
        back.title = "Graph"
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.imagePosition = .imageLeading
        back.bezelStyle = .rounded
        back.target = self
        back.action = #selector(goBack(_:))
        back.keyEquivalent = "\u{1b}"
        title.lineBreakMode = .byTruncatingHead
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, symbol, action, tip) in [(previous, "chevron.up", #selector(goPrevious(_:)), "Vorheriger Hunk"), (next, "chevron.down", #selector(goNext(_:)), "Nächster Hunk")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        fileAction.bezelStyle = .rounded
        fileAction.target = self
        fileAction.action = #selector(runFileAction(_:))

        let leading = NSStackView(views: [back, title, badge, stat])
        leading.spacing = Theme.Space.m
        let trailing = NSStackView(views: [previous, next, fileAction])
        trailing.spacing = Theme.Space.s
        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Theme.Space.m),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ selection: FileSelection, diff: FileDiff?) {
        let text = NSMutableAttributedString(string: selection.directory, attributes: [.font: Theme.body, .foregroundColor: Theme.inkMuted])
        text.append(NSAttributedString(string: selection.name, attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.ink]))
        title.attributedStringValue = text
        title.toolTip = selection.path
        switch selection.source {
        case .commit: badge.text = nil
        case .unstaged: badge.text = "unstaged"
        case .staged: badge.text = "staged"
        case .untracked: badge.text = "untracked"
        }
        stat.attributedStringValue = diff.map { FileRowView.statText($0.stat) } ?? NSAttributedString()
        let hasHunks = (diff?.hunks.count ?? 0) > 1
        previous.isHidden = !hasHunks
        next.isHidden = !hasHunks
        fileAction.isHidden = !(selection.isStageable || selection.isUnstageable) || diff == nil
        fileAction.title = selection.isUnstageable ? "Datei unstagen" : "Datei stagen"
    }

    @objc private func goBack(_ sender: Any?) { onBack?() }
    @objc private func goPrevious(_ sender: Any?) { onPrevious?() }
    @objc private func goNext(_ sender: Any?) { onNext?() }
    @objc private func runFileAction(_ sender: Any?) { onFileAction?() }
}

/// A small capsule with a word in it, for "unstaged" and the like.
final class BadgeView: NSView {
    var text: String? { didSet { isHidden = text == nil; invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var attributed: NSAttributedString { NSAttributedString(string: text ?? "", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted]) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: attributed.size().width + 2 * Theme.Diff.badgePadding, height: Theme.Diff.badgeHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.surface2.setFill()
        path.fill()
        Theme.hairline.setStroke()
        path.stroke()
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// One line of a diff: old and new line number, the sign, the text. Added and removed lines are tinted.
final class DiffLineView: NSView {
    var line: DiffLine? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let line else { return }
        typealias D = Theme.Diff
        let tint: NSColor? = switch line.kind {
        case .added: Theme.moss
        case .removed: Theme.persimmon
        case .context: nil
        }
        let numbers = CGRect(x: 0, y: 0, width: 2 * D.numberColumn, height: bounds.height)
        if let tint {
            tint.withAlphaComponent(D.lineTint).setFill()
            bounds.fill()
            tint.withAlphaComponent(D.numberTint).setFill()
            numbers.fill()
        } else {
            Theme.surface1.setFill()
            numbers.fill()
        }
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: Theme.inkFaint]
        func number(_ value: Int?, columnEnd: CGFloat) {
            guard let value else { return }
            let text = NSAttributedString(string: "\(value)", attributes: numberAttributes)
            text.draw(at: CGPoint(x: columnEnd - D.textInset - text.size().width, y: bounds.midY - text.size().height / 2))
        }
        number(line.oldNumber, columnEnd: D.numberColumn)
        number(line.newNumber, columnEnd: 2 * D.numberColumn)
        let sign = switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
        let signText = NSAttributedString(string: sign, attributes: [.font: Theme.mono, .foregroundColor: tint ?? Theme.inkMuted])
        signText.draw(at: CGPoint(x: numbers.maxX + D.textInset, y: bounds.midY - signText.size().height / 2))
        let body = NSMutableAttributedString(string: Self.display(line.text), attributes: [.font: Theme.mono, .foregroundColor: Theme.ink])
        if line.missingNewline { body.append(NSAttributedString(string: "  ⏎ fehlt am Dateiende", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkFaint])) }
        body.draw(at: CGPoint(x: Self.textX, y: bounds.midY - body.size().height / 2))
    }

    static var textX: CGFloat { 2 * Theme.Diff.numberColumn + Theme.Diff.textInset + Theme.Diff.signColumn }

    /// Tabs as spaces, so columns line up as in an editor.
    static func display(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: Theme.Diff.tabWidth))
    }
}

/// The header of one hunk: its range and section, and the actions for this hunk alone.
final class DiffHunkView: NSView {
    var onAction: (() -> Void)?
    var onDiscard: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let action = NSButton()
    let discard = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Theme.mono
        label.textColor = Theme.inkMuted
        label.lineBreakMode = .byTruncatingTail
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.target = self
        action.action = #selector(run(_:))
        discard.bezelStyle = .rounded
        discard.controlSize = .small
        discard.title = "Hunk verwerfen"
        discard.target = self
        discard.action = #selector(runDiscard(_:))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(discard)
        addSubview(action)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DiffLineView.textX - Theme.Diff.signColumn),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.Diff.hunkLabelWidth),
        ])
    }

    /// The buttons keep to the right edge of what is visible, also while long lines scroll the diff sideways; discarding sits left of staging.
    override func layout() {
        super.layout()
        action.sizeToFit()
        discard.sizeToFit()
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        action.setFrameOrigin(NSPoint(x: visible.maxX - Theme.Space.m - action.frame.width, y: (bounds.height - action.frame.height) / 2))
        discard.setFrameOrigin(NSPoint(x: action.frame.minX - Theme.Space.s - discard.frame.width, y: (bounds.height - discard.frame.height) / 2))
    }

    required init?(coder: NSCoder) { nil }

    func show(_ hunk: DiffHunk, actionTitle: String?, canDiscard: Bool) {
        label.stringValue = hunk.header
        action.title = actionTitle ?? ""
        action.isHidden = actionTitle == nil
        discard.isHidden = !canDiscard
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Stroke.hairline).fill()
        NSRect(x: 0, y: bounds.height - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
    }

    @objc private func run(_ sender: Any?) { onAction?() }
    @objc private func runDiscard(_ sender: Any?) { onDiscard?() }
}
