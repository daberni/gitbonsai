import AppKit

/// Harness switches for confirmations shown as real sheets, which the Tags list needs to show that it stays open behind them.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SHEET_CLICK=confirm|cancel` shows confirmations as real sheets instead of answering them, and clicks that button with real events.
    static var clicksSheets: Bool { isActive && ["confirm", "cancel"].contains(environment["GITBONSAI_SHEET_CLICK"] ?? "") }

    /// Called right before the sheet begins; `GITBONSAI_SHEET_SHOT=<png>` renders the window with the sheet and, beside it, any open popover's list.
    static func clickSheet(_ alert: NSAlert) {
        let confirms = environment["GITBONSAI_SHEET_CLICK"] == "confirm"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let sheet = alert.window
            let popovers = NSApp.windows.filter { $0.className.contains("Popover") && $0.isVisible }
            FileHandle.standardError.write(Data("sheet up: \(alert.messageText), key window \(NSApp.keyWindow?.className ?? "none"), popover windows shown \(popovers.count)\n".utf8))
            if environment["GITBONSAI_SHEET_SHOT"] != nil { render(alert) }
            let button = alert.buttons[confirms ? 0 : 1]
            click(in: sheet, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        }
    }
}

/// Harness switch for the layout of a panel's header and filter row while its entries are brought up to date.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_PANEL_FRAMES=<seconds>` samples, from the moment the popover shows, the frames of the filter field, its scope arrow, its text, the counter
    /// and the busy slot every few milliseconds, and prints them each time they change, with whether the list was busy then.
    /// `GITBONSAI_PANEL_FRAMES_SHOT=<prefix>` renders the list each time it turns busy or idle, to `<prefix>-<n>-busy.png` or `<prefix>-<n>-idle.png`.
    static func watchPanelLayout(_ popover: PanelPopover) {
        guard let seconds = environment["GITBONSAI_PANEL_FRAMES"].flatMap(Double.init) else { return }
        samplePanelLayout(popover, until: Date().addingTimeInterval(seconds), last: nil, phases: [], changes: 0)
    }

    private static func samplePanelLayout(_ popover: PanelPopover, until end: Date, last: String?, phases: [Bool], changes: Int) {
        let list = popover.list
        let frames = panelLayout(of: list)
        var phases = phases
        if phases.last != list.isBusy {
            phases.append(list.isBusy)
            if let prefix = environment["GITBONSAI_PANEL_FRAMES_SHOT"] { capturePanel(popover, to: "\(prefix)-\(phases.count)-\(list.isBusy ? "busy" : "idle").png") }
        }
        var changes = changes
        if frames != last {
            if last != nil { changes += 1 }
            FileHandle.standardError.write(Data("panel layout (\(list.isBusy ? "busy" : "idle"), note \(list.note ?? "none")): \(frames)\n".utf8))
        }
        guard Date() < end else {
            let sequence = phases.map { $0 ? "busy" : "idle" }.joined(separator: " → ")
            FileHandle.standardError.write(Data("panel layout changes: \(changes) over \(sequence)\n".utf8))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { samplePanelLayout(popover, until: end, last: frames, phases: phases, changes: changes) }
    }

    private static func panelLayout(of list: PanelListView) -> String {
        let field = list.filterField
        func inList(_ rect: NSRect, of view: NSView) -> String {
            let frame = view.convert(rect, to: list)
            return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        }
        let cell = field.cell as? NSSearchFieldCell
        let arrow = cell.map { inList($0.searchButtonRect(forBounds: field.bounds), of: field) } ?? "-"
        let text = cell.map { inList($0.searchTextRect(forBounds: field.bounds), of: field) } ?? "-"
        let fieldFrame = field.isHidden ? "hidden" : inList(field.bounds, of: field)
        // The popover centres on its sidebar row, so a list that grows moves its header on screen even where the list's own frames stay.
        let onScreen = list.window.map { window in window.convertToScreen(list.convert(list.bounds, to: nil)) }.map { "\(Int($0.minX)),\(Int($0.maxY))" } ?? "-"
        return "list top on screen \(onScreen), field \(fieldFrame), arrow \(arrow), text \(text), counter \(inList(list.countLabel.bounds, of: list.countLabel)), busy slot \(inList(list.busyIndicator.bounds, of: list.busyIndicator)), menu \(field.searchMenuTemplate == nil ? "none" : "scopes")"
    }
}
