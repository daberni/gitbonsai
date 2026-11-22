import AppKit
import UniformTypeIdentifiers

/// A pop-up for choosing an app: the default first, then the chosen app, then "Andere App …", which asks for one in /Applications.
@MainActor
final class AppPickerButton: NSPopUpButton {
    private let defaultTitle: String
    private let defaultApp: URL?
    private let read: () -> URL?
    private let write: (URL?) -> Void

    /// `defaultApp` only supplies the icon of the first entry.
    init(defaultTitle: String, defaultApp: URL?, read: @escaping () -> URL?, write: @escaping (URL?) -> Void) {
        self.defaultTitle = defaultTitle
        self.defaultApp = defaultApp
        self.read = read
        self.write = write
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(choose(_:))
        widthAnchor.constraint(equalToConstant: Theme.Settings.popupWidth).isActive = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        removeAllItems()
        menu?.addItem(entry(defaultTitle, app: defaultApp, tag: 0))
        if let chosen = read() {
            menu?.addItem(.separator())
            menu?.addItem(entry(FileManager.default.displayName(atPath: chosen.path).replacingOccurrences(of: ".app", with: ""), app: chosen, tag: 1))
        }
        menu?.addItem(.separator())
        menu?.addItem(entry("Andere App …", app: nil, tag: 2))
        selectItem(withTag: read() == nil ? 0 : 1)
    }

    private func entry(_ title: String, app: URL?, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        if let app {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: Theme.Settings.appIcon, height: Theme.Settings.appIcon)
            item.image = icon
        }
        return item
    }

    @objc private func choose(_ sender: Any?) {
        switch selectedTag() {
        case 0:
            write(nil)
            rebuild()
        case 2:
            askForApp()
        default:
            break
        }
    }

    private func askForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Auswählen"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url { write(url) }
            rebuild()
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }
}
