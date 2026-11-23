import AppKit
import GitEngine

/// Harness switches for adding and editing remotes.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_ADD_REMOTE=1` opens the add-remote sheet with a real click on the sidebar's "Add Remote…"; the edit sheet opens from `GITBONSAI_SIDEBAR_MENU_LIST=remote:<name>` with `GITBONSAI_SIDEBAR_MENU_PICK=Edit`.
    /// It also prints the sidebar's remote headers once the remotes were read.
    static func openAddRemote(on tab: RepositoryViewController) {
        guard isActive else { return }
        if environment["GITBONSAI_PRINT_REMOTES"] == "1" {
            after(0.6) { remoteLog("sidebar remotes: " + tab.sidebar.remotes.map { "\($0) (header \(tab.sidebar.itemIndex(header: SidebarItem.remotePrefix + $0) == nil ? "missing" : "shown"))" }.joined(separator: ", ")) }
        }
        guard environment["GITBONSAI_ADD_REMOTE"] == "1" else { return }
        let sidebar = tab.sidebar
        after(0.6) {
            guard let window = sidebar.window, let index = (0..<sidebar.items.count).first(where: { if case .row(let row) = sidebar.items[$0] { row.target == SidebarItem.addRemoteTarget } else { false } }) else { return remoteLog("no Add Remote row") }
            let rect = sidebar.rowRect(at: index)
            click(in: window, at: sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
            // The sheet opens after reading the remotes; the capture waits until its script was scheduled.
            remoteSheetRelease = hold()
        }
    }

    /// `GITBONSAI_REMOTE_SCRIPT=<step>;…` drives the open remote sheet: `click:name|url|fetch|confirm|cancel` and `type:<text>` with real events, `clear:name|url` empties a field as a selection and delete would,
    /// `key:return|escape`, `print` (the form's state) and `shot:<png>` (the sheet alone).
    static func driveRemoteSheet(_ sheet: RemoteSheet) {
        defer { remoteSheetRelease?(); remoteSheetRelease = nil }
        guard isActive, let script = environment["GITBONSAI_REMOTE_SCRIPT"] else { return }
        for (index, step) in script.split(separator: ";").map(String.init).enumerated() {
            after(0.5 + 0.35 * Double(index)) { runRemoteStep(step, on: sheet) }
        }
    }

    private static func runRemoteStep(_ step: String, on sheet: RemoteSheet) {
        guard let window = sheet.window else { return }
        let (verb, argument) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        let inputs = ["name": sheet.nameInput, "url": sheet.urlInput]
        switch verb {
        case "click":
            let views: [String: NSView] = ["name": sheet.nameInput, "url": sheet.urlInput, "fetch": sheet.fetchBox, "confirm": sheet.confirmButton, "cancel": sheet.cancelButton]
            guard let view = views[argument], !view.isHiddenOrHasHiddenAncestor else { return remoteLog("no visible \(argument)") }
            click(in: window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        case "type":
            for character in argument { sendRemoteKey(String(character), code: 0, to: window) }
        case "clear":
            guard let input = inputs[argument] else { return remoteLog("no field \(argument)") }
            input.stringValue = ""
            input.onChange?("")
        case "key":
            let keys: [String: (String, UInt16)] = ["return": ("\r", 36), "escape": ("\u{1b}", 53)]
            guard let (characters, code) = keys[argument] else { return remoteLog("unknown key \(argument)") }
            sendRemoteKey(characters, code: code, to: window)
        case "print":
            let message = sheet.nameMessage.isHidden ? "none" : sheet.nameMessage.stringValue
            remoteLog("remote sheet: open \(window.sheetParent != nil), name \"\(sheet.nameInput.stringValue)\", url \"\(sheet.urlInput.stringValue)\", error \(message), fetch \(sheet.fetchBox.isHidden ? "hidden" : sheet.fetchBox.isOn ? "on" : "off"), confirm \(sheet.confirmButton.isEnabled ? "enabled" : "disabled")")
        case "shot":
            guard let view = window.contentView?.superview ?? window.contentView else { return }
            window.appearance = NSApp.appearance
            view.layoutSubtreeIfNeeded()
            writePNG(of: view, to: argument)
        default:
            remoteLog("unknown step \(step)")
        }
    }

    private static func sendRemoteKey(_ characters: String, code: UInt16, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    private static var remoteSheetRelease: (@MainActor () -> Void)?

    private static func remoteLog(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
