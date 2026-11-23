import AppKit
import GitEngine

/// The bar above the conflict view: the file and the kind of conflict, the navigation between changes, the word merge of simple conflicts, the base in place of the result, the choices for every open conflict, "Resolve…", "Mark resolved" and the close button (also Esc), which leads back to the graph.
/// In the history pane it counts the open conflicts and leads to the merge window or the chosen merge tool; the merge window has the word merge, the base and the choice for open conflicts, and closes like any window.
final class ConflictHeaderView: BarView {
    enum Mode { case pane, window }

    let mode: Mode
    var onBack: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    /// The sides to take into every open conflict, in order.
    var onWholeFile: (([ConflictSide]) -> Void)?
    var onMergeWords: (() -> Void)?
    var onShowBase: ((Bool) -> Void)?
    /// "Resolve…": the merge window, or the merge tool chosen in the settings.
    var onResolve: (() -> Void)?
    var onMarkResolved: (() -> Void)?

    private let indicator = NSTextField(labelWithString: "U")
    private let title = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    let previous = NSButton()
    let next = NSButton()
    let counter = NSTextField(labelWithString: "")
    let resolve = NSButton()
    let mergeWords = NSButton()
    let showBase = NSButton()
    let wholeFile = NSPopUpButton(frame: .zero, pullsDown: true)
    let markResolved = PrimaryButton(title: String(localized: "conflict.markResolved", defaultValue: "Mark resolved", bundle: .module, comment: "Button that writes the result of a conflicted file and stages it"))
    let close = NSButton()
    private let leading = NSStackView()
    private let trailing = NSStackView()
    /// The elements `show` made visible that give way when the bar is too narrow; nothing is squeezed.
    private var optional: [NSView] { [badge, counter] }
    private var wanted: Set<ObjectIdentifier> = []
    private var isFitting = false
    private var fittedSignature = ""

    init(mode: Mode) {
        self.mode = mode
        super.init(edge: .bottom)
        counter.font = Theme.captionDigits
        counter.lineBreakMode = .byTruncatingTail
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        resolve.title = String(localized: "conflict.resolve.title", defaultValue: "Resolve…", bundle: .module, comment: "Button that opens the conflicted file in the merge window or in the merge tool chosen in the settings")
        resolve.imagePosition = .imageLeading
        resolve.bezelStyle = .rounded
        resolve.target = self
        resolve.action = #selector(runResolve(_:))
        showResolveTool(nil)
        indicator.font = Theme.monoStrong
        indicator.textColor = Theme.persimmon
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.usesSingleLineMode = true
        title.cell?.wraps = false
        title.lineBreakMode = .byTruncatingHead
        // The file name truncates once the optional elements are gone; buttons never shrink.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let arrows = [
            (previous, "chevron.up", NSUpArrowFunctionKey, #selector(goPrevious(_:)), String(localized: "conflict.previous", defaultValue: "Previous change (⌥⌘↑)", bundle: .module, comment: "Tooltip of the button that moves to the previous change of the merge")),
            (next, "chevron.down", NSDownArrowFunctionKey, #selector(goNext(_:)), String(localized: "conflict.next", defaultValue: "Next change (⌥⌘↓)", bundle: .module, comment: "Tooltip of the button that moves to the next change of the merge")),
        ]
        for (button, symbol, key, action, tip) in arrows {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.toolTip = tip
            button.keyEquivalent = String(Character(UnicodeScalar(UInt16(key))!))
            button.keyEquivalentModifierMask = [.command, .option]
        }
        configureWholeFile()
        mergeWords.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        mergeWords.imagePosition = .imageOnly
        mergeWords.setAccessibilityLabel(String(localized: "conflict.mergeWords", defaultValue: "Merge simple conflicts", bundle: .module, comment: "Button that merges conflicts word by word where both sides changed different words of the same lines"))
        mergeWords.bezelStyle = .rounded
        mergeWords.toolTip = String(localized: "conflict.mergeWordsToolTip", defaultValue: "Merge simple conflicts: combines changes of both sides to different words of the same lines", bundle: .module, comment: "Tooltip of the wand button that merges conflicts word by word")
        mergeWords.target = self
        mergeWords.action = #selector(runMergeWords(_:))
        showBase.setButtonType(.pushOnPushOff)
        showBase.title = String(localized: "conflict.showBase", defaultValue: "Show base", bundle: .module, comment: "Toggle that shows the common base in the middle column instead of the result")
        showBase.bezelStyle = .rounded
        showBase.toolTip = String(localized: "conflict.showBaseToolTip", defaultValue: "Show the common base in place of the result", bundle: .module, comment: "Tooltip of the Base toggle")
        showBase.target = self
        showBase.action = #selector(toggleBase(_:))
        markResolved.target = self
        markResolved.action = #selector(runMarkResolved(_:))
        let closeSymbol = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "diff.toolbar.close", defaultValue: "Close", bundle: .module))?.withSymbolConfiguration(closeSymbol)
        close.bezelStyle = .rounded
        close.toolTip = String(localized: "diff.toolbar.closeToolTip", defaultValue: "Close (Esc)", bundle: .module)
        close.target = self
        close.action = #selector(goBack(_:))
        close.keyEquivalent = "\u{1b}"

        leading.setViews([indicator, title, badge], in: .leading)
        leading.spacing = Theme.Space.m
        leading.setCustomSpacing(Theme.Space.s, after: indicator)
        trailing.setViews([counter, previous, next, resolve, mergeWords, showBase, wholeFile, markResolved, close], in: .leading)
        trailing.spacing = Theme.Space.s
        trailing.setCustomSpacing(Theme.Space.m, after: next)
        trailing.setCustomSpacing(Theme.Space.m, after: markResolved)
        for stack in [leading, trailing] {
            // Hidden elements take no room, so the bar can tell what fits.
            stack.detachesHiddenViews = true
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

    private func configureWholeFile() {
        wholeFile.bezelStyle = .rounded
        let face = NSMenuItem(title: String(localized: "conflict.wholeFile", defaultValue: "Open conflicts", bundle: .module, comment: "Pull-down that resolves every open conflict of the file the same way"), action: nil, keyEquivalent: "")
        wholeFile.menu?.addItem(face)
        let choices: [(String, [ConflictSide])] = [
            (String(localized: "conflict.choice.ours", defaultValue: "Ours", bundle: .module, comment: "Resolve the open conflicts with our side"), [.ours]),
            (String(localized: "conflict.choice.theirs", defaultValue: "Theirs", bundle: .module, comment: "Resolve the open conflicts with their side"), [.theirs]),
            (String(localized: "conflict.choice.oursThenTheirs", defaultValue: "Ours, then Theirs", bundle: .module, comment: "Resolve the open conflicts with both sides, ours first"), [.ours, .theirs]),
            (String(localized: "conflict.choice.theirsThenOurs", defaultValue: "Theirs, then Ours", bundle: .module, comment: "Resolve the open conflicts with both sides, theirs first"), [.theirs, .ours]),
        ]
        for (title, order) in choices {
            let item = NSMenuItem(title: title, action: #selector(chooseWholeFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order
            wholeFile.menu?.addItem(item)
        }
    }

    /// The file and its kind; `changes` is nil for a conflict without lines to merge, which has no merge window: "Resolve…" shows there only for a merge tool.
    /// `mergeTool` is the tool "Resolve…" opens instead of the merge window.
    func show(path: String, kind: ConflictKind, changes: Int?, mergeTool: String?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let name = (path as NSString).lastPathComponent
        let text = NSMutableAttributedString(string: String(path.dropLast(name.count)), attributes: [.font: Theme.body, .foregroundColor: Theme.inkMuted, .paragraphStyle: paragraph])
        text.append(NSAttributedString(string: name, attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.ink, .paragraphStyle: paragraph]))
        title.attributedStringValue = text
        title.toolTip = path
        badge.text = ConflictSides.word(for: kind)
        let isText = changes != nil
        let inWindow = mode == .window
        previous.isHidden = (changes ?? 0) < 2
        next.isHidden = previous.isHidden
        counter.isHidden = !isText || inWindow
        self.isText = isText
        for control in [mergeWords, showBase, wholeFile] as [NSView] { control.isHidden = !isText || !inWindow }
        markResolved.isHidden = !isText
        close.isHidden = inWindow
        wanted = Set(optional.filter { !$0.isHidden }.map(ObjectIdentifier.init))
        showBase.state = .off
        showResolveTool(mergeTool)
    }

    private var isText = true

    /// What "Resolve…" opens, also when the setting changes while the file is shown.
    func showResolveTool(_ mergeTool: String?) {
        resolve.isHidden = mode == .window || (!isText && mergeTool == nil)
        let tip: String
        if let mergeTool {
            tip = String(localized: "conflict.resolve.mergeToolToolTip", defaultValue: "Open in \(mergeTool)", bundle: .module, comment: "Tooltip of Resolve… when it opens the merge tool chosen in the settings; the argument is git's name of the tool")
        } else {
            tip = String(localized: "conflict.resolve.windowToolTip", defaultValue: "Resolve side by side in the merge window", bundle: .module, comment: "Tooltip of Resolve… when it opens the app's merge window")
        }
        resolve.toolTip = tip
        resolve.image = NSImage(systemSymbolName: mergeTool == nil ? "rectangle.split.3x1" : "arrow.up.forward.app", accessibilityDescription: tip)
        fittedSignature = ""
        needsLayout = true
    }

    /// Mark resolved waits until no conflict is open; the word merge and the choice for open conflicts act on the open ones.
    func showProgress(open: Int) {
        counter.stringValue = open == 0
            ? String(localized: "conflict.counterResolved", defaultValue: "All conflicts resolved", bundle: .module, comment: "Caption of the result column: no conflict is open")
            : String(localized: "conflict.counter", defaultValue: "\(open) conflicts open", bundle: .module, comment: "Caption of the result column: how many conflicts still need a decision")
        counter.textColor = open == 0 ? Theme.moss : Theme.persimmon
        needsLayout = true
        markResolved.isEnabled = open == 0 && showBase.state == .off
        markResolved.toolTip = open == 0 ? nil : String(localized: "conflict.markResolvedWaiting", defaultValue: "Decide every conflict first", bundle: .module, comment: "Tooltip of the disabled Mark resolved button")
        mergeWords.isEnabled = open > 0
        wholeFile.isEnabled = open > 0
    }

    override func layout() {
        super.layout()
        fitToWidth()
    }

    /// Shows every wanted element that fits at its full size: first the badge goes, then "Resolve…" keeps only its icon, then the counter goes.
    /// The widths are measured first and only elements whose visibility changes are touched, so the layout this triggers settles at once.
    private func fitToWidth() {
        let signature = "\(bounds.width)|\(wanted.count)|\(counter.stringValue)|\(title.stringValue)"
        guard !isFitting, bounds.width > 0, signature != fittedSignature else { return }
        isFitting = true
        defer { isFitting = false }
        fittedSignature = signature
        let small = Theme.Space.s
        let wide = Theme.Space.m
        func width(_ view: NSView) -> CGFloat { view.fittingSize.width }
        // The file name needs room for at least its last part.
        let fixedLeading = width(indicator) + small + min(width(title), Theme.Conflict.minimumTitle)
        let buttons: [NSView] = [previous, next, mergeWords, showBase, wholeFile, markResolved, close]
        let alwaysTrailing = buttons.filter { !$0.isHidden }
        let titleWidth = resolve.attributedTitle.size().width + small
        let resolveWidth = resolve.isHidden ? 0 : width(resolve) + (resolve.imagePosition == .imageOnly ? titleWidth : 0)
        let available = bounds.width - 3 * wide
        func needed(_ visible: [NSView], compact: Bool) -> CGFloat {
            let trailingViews: [NSView] = alwaysTrailing + visible.filter { $0 !== badge }
            let badgeWidth: CGFloat = visible.contains(badge) ? wide + width(badge) : 0
            let viewsWidth: CGFloat = trailingViews.reduce(0) { $0 + width($1) }
            let gaps: CGFloat = CGFloat(trailingViews.count + 1) * small + 2 * wide
            let resolveExtra: CGFloat = resolveWidth - (compact ? titleWidth : 0)
            return fixedLeading + badgeWidth + viewsWidth + gaps + resolveExtra
        }
        // The badge goes first, then the button keeps only its icon, then the counter.
        var visible = optional.filter { wanted.contains(ObjectIdentifier($0)) }
        var compact = false
        if needed(visible, compact: compact) > available { visible.removeAll { $0 === badge } }
        if needed(visible, compact: compact) > available { compact = !resolve.isHidden }
        while !visible.isEmpty, needed(visible, compact: compact) > available { visible.removeFirst() }
        for view in optional {
            let hidden = !visible.contains(view)
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        let position: NSControl.ImagePosition = compact ? .imageOnly : .imageLeading
        if resolve.imagePosition != position { resolve.imagePosition = position }
    }

    /// The path, the kind, the counter and the state of Mark resolved; harness checks print them.
    var summary: String {
        "\(title.stringValue) [\(badge.isHidden ? "-" : badge.text ?? "")] \(counter.isHidden ? "-" : counter.stringValue) resolve=\(resolve.isHidden ? "hidden" : resolve.imagePosition == .imageOnly ? "icon" : "full")(\(resolve.toolTip ?? "")) markResolved=\(markResolved.isHidden ? "hidden" : markResolved.isEnabled ? "enabled" : "disabled")"
    }

    @objc private func goBack(_ sender: Any?) { onBack?() }
    @objc private func goPrevious(_ sender: Any?) { onPrevious?() }
    @objc private func goNext(_ sender: Any?) { onNext?() }
    @objc private func runMarkResolved(_ sender: Any?) { onMarkResolved?() }
    @objc private func runMergeWords(_ sender: Any?) { onMergeWords?() }
    @objc private func runResolve(_ sender: Any?) { onResolve?() }
    @objc private func toggleBase(_ sender: Any?) { onShowBase?(showBase.state == .on) }
    @objc private func chooseWholeFile(_ sender: NSMenuItem) {
        guard let order = sender.representedObject as? [ConflictSide] else { return }
        onWholeFile?(order)
    }
}
