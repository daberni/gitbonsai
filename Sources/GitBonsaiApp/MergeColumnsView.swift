import AppKit
import GitEngine

/// Ours, the result and theirs side by side, with the actions between them. The columns scroll up and down together; each scrolls sideways on its own, as long lines need.
final class MergeColumnsView: NSView {
    typealias M = Theme.Conflict
    /// A gutter button was clicked: the change, the side and whether to take it (or ignore it).
    var onAction: ((Int, ConflictSide, Bool) -> Void)?

    let oursColumn = MergeColumnView()
    let middleColumn = MergeColumnView()
    let theirsColumn = MergeColumnView()
    let oursGutter = MergeGutterView(side: .ours)
    let theirsGutter = MergeGutterView(side: .theirs)
    private let oursCaption = NSTextField(labelWithString: "")
    private let middleCaption = NSTextField(labelWithString: "")
    private let theirsCaption = NSTextField(labelWithString: "")
    private var scrolls: [NSScrollView] = []
    private var margins: [LineNumberMargin] = []
    private var isSyncing = false
    private(set) var layoutModel: MergeLayout?

    init() {
        super.init(frame: .zero)
        let columns = [oursColumn, middleColumn, theirsColumn]
        scrolls = columns.map { column in
            let scroll = NSScrollView()
            scroll.documentView = column
            scroll.drawsBackground = true
            scroll.backgroundColor = Theme.surface0
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            return scroll
        }
        scrolls[2].hasVerticalScroller = true
        oursGutter.onAction = { [weak self] change, take in self?.onAction?(change, .ours, take) }
        theirsGutter.onAction = { [weak self] change, take in self?.onAction?(change, .theirs, take) }
        for caption in [oursCaption, middleCaption, theirsCaption] {
            caption.font = Theme.label
            caption.textColor = Theme.inkMuted
            caption.lineBreakMode = .byTruncatingTail
        }
        let parts: [NSView] = [oursCaption, middleCaption, theirsCaption, oursGutter, theirsGutter] + scrolls
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        let captionInset = M.captionInset
        NSLayoutConstraint.activate([
            scrolls[0].leadingAnchor.constraint(equalTo: leadingAnchor),
            oursGutter.leadingAnchor.constraint(equalTo: scrolls[0].trailingAnchor),
            oursGutter.widthAnchor.constraint(equalToConstant: M.gutterWidth),
            scrolls[1].leadingAnchor.constraint(equalTo: oursGutter.trailingAnchor),
            theirsGutter.leadingAnchor.constraint(equalTo: scrolls[1].trailingAnchor),
            theirsGutter.widthAnchor.constraint(equalToConstant: M.gutterWidth),
            scrolls[2].leadingAnchor.constraint(equalTo: theirsGutter.trailingAnchor),
            scrolls[2].trailingAnchor.constraint(equalTo: trailingAnchor),
            scrolls[1].widthAnchor.constraint(equalTo: scrolls[0].widthAnchor),
            scrolls[2].widthAnchor.constraint(equalTo: scrolls[0].widthAnchor),
            oursCaption.leadingAnchor.constraint(equalTo: scrolls[0].leadingAnchor, constant: captionInset),
            oursCaption.trailingAnchor.constraint(lessThanOrEqualTo: scrolls[0].trailingAnchor, constant: -captionInset),
            middleCaption.leadingAnchor.constraint(equalTo: scrolls[1].leadingAnchor, constant: captionInset),
            middleCaption.trailingAnchor.constraint(lessThanOrEqualTo: scrolls[1].trailingAnchor, constant: -captionInset),
            theirsCaption.leadingAnchor.constraint(equalTo: scrolls[2].leadingAnchor, constant: captionInset),
            theirsCaption.trailingAnchor.constraint(lessThanOrEqualTo: scrolls[2].trailingAnchor, constant: -captionInset),
        ])
        for caption in [oursCaption, middleCaption, theirsCaption] {
            caption.centerYAnchor.constraint(equalTo: topAnchor, constant: M.captionHeight / 2).isActive = true
        }
        for part in [oursGutter, theirsGutter] + scrolls {
            part.topAnchor.constraint(equalTo: topAnchor, constant: M.captionHeight).isActive = true
            part.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }
        margins = zip(columns, scrolls).map { column, scroll in
            let margin = LineNumberMargin(column: column)
            margin.install(over: scroll, in: self)
            return margin
        }
    }

    required init?(coder: NSCoder) { nil }

    func show(_ resolution: MergeResolution, sides: ConflictSides, showsBase: Bool) {
        let model = MergeLayout(resolution, showsBase: showsBase)
        layoutModel = model
        oursCaption.setText(RefString(LocalizedStringResource("conflict.side.ours", defaultValue: "Ours \(sides.ours)", bundle: .module)))
        middleCaption.attributedStringValue = Self.middleCaption(open: resolution.openConflicts, showsBase: showsBase)
        theirsCaption.setText(RefString(LocalizedStringResource("conflict.side.theirs", defaultValue: "Theirs \(sides.theirs)", bundle: .module)))
        oursColumn.show(model.ours)
        middleColumn.show(model.middle)
        theirsColumn.show(model.theirs)
        // While the base is shown, nothing can be taken into it.
        oursGutter.show(resolution, places: showsBase ? [] : model.places)
        theirsGutter.show(resolution, places: showsBase ? [] : model.places)
        oursGutter.isHidden = showsBase
        theirsGutter.isHidden = showsBase
    }

    /// "Result · 2 conflicts open", or the base while it is shown.
    private static func middleCaption(open: Int, showsBase: Bool) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted]
        guard !showsBase else { return NSAttributedString(string: String(localized: "conflict.side.base", defaultValue: "Base", bundle: .module, comment: "Caption of the middle column while it shows the common base"), attributes: attributes) }
        let caption = NSMutableAttributedString(string: String(localized: "conflict.result", defaultValue: "Result", bundle: .module, comment: "Caption of the middle column: the merge result") + " · ", attributes: attributes)
        let state = open == 0
            ? String(localized: "conflict.counterResolved", defaultValue: "All conflicts resolved", bundle: .module, comment: "Caption of the result column: no conflict is open")
            : String(localized: "conflict.counter", defaultValue: "\(open) conflicts open", bundle: .module, comment: "Caption of the result column: how many conflicts still need a decision")
        caption.append(NSAttributedString(string: state, attributes: [.font: Theme.label, .foregroundColor: open == 0 ? Theme.moss : Theme.persimmon]))
        return caption
    }

    /// The caption of the result column; harness checks print it.
    var resultCaption: String { middleCaption.stringValue }

    /// Marks a change as the current one and scrolls it into view, a third from the top.
    func select(_ change: Int, scroll scrolls: Bool) {
        guard let place = layoutModel?.places[safe: change] else { return }
        for column in [oursColumn, middleColumn, theirsColumn] { column.current = place }
        guard scrolls else { return }
        layoutSubtreeIfNeeded()
        let clip = self.scrolls[1].contentView
        let target = MergeColumnView.y(ofRow: place.row) - clip.bounds.height / 3
        scroll(toY: min(max(0, target), max(0, middleColumn.frame.height - clip.bounds.height)))
    }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        for scroll in scrolls { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        syncGutters()
    }

    /// The vertical scroll position shared by the columns; harness checks print it.
    var offset: CGFloat { scrolls[1].contentView.bounds.minY }

    private func scroll(toY y: CGFloat) {
        for scroll in scrolls {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        syncGutters()
    }

    @objc private func scrolled(_ notification: Notification) {
        guard !isSyncing, let clip = notification.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }
        let y = clip.bounds.minY
        for scroll in scrolls where scroll.contentView !== clip && abs(scroll.contentView.bounds.minY - y) > 0.5 {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        syncGutters()
    }

    private func syncGutters() {
        oursGutter.offset = offset
        theirsGutter.offset = offset
        margins.forEach { $0.needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        scrolls[1].scrollWheel(with: event)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
