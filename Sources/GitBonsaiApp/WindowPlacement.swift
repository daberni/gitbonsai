import AppKit

/// Where the window was and in which state, saved across launches.
struct WindowPlacement: Codable, Equatable {
    /// The frame outside full screen and zoom, which those states return to.
    var frame: CGRect
    /// The display the window was on, as `NSScreenNumber`.
    var screen: UInt32?
    var isZoomed = false
    var isFullScreen = false

    struct Screen {
        let id: UInt32?
        let visibleFrame: CGRect
    }

    /// The frame to restore: on its own screen while that is attached, otherwise on `main`; moved and shrunk until it lies within that screen's visible area.
    func restoredFrame(screens: [Screen], main: Screen, minimum: CGSize) -> CGRect {
        let target = screens.first { $0.id != nil && $0.id == screen } ?? main
        let visible = target.visibleFrame
        let width = min(max(frame.width, minimum.width), visible.width)
        let height = min(max(frame.height, minimum.height), visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

    var placementScreen: WindowPlacement.Screen { WindowPlacement.Screen(id: displayID, visibleFrame: visibleFrame) }
}

/// Saves the window's frame, screen, zoom and full screen while it moves and when the app quits, and puts them back on launch.
@MainActor
final class WindowFrameKeeper {
    private let window: NSWindow
    private let store: SessionStore
    private var normalFrame: CGRect
    private var isInFullScreenTransition = false
    private var entersFullScreenWhenShown = false
    private var zoomsWhenShown = false
    private var pendingSave: Task<Void, Never>?

    init(window: NSWindow, store: SessionStore) {
        self.window = window
        self.store = store
        normalFrame = window.frame
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Puts the window where it was, before it is shown; a new window is centred on the main screen.
    func restore() {
        guard let placement = store.windowPlacement, let main = NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            normalFrame = window.frame
            return
        }
        let frame = placement.restoredFrame(screens: NSScreen.screens.map(\.placementScreen), main: main.placementScreen, minimum: window.minSize)
        window.setFrame(frame, display: false)
        normalFrame = frame
        zoomsWhenShown = placement.isZoomed
        entersFullScreenWhenShown = placement.isFullScreen
    }

    /// Zoom and full screen order the window front, so they wait until it is shown. A harness run in the background must never show a window or take over a space, so it only reports them.
    func windowShown() {
        let zooms = zoomsWhenShown && !window.isZoomed
        let entersFullScreen = entersFullScreenWhenShown
        zoomsWhenShown = false
        entersFullScreenWhenShown = false
        if ScreenshotHarness.runsInBackground {
            if zooms { FileHandle.standardError.write(Data("window would zoom\n".utf8)) }
            if entersFullScreen { FileHandle.standardError.write(Data("window would enter full screen\n".utf8)) }
            return
        }
        if zooms { window.zoom(nil) }
        if entersFullScreen { window.toggleFullScreen(nil) }
    }

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    var placement: WindowPlacement {
        WindowPlacement(frame: normalFrame, screen: window.screen?.displayID, isZoomed: zoomsWhenShown || !isFullScreen && window.isZoomed, isFullScreen: isFullScreen || entersFullScreenWhenShown)
    }

    /// A move or resize; saved once the window rests.
    func frameChanged() {
        if !isInFullScreenTransition, !isFullScreen, !window.isZoomed { normalFrame = window.frame }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Theme.Window.frameSaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func fullScreenTransitionBegan() {
        isInFullScreenTransition = true
    }

    func fullScreenTransitionEnded() {
        isInFullScreenTransition = false
        save()
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        store.windowPlacement = placement
    }
}
