import AppKit
import SwiftUI

/// The one settings window, with a toolbar tab per section like the system's own settings. The tabs are AppKit, each section a SwiftUI form:
/// the app has no SwiftUI `App` lifecycle, so the `Settings` scene is not available, and a SwiftUI `TabView` outside it draws a segmented control instead of toolbar tabs.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Section: String, CaseIterable {
        case general, apps, git, avatars

        var title: String {
            switch self {
            case .general: String(localized: "settings.pane.general", defaultValue: "General", bundle: .module, comment: "Settings tab.")
            case .apps: String(localized: "settings.pane.apps", defaultValue: "Apps", bundle: .module, comment: "Settings tab of the editors and terminals.")
            case .git: String(localized: "settings.pane.git", defaultValue: "Git", bundle: .module, comment: "Settings tab.")
            case .avatars: String(localized: "settings.pane.avatars", defaultValue: "Avatars", bundle: .module, comment: "Settings tab.")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .apps: "square.grid.2x2"
            case .git: "point.3.connected.trianglepath.dotted"
            case .avatars: "person.crop.circle"
            }
        }

        @MainActor @ViewBuilder fileprivate var pane: some View {
            switch self {
            case .general: GeneralSettingsPane()
            case .apps: AppsSettingsPane()
            case .git:
                GitSettingsPane()
                MergeToolSettingsSection()
                FetchSettingsSection()
            case .avatars: AvatarSettingsPane()
            }
        }
    }

    static let shared = SettingsWindowController()

    let model = SettingsModel()
    private let tabs = SettingsTabs()

    private init() {
        tabs.tabStyle = .toolbar
        for section in Section.allCases {
            let host = NSHostingController(rootView: SettingsPaneFrame { section.pane }.environment(model))
            // The window takes each section's height, as the system settings do.
            host.sizingOptions = .preferredContentSize
            host.title = section.title
            let item = NSTabViewItem(viewController: host)
            item.label = section.title
            item.identifier = section.rawValue
            item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            tabs.addTabViewItem(item)
        }
        let last = AppSettings.lastSettingsSection.flatMap(Section.init) ?? .general
        tabs.selectedTabViewItemIndex = Section.allCases.firstIndex(of: last) ?? 0
        tabs.onSelect = { AppSettings.lastSettingsSection = $0 }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = last.title
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

/// Reports the section the user switched to, so the window can open there next time.
private final class SettingsTabs: NSTabViewController {
    var onSelect: ((String) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let identifier = tabViewItem?.identifier as? String { onSelect?(identifier) }
    }
}

/// Every section is a grouped form of the same width that is as tall as its content, so switching sections only changes the window's height.
/// A section taller than `Theme.Settings.maxHeight` stops there and scrolls.
private struct SettingsPaneFrame<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                // The action runs inside the layout pass that measured the content; a height set there only takes effect at the next event, so the window would resize under the pointer of the following click.
                DispatchQueue.main.async { contentHeight = height }
            }
            .frame(width: Theme.Settings.width, height: min(contentHeight ?? Theme.Settings.maxHeight, Theme.Settings.maxHeight))
    }
}

/// An explanation under a section, in the app's caption style.
struct SettingsCaption: View {
    let text: LocalizedStringResource

    init(_ text: LocalizedStringResource) { self.text = text }

    var body: some View {
        Text(text)
            .font(.themeCaption)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
