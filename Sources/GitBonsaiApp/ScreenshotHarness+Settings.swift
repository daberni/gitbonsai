import AppKit
import GitEngine

/// Harness switches for the settings window. Its sections are SwiftUI, so controls are found through the accessibility tree SwiftUI publishes
/// (label, identifier, value) and driven with real mouse and key events at their accessibility frame, the way a person or VoiceOver reaches them.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_LANGUAGE=en|de` runs a harness launch in that language without storing it.
    static var language: String? {
        isActive ? environment["GITBONSAI_LANGUAGE"] : nil
    }

    /// `GITBONSAI_SETTINGS=general|apps|git|avatars` opens the settings on that section and captures the settings window instead of the main window.
    static var settingsSection: SettingsWindowController.Section? {
        environment["GITBONSAI_SETTINGS"].flatMap(SettingsWindowController.Section.init)
    }

    static func openSettingsIfAsked() {
        guard isActive, let section = settingsSection else { return }
        let settings = SettingsWindowController.shared
        settings.show(section)
        if runsInBackground { hideWindows() }
        guard let window = settings.window else { return }
        let steps = environment["GITBONSAI_SETTINGS_SCRIPT"].map { $0.split(separator: ";").map(String.init) } ?? []
        if !steps.isEmpty { publishSwiftUIAccessibility() }
        // SwiftUI builds its accessibility tree a moment after it is asked for.
        after((steps.isEmpty ? 0 : 0.5)) { runSettingsSteps(steps[...], in: window) }
    }

    /// The main window is not captured while the settings window is.
    static func capturesSettingsInstead(of window: NSWindow) -> Bool {
        settingsSection != nil && window !== SettingsWindowController.shared.window
    }

    /// `GITBONSAI_SETTINGS_SCRIPT=<step>;…`, half a second per step, then the capture: `click:<label or identifier>`, `action:<element>=<action name>`, `scroll:<points>`, `type:<text>`, `key:return|tab|escape`, `print`, `shot:<png>`, `wait:<seconds>`.
    private static func runSettingsSteps(_ steps: ArraySlice<String>, in window: NSWindow) {
        guard let step = steps.first else { return captureAndQuit(window: window) }
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        var delay = 0.5
        switch parts[0] {
        case "click":
            if let element = settingsElement(argument, in: window) {
                let frame = window.convertFromScreen(element.accessibilityFrame?() ?? .zero)
                // A checkbox or radio button spans its whole row in a grouped form; the box sits at its leading edge.
                let boxed = [.checkBox, .radioButton].contains(element.accessibilityRole?())
                let point = CGPoint(x: boxed ? frame.minX + frame.height / 2 : frame.midX, y: frame.midY)
                let height = window.frame.height
                click(in: window, at: point)
                print("settings: clicked \(describe(element))")
                if boxed { reportResponse(of: element, in: window, from: height) }
            } else {
                print("settings: no element \(argument)")
            }
        case "action":
            // `action:<element>=<name>` performs a named accessibility action, as VoiceOver's actions rotor does.
            let target = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let action = settingsElement(target[0], in: window)?.accessibilityCustomActions?()?.first { $0.name == target.last }
            if let action {
                if let handler = action.handler { _ = handler() } else if let target = action.target as? NSObject, let selector = action.selector { target.perform(selector, with: action) }
                print("settings: performed \(argument)")
            } else {
                print("settings: no action \(argument)")
            }
        case "scroll":
            // A real scroll-wheel event over the section's middle; positive points scroll down.
            let points = Int32(argument) ?? 200
            let content = window.contentLayoutRect
            let point = CGPoint(x: content.midX, y: content.midY)
            let screenPoint = window.convertPoint(toScreen: point)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            // Background windows ignore mouse events, so the event goes to the view under the point the way the window would route it.
            if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0) {
                cgEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
                if let event = NSEvent(cgEvent: cgEvent), let view = window.contentView?.superview?.hitTest(point) { view.scrollWheel(with: event) }
            }
            let scrollView = views(of: NSScrollView.self, in: window).first
            print("settings: scroll offset \(Int(scrollView?.contentView.bounds.minY ?? -1)) of \(Int(scrollView?.documentView?.frame.height ?? -1))")
            print("settings: scrolled \(points)")
        case "type":
            for character in argument { sendKey(String(character), code: 0, in: window) }
            print("settings: typed \(argument), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "none")")
        case "key":
            let keys: [String: (String, UInt16)] = ["return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1b}", 53)]
            if let (characters, code) = keys[argument] { sendKey(characters, code: code, in: window) }
            print("settings: key \(argument), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "none")")
        case "print":
            print("settings: \(SettingsWindowController.shared.selectedSection.rawValue), window \(Int(window.frame.width))×\(Int(window.frame.height))")
            settingsElements(in: window).forEach { print("  " + describe($0)) }
        case "shot":
            if let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            }
        case "wait":
            delay = Double(argument) ?? 1
        default:
            print("settings: unknown step \(step)")
        }
        after(delay) { runSettingsSteps(steps.dropFirst(), in: window) }
    }

    /// After a click on a checkbox or radio button, prints how long until the control shows its new state and until the window has its final height,
    /// measured every 2 ms against the wall clock; a window that changes height while the user looks at it is part of what feels slow.
    private static func reportResponse(of element: AnyObject, in window: NSWindow, from height: CGFloat) {
        let start = CACurrentMediaTime()
        let before = value(of: element) as? NSNumber
        var selectedAfter: Double?
        var lastResize = start
        var lastHeight = height
        func poll() {
            let now = CACurrentMediaTime()
            if selectedAfter == nil, let current = value(of: element) as? NSNumber, current != before || current.intValue == 1 { selectedAfter = now - start }
            if window.frame.height != lastHeight {
                lastHeight = window.frame.height
                lastResize = now
            }
            guard now - start > 0.45 else { return after(0.002) { poll() } }
            let shown = selectedAfter.map { "\(Int($0 * 1000)) ms" } ?? "never"
            print("settings: response shown after \(shown), window \(Int(height))→\(Int(lastHeight)) pt, settled after \(Int((lastResize - start) * 1000)) ms")
        }
        poll()
    }

    /// SwiftUI publishes its accessibility tree only once an assistive app asks, which it learns from `AXEnhancedUserInterface` on the application;
    /// the harness sets that attribute on itself, the way VoiceOver or an accessibility inspector would. The deprecated setter is reached by selector, so the build stays free of warnings.
    private static func publishSwiftUIAccessibility() {
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
    }

    /// Every element of the window that has a role, depth first: the toolbar's tabs and the section's controls and texts.
    /// SwiftUI's nodes answer the accessibility selectors without declaring `NSAccessibilityProtocol`, so they are asked through `AnyObject`.
    private static func settingsElements(in window: NSWindow) -> [AnyObject] {
        var found: [AnyObject] = []
        func collect(_ element: AnyObject) {
            if let role = element.accessibilityRole?(), ![.group, .unknown, .scrollArea, .splitGroup, .toolbar].contains(role) { found.append(element) }
            for child in element.accessibilityChildren?() ?? [] { collect(child as AnyObject) }
        }
        window.accessibilityChildren()?.forEach { collect($0 as AnyObject) }
        return found
    }

    /// The first element whose identifier is `name`, else the first control whose label or title is, else any element whose label, title or value is.
    private static func settingsElement(_ name: String, in window: NSWindow) -> AnyObject? {
        let elements = settingsElements(in: window)
        return elements.first { $0.accessibilityIdentifier?() == name }
            ?? elements.first { $0.accessibilityRole?() != .staticText && [$0.accessibilityLabel?() ?? nil, $0.accessibilityTitle?() ?? nil].contains(name) }
            ?? elements.first { [$0.accessibilityLabel?() ?? nil, $0.accessibilityTitle?() ?? nil, value(of: $0) as? String].contains(name) }
    }

    private static func describe(_ element: AnyObject) -> String {
        let name = [element.accessibilityLabel?() ?? nil, element.accessibilityTitle?() ?? nil].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let value = value(of: element).map { " = \($0)" } ?? ""
        let identifier = (element.accessibilityIdentifier?()).flatMap { $0.isEmpty ? nil : " #\($0)" } ?? ""
        let enabled = element.isAccessibilityEnabled?() == false ? " (disabled)" : ""
        return "\((element.accessibilityRole?()).map { "\($0.rawValue)" } ?? "?") \"\(name)\"\(value)\(identifier)\(enabled)"
    }

    private static func value(of element: AnyObject) -> Any? {
        (element as? NSObject)?.responds(to: NSSelectorFromString("accessibilityValue")) == true ? (element as? NSObject)?.value(forKey: "accessibilityValue") : nil
    }

    private static func sendKey(_ characters: String, code: UInt16, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
        }
    }
}
