import AppKit

/// The one settings window, with a toolbar tab per section like the system's own settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Section: String, CaseIterable {
        case general, git, appearance, fetch, avatars

        var title: String {
            switch self {
            case .general: String(localized: "settings.pane.general", defaultValue: "General", bundle: .module, comment: "Settings tab.")
            case .git: String(localized: "settings.pane.git", defaultValue: "Git", bundle: .module, comment: "Settings tab.")
            case .appearance: String(localized: "settings.pane.appearance", defaultValue: "Appearance", bundle: .module, comment: "Settings tab.")
            case .fetch: String(localized: "settings.pane.fetch", defaultValue: "Fetch", bundle: .module, comment: "Settings tab.")
            case .avatars: String(localized: "settings.pane.avatars", defaultValue: "Avatars", bundle: .module, comment: "Settings tab.")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .git: "point.3.connected.trianglepath.dotted"
            case .appearance: "circle.lefthalf.filled"
            case .fetch: "arrow.down.circle"
            case .avatars: "person.crop.circle"
            }
        }

        @MainActor func makeViewController() -> NSViewController {
            switch self {
            case .general: GeneralSettingsViewController()
            case .git: GitSettingsViewController()
            case .appearance: AppearanceSettingsViewController()
            case .fetch: FetchSettingsViewController()
            case .avatars: AvatarSettingsViewController()
            }
        }
    }

    static let shared = SettingsWindowController()

    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        for section in Section.allCases {
            let controller = section.makeViewController()
            controller.title = section.title
            let item = NSTabViewItem(viewController: controller)
            item.label = section.title
            item.identifier = section.rawValue
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = Section.general.title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var selectedSection: Section {
        Section.allCases[max(tabs.selectedTabViewItemIndex, 0)]
    }

    func show(_ section: Section? = nil) {
        if let section, let index = Section.allCases.firstIndex(of: section) {
            tabs.selectedTabViewItemIndex = index
            window?.title = section.title
        }
        showWindow(nil)
        if !ScreenshotHarness.runsInBackground { window?.makeKeyAndOrderFront(nil) }
    }
}
