import AppKit
import UniformTypeIdentifiers

/// A pop-up for choosing an app: the default first, then the suggested apps and the chosen one, then "Andere App …", which asks for one in /Applications.
@MainActor
final class AppPickerButton: NSPopUpButton {
    private let defaultTitle: String
    private let defaultApp: URL?
    private let read: () -> URL?
    private let write: (URL?) -> Void
    private let suggestions: [URL]
    private static let firstSuggestionTag = 3

    /// `defaultApp` only supplies the icon of the first entry. `suggestions` are installed apps offered without the open panel, such as the detected terminals.
    init(defaultTitle: String, defaultApp: URL?, suggestions: [URL] = [], read: @escaping () -> URL?, write: @escaping (URL?) -> Void) {
        self.defaultTitle = defaultTitle
        self.defaultApp = defaultApp
        self.suggestions = suggestions.filter { $0 != defaultApp }
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
        let chosen = read()
        if !suggestions.isEmpty || chosen != nil { menu?.addItem(.separator()) }
        for (index, app) in suggestions.enumerated() {
            menu?.addItem(entry(Self.name(of: app), app: app, tag: Self.firstSuggestionTag + index))
        }
        if let chosen, !suggestions.contains(chosen), chosen != defaultApp {
            menu?.addItem(entry(Self.name(of: chosen), app: chosen, tag: 1))
        }
        menu?.addItem(.separator())
        menu?.addItem(entry("Andere App …", app: nil, tag: 2))
        let selected = chosen.flatMap { suggestions.firstIndex(of: $0).map { Self.firstSuggestionTag + $0 } } ?? (chosen == nil || chosen == defaultApp ? 0 : 1)
        selectItem(withTag: selected)
    }

    private static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
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
        case let tag where tag >= Self.firstSuggestionTag:
            write(suggestions[tag - Self.firstSuggestionTag])
            rebuild()
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
