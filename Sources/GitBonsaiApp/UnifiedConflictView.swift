import AppKit
import GitEngine

/// A conflicted text file in one column, for the history pane: the lines all agree on, the result of each decided change in its side's colour, and each open conflict as ours above theirs under a row of actions.
final class UnifiedConflictView: NSView {
    /// A link of an action row was clicked, such as `take/2/ours`, `merge/2` or `reopen/2`.
    var onLink: ((String) -> Void)?
    let column = MergeColumnView()
    private let scroll = NSScrollView()
    private lazy var margin = LineNumberMargin(column: column)
    private(set) var layoutModel: MergeLayout?

    init() {
        scroll.documentView = column
        super.init(frame: .zero)
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface0
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        column.onLink = { [weak self] link in self?.onLink?(link) }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        margin.install(over: scroll, in: self)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ session: ConflictSession) {
        let model = MergeLayout(unified: session.resolution, sides: session.sides, wordMerges: Set(session.wordMerges.keys))
        layoutModel = model
        column.show(model.middle)
        column.current = model.places[safe: session.current]
    }

    /// Scrolls a change into view, a third from the top.
    func reveal(_ change: Int) {
        guard let place = layoutModel?.places[safe: change] else { return }
        layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let target = MergeColumnView.y(ofRow: place.row) - clip.bounds.height / 3
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, target), max(0, column.frame.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The vertical scroll position; harness checks print it.
    var offset: CGFloat { scroll.contentView.bounds.minY }

    @objc private func scrolled(_ notification: Notification) {
        margin.needsDisplay = true
    }
}
