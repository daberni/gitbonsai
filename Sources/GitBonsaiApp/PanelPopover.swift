import AppKit

/// A transient popover that shows a `PanelListView` next to the sidebar row it belongs to.
@MainActor
final class PanelPopover: NSObject, NSPopoverDelegate {
    let list: PanelListView
    private let popover = NSPopover()
    private let controller = NSViewController()
    var onClose: (() -> Void)?
    private var holds = 0

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

    /// Keeps the popover open, inert, behind a sheet on its window while `body` runs. AppKit closes every popover of a window when a sheet begins on it
    /// (`_NSPopoverNotifySheetWillBeginOnWindow`) and asks `popoverShouldClose` first, which says no while held, to that and to clicks outside.
    func stayingOpen<T>(_ body: () async -> T) async -> T {
        holds += 1
        list.window?.ignoresMouseEvents = true
        let result = await body()
        holds -= 1
        if holds == 0 { list.window?.ignoresMouseEvents = false }
        return result
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        holds == 0
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
