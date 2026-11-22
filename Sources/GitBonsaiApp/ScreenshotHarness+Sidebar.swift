import AppKit
import GitEngine

/// Harness switches for the sidebar.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SIDEBAR_SCROLL=<points>` scrolls the sidebar down and prints where its scroller and status slot column lie.
    /// The capture does not draw an overlay scroller, so the printed edges show whether it would cover the slot.
    static func scrollSidebar(_ sidebar: SidebarView) {
        guard let offset = environment["GITBONSAI_SIDEBAR_SCROLL"].flatMap(Double.init), let scrollView = sidebar.enclosingScrollView else { return }
        sidebar.scroll(CGPoint(x: 0, y: offset))
        let scroller = scrollView.verticalScroller.map { sidebar.convert($0.bounds, from: $0) }
        let style = scrollView.scrollerStyle == .overlay ? "overlay" : "legacy"
        print("sidebar \(style) scroller x \(scroller.map { "\($0.minX)" } ?? "none"), slot right \(sidebar.slotRight), width \(sidebar.bounds.width)")
    }
}
