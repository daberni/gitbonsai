import AppKit

/// The pointer's place over one list, kept current while the list scrolls under a still pointer.
/// Tracking areas only report pointer moves; when content scrolls, the item under the pointer changes without one, so the hover is recomputed from the pointer's screen position on every bounds change of the enclosing clip view.
@MainActor
final class ListHover: NSResponder {
    /// The pointer in the list's coordinates, nil once it left the list's visible part.
    private(set) var point: NSPoint?
    /// Called whenever `point` may have changed, including on scrolls.
    var onChange: ((NSPoint?) -> Void)?
    private weak var view: NSView?
    private weak var observedClip: NSClipView?
    private var observer: NSObjectProtocol?

    init(view: NSView, cursorUpdate: Bool = false) {
        self.view = view
        super.init()
        var options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if cursorUpdate { options.insert(.cursorUpdate) }
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
    }

    required init?(coder: NSCoder) { nil }

    /// Observes the scroll view the list sits in now; call when the list moved into another view hierarchy.
    func attach() {
        let clip = view?.enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observedClip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Recomputes the point from where the pointer is now, if it still lies over the list and the list's window is the one under it.
    func refresh() {
        guard point != nil, let view, let window = view.window else { return }
        let screen = NSEvent.mouseLocation
        let local = view.convert(window.convertPoint(fromScreen: screen), from: nil)
        set(view.visibleRect.contains(local) ? local : nil)
    }

    func clear() { set(nil) }

    override func mouseEntered(with event: NSEvent) { update(event) }
    override func mouseMoved(with event: NSEvent) { update(event) }
    override func cursorUpdate(with event: NSEvent) { update(event) }
    override func mouseExited(with event: NSEvent) { set(nil) }

    private func update(_ event: NSEvent) {
        guard let view else { return }
        let local = view.convert(event.locationInWindow, from: nil)
        set(view.visibleRect.contains(local) ? local : nil)
    }

    private func set(_ new: NSPoint?) {
        point = new
        onChange?(new)
    }
}
