import AppKit

/// Hosts the tab row in the title bar, beside the traffic lights, and in the window content while in full screen.
@MainActor
final class TitlebarTabRow {
    let tabBar = TabBarView()
    private let root: NSView
    private weak var window: NSWindow?

    /// `root` is the window's content view, which takes the row in full screen.
    init(window: NSWindow, root: NSView) {
        self.window = window
        self.root = root
    }

    /// macOS decides which parts of the title bar move the window from the views inside the title bar only.
    /// So the tab row lives there, behind the traffic lights, and tells it that clicks on it are its own; the free space moves the window through the tab row.
    /// In full screen the title bar slides away, so the row moves into the window content.
    func mount() {
        guard let window else { return }
        tabBar.removeFromSuperview()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        let titlebar = window.standardWindowButton(.closeButton)?.superview
        let host: NSView = window.styleMask.contains(.fullScreen) ? root : titlebar ?? root
        host.addSubview(tabBar, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: host.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])
    }

    /// The tabs start right of the traffic lights. The buttons are left where macOS puts them; in full screen they are gone.
    func placeBesideTrafficLights() {
        guard let window else { return }
        guard !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton), let container = zoom.superview else {
            tabBar.leadingInset = Theme.Space.m
            return
        }
        let frame = container.convert(zoom.frame, to: tabBar)
        tabBar.leadingInset = frame.maxX + Theme.Tabs.afterTrafficLights
    }

    /// Entering or leaving full screen moves the row between title bar and content.
    func followFullScreen() {
        mount()
        placeBesideTrafficLights()
    }
}
