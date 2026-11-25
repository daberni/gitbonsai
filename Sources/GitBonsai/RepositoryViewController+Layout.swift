import AppKit
import GitEngine

/// Places toolbar, sidebar, history, detail panel and status line.
extension RepositoryViewController {
    // MARK: Layout

    func layout() {
        let sidebarScroll = Self.scroll(sidebar, background: Theme.surface1)
        let detailScroll = Self.scroll(detail, background: Theme.surface1)
        Self.fitToContent(detail, in: detailScroll)
        // The banner of a rebase, cherry-pick or revert in progress sits above the history and takes no room while hidden.
        let historyColumn = NSStackView(views: [operationBanner.view, historyPane])
        historyColumn.orientation = .vertical
        historyColumn.spacing = 0
        for part in [operationBanner.view, historyPane] {
            part.leadingAnchor.constraint(equalTo: historyColumn.leadingAnchor).isActive = true
            part.trailingAnchor.constraint(equalTo: historyColumn.trailingAnchor).isActive = true
        }
        historyPane.setContentHuggingPriority(.defaultLow, for: .vertical)
        historyPane.show(history.view)
        // The commit form sits below the detail panel and only appears for the working directory.
        rightColumn = ColumnWithBottomBar(content: detailScroll, bar: commitUseCase.form)
        split = PanelSplitView(sidebar: sidebarScroll, history: historyColumn, detail: rightColumn)

        let statusBar = BarView(edge: .top)
        statusLabel.font = Theme.captionDigits
        statusLabel.textColor = Theme.inkMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)
        undo.button.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(undo.button)

        for subview in [toolbar, split, statusBar] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Theme.Window.toolbar),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.Window.statusBar),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: Theme.Space.m),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            undo.button.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: Theme.Space.s),
            undo.button.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -Theme.Space.m),
            undo.button.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        toast.install(in: view, above: historyPane)
    }

    /// A document view laid out with constraints grows with its content, and never gets shorter than the visible area.
    private static func fitToContent(_ document: NSView, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        document.translatesAutoresizingMaskIntoConstraints = false
        let collapse = document.heightAnchor.constraint(equalToConstant: 0)
        // Weaker than anything around it: it only shrinks the document, never the scroll view.
        collapse.priority = NSLayoutConstraint.Priority(1)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            collapse,
        ])
    }

    private static func scroll(_ document: NSView, background: NSColor) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = document
        document.autoresizingMask = [.width]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        return scrollView
    }
}
