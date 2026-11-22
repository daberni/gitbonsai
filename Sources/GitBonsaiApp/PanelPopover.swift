import AppKit

/// A transient popover that shows a `PanelListView` next to the sidebar row it belongs to.
@MainActor
final class PanelPopover: NSObject, NSPopoverDelegate {
    let list: PanelListView
    private let popover = NSPopover()
    private let controller = NSViewController()
    var onClose: (() -> Void)?

    init(list: PanelListView) {
        self.list = list
        super.init()
        controller.view = list
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !ScreenshotHarness.isActive
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// The window AppKit hosts the popover in, while it is shown.
    var window: NSWindow? { isShown ? list.window : nil }

    func show(relativeTo rect: NSRect, of view: NSView) {
        list.layoutSubtreeIfNeeded()
        popover.contentSize = list.fittingSize
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        list.window?.makeFirstResponder(list.filterField.isHidden ? list.tableView : list.filterField)
    }

    func close() {
        popover.close()
    }

    /// The list grows or shrinks with its entries while it is open.
    func fitContent() {
        guard isShown else { return }
        list.layoutSubtreeIfNeeded()
        popover.contentSize = list.fittingSize
    }

    func popoverDidClose(_ notification: Notification) {
        onClose?()
    }
}
