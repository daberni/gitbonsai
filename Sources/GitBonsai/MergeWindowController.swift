import AppKit
import GitEngine

/// The merge window of one conflicted text file: ours, the result and theirs side by side over the full window width, on the same decisions as the unified view in the history pane.
/// It closes once the file is resolved, here or anywhere else.
@MainActor
final class MergeWindowController: NSWindowController, NSWindowDelegate {
    let session: ConflictSession
    let header = ConflictHeaderView(mode: .window)
    let columns = MergeColumnsView()
    /// Mark resolved: the tab writes the result and stages it.
    var onMarkResolved: (() -> Void)?
    var onClosed: (() -> Void)?
    private var observation: UUID?
    private var showsBase = false

    init(session: ConflictSession, parent: NSWindow?) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.Conflict.windowSize), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.minSize = Theme.Conflict.windowMinimumSize
        window.title = String(localized: "conflict.window.title", defaultValue: "Resolve \(session.path)", bundle: .module, comment: "Title of the merge window; the argument is the file's path")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        layout(in: window)
        if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2)) } else { window.center() }
        observation = session.observe { [weak self] in self?.update() }
        update()
        columns.scrollToTop()
        columns.select(session.current, scroll: true)
    }

    required init?(coder: NSCoder) { nil }

    private func layout(in window: NSWindow) {
        let content = FillView(color: Theme.surface0)
        header.show(path: session.path, kind: session.conflict.kind, changes: session.resolution.changes.count, mergeTool: nil)
        header.onPrevious = { [weak self] in self?.go(by: -1) }
        header.onNext = { [weak self] in self?.go(by: 1) }
        header.onMergeWords = { [weak self] in if self?.session.mergeAllWords() == false { NSSound.beep() } }
        header.onShowBase = { [weak self] shows in
            self?.showsBase = shows
            self?.update()
        }
        header.onWholeFile = { [weak self] order in self?.session.update { $0.takeInOpenConflicts(order) } }
        header.onMarkResolved = { [weak self] in self?.onMarkResolved?() }
        columns.onAction = { [weak self] change, side, take in
            guard let session = self?.session else { return }
            if take { session.take(side, at: change) } else { session.ignore(side, at: change) }
            session.current = change
        }
        for part in [header, columns] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(part)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Conflict.headerHeight),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func update() {
        columns.show(session.resolution, sides: session.sides, showsBase: showsBase)
        columns.select(session.current, scroll: false)
        header.showProgress(open: session.resolution.openConflicts)
    }

    private func go(by step: Int) {
        let target = session.current + step
        guard session.resolution.changes.indices.contains(target) else { NSSound.beep(); return }
        session.current = target
        columns.select(target, scroll: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let observation { session.stopObserving(observation) }
        observation = nil
        onClosed?()
    }
}
