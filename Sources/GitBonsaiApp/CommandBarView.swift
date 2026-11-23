import AppKit

/// Covers the window while the command bar is open: a click beside the panel closes it, the panel floats centred near the top.
final class CommandBarOverlay: NSView {
    let panel = CommandBarPanel()
    var onClickOutside: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: Theme.CommandBar.topOffset),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: Theme.CommandBar.width),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.Space.l),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onClickOutside?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating panel: Liquid Glass tinted with paper, the search field, the step it is in and the result list.
final class CommandBarPanel: NSView {
    private typealias C = Theme.CommandBar

    let search = TextInput()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let glass = NSGlassEffectView()
    private let stepLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: String(localized: "commandBar.list.noMatches", defaultValue: "No matching commands", bundle: .module))
    private var listHeight: NSLayoutConstraint!
    private var stepHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let content = NSView()
        glass.cornerRadius = Theme.Radius.lg
        glass.tintColor = Theme.surface1.withAlphaComponent(C.glassTint)
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        search.font = Theme.title
        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.rowHeight = C.rowHeight
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        stepLabel.font = Theme.label
        stepLabel.textColor = Theme.inkMuted
        emptyLabel.font = Theme.body
        emptyLabel.textColor = Theme.inkMuted
        emptyLabel.isHidden = true

        for view in [stepLabel, search, scroll, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: C.rowHeight)
        stepHeight = stepLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stepLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: C.padding),
            stepLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.padding + C.rowPadding),
            stepLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -C.padding),
            stepHeight,
            search.topAnchor.constraint(equalTo: stepLabel.bottomAnchor),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.padding),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -C.padding),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: C.listGap),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.listInset),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -C.listInset),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -C.listInset),
            listHeight,
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: C.padding + C.rowPadding),
        ])
    }

    /// The label above the field while a second step is open, such as "Checkout Branch…".
    func showStep(_ title: String?) {
        stepLabel.attributedStringValue = NSAttributedString(string: title?.uppercased() ?? "", attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        stepHeight.constant = title == nil ? 0 : C.stepHeight
    }

    /// Sizes the list to its rows, up to the visible maximum; an empty list keeps one row for "No matching commands".
    func showRows(_ count: Int) {
        listHeight.constant = CGFloat(max(min(count, C.maxVisibleRows), 1)) * C.rowHeight
        emptyLabel.isHidden = count > 0
    }
}
