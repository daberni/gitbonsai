import AppKit

/// Harness switches for confirmations shown as real sheets, which the Tags list needs to show that it stays open behind them.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_SHEET_CLICK=confirm|cancel` shows confirmations as real sheets instead of answering them, and clicks that button with real events.
    static var clicksSheets: Bool { isActive && ["confirm", "cancel"].contains(environment["GITBONSAI_SHEET_CLICK"] ?? "") }

    /// Called right before the sheet begins; `GITBONSAI_SHEET_SHOT=<png>` renders the window with the sheet and, beside it, any open popover's list.
    static func clickSheet(_ alert: NSAlert) {
        let confirms = environment["GITBONSAI_SHEET_CLICK"] == "confirm"
        after(0.5) {
            let sheet = alert.window
            let popovers = NSApp.windows.filter { $0.className.contains("Popover") && $0.isVisible }
            FileHandle.standardError.write(Data("sheet up: \(alert.messageText), key window \(NSApp.keyWindow?.className ?? "none"), popover windows shown \(popovers.count)\n".utf8))
            if environment["GITBONSAI_SHEET_SHOT"] != nil { render(alert) }
            let button = alert.buttons[confirms ? 0 : 1]
            click(in: sheet, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        }
    }
}
